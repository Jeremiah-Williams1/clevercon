#!/usr/bin/env node
// Version rules for the two published packages. Read-only: never publishes, never edits files.
//
//   node ops/ci/check-versions.mjs            report mode (PR checks): prints a table;
//                                             fails only on a broken tree (bad semver, or the MCP
//                                             asks for an SDK version this tree does not provide).
//   node ops/ci/check-versions.mjs --release  release mode (PR into prod, rehearsal): also fails if
//                                             a version is already published, or a stable version is
//                                             not higher than the highest stable one on the registry.
//
// REGISTRY=<url> points the lookups at another registry (the Verdaccio rehearsal uses this).
// If the registry cannot be reached the lookups are skipped with a warning (report mode) or fail (release mode).
import { execFileSync } from 'node:child_process';
import { readFileSync, appendFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';

const RELEASE = process.argv.includes('--release');
const REGISTRY = process.env.REGISTRY || 'https://registry.npmjs.org/';
const PACKAGES = ['packages/agent-sdk', 'packages/mcp']; // publish order: the SDK first, the MCP second

// semver ships inside npm, so nothing needs installing. Look next to the real npm first, then in the global root.
function loadSemver() {
  const require = createRequire(import.meta.url);
  const candidates = [];
  try {
    const npmBin = realpathSync(execFileSync('which', ['npm'], { encoding: 'utf8' }).trim());
    candidates.push(join(dirname(npmBin), '..', 'node_modules', 'semver'));
  } catch {
    // no npm on PATH: fall through to the other candidates
  }
  try {
    const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
    candidates.push(join(root, 'npm', 'node_modules', 'semver'));
  } catch {
    // ignore
  }
  for (const c of candidates) {
    try {
      return require(c);
    } catch {
      // try the next one
    }
  }
  throw new Error(`cannot find npm's bundled semver; tried:\n  ${candidates.join('\n  ')}`);
}
const semver = loadSemver();

const errors = [];
const warnings = [];
const rows = [];

function registryVersions(name) {
  try {
    const out = execFileSync('npm', ['view', name, 'versions', '--json', '--registry', REGISTRY], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    const v = out ? JSON.parse(out) : [];
    return { ok: true, versions: Array.isArray(v) ? v : [v] };
  } catch (e) {
    const text = `${e.stderr || ''}${e.stdout || ''}`;
    if (text.includes('E404')) return { ok: true, versions: [] }; // never published
    return { ok: false, reason: text.split('\n')[0] || String(e.message) };
  }
}

const manifests = PACKAGES.map((dir) => JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')));

for (const m of manifests) {
  const where = `${m.name}@${m.version}`;
  if (!semver.valid(m.version)) {
    errors.push(`${where}: not a valid semver version`);
    rows.push([m.name, m.version, '-', 'invalid version']);
    continue;
  }
  const reg = registryVersions(m.name);
  if (!reg.ok) {
    (RELEASE ? errors : warnings).push(`${m.name}: registry lookup failed (${reg.reason})`);
    rows.push([m.name, m.version, '?', 'registry not reachable']);
    continue;
  }
  const stable = reg.versions.filter((v) => !semver.prerelease(v));
  const topStable = stable.sort(semver.compare).pop() || 'none';
  const states = [];
  if (reg.versions.includes(m.version)) {
    states.push('already published');
    if (RELEASE) errors.push(`${where}: this version is already on the registry; bump it`);
  }
  if (!semver.prerelease(m.version) && topStable !== 'none' && semver.lt(m.version, topStable)) {
    states.push(`lower than ${topStable}`);
    if (RELEASE) errors.push(`${where}: lower than the highest stable version on the registry (${topStable})`);
  }
  const state = states.length ? states.join('; ') : 'new version';
  rows.push([m.name, m.version, topStable, state]);
}

// How the MCP gets the SDK decides what to check:
//  - runtime dependency: users install the SDK from the registry, so the range must accept the SDK in this tree;
//  - dev dependency: the SDK is bundled into the MCP at build time (upstream's build.mjs), so users never
//    install it and there is no range to satisfy; the SDK version is then only a record of what was bundled.
const [sdk, mcp] = manifests;
const runtimeRange = mcp.dependencies?.[sdk.name];
const devRange = mcp.devDependencies?.[sdk.name];
const notes = [];
if (runtimeRange) {
  if (semver.valid(sdk.version) && !semver.satisfies(sdk.version, runtimeRange, { includePrerelease: true })) {
    errors.push(`${mcp.name} asks for ${sdk.name}@${runtimeRange}, but this tree has ${sdk.version}; update the range`);
  }
} else if (devRange) {
  if (semver.valid(sdk.version) && !semver.satisfies(sdk.version, devRange, { includePrerelease: true })) {
    errors.push(`${mcp.name} bundles ${sdk.name}, but its range ${devRange} excludes this tree's ${sdk.version}; npm would bundle a registry copy instead of this tree's SDK`);
  } else {
    notes.push(`${mcp.name} bundles ${sdk.name} at build time (dev dependency ${devRange}); the range accepts this tree's ${sdk.version}.`);
  }
} else {
  warnings.push(`${mcp.name} does not list ${sdk.name} at all; the publish order assumption may be wrong`);
}

const table = [
  `### Package versions (${RELEASE ? 'release' : 'report'} mode, registry ${REGISTRY})`,
  '| package | in this tree | highest stable on registry | state |',
  '|---|---|---|---|',
  ...rows.map((r) => `| ${r.join(' | ')} |`),
  ...notes.map((n) => `\n${n}`),
].join('\n');
console.log(table);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${table}\n`);

for (const w of warnings) console.log(`::warning::${w}`);
for (const e of errors) console.log(`::error::${e}`);
process.exit(errors.length ? 1 : 0);