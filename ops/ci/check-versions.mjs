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
import { readFileSync, appendFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const RELEASE = process.argv.includes('--release');
const REGISTRY = process.env.REGISTRY || 'https://registry.npmjs.org/';
const PACKAGES = ['packages/agent-sdk', 'packages/mcp']; // publish order: the SDK first, the MCP second

// semver ships inside npm, so nothing needs installing.
const npmRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
const semver = createRequire(import.meta.url)(join(npmRoot, 'npm', 'node_modules', 'semver'));

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
  let state = 'new version';
  if (reg.versions.includes(m.version)) {
    state = 'already published';
    if (RELEASE) errors.push(`${where}: this version is already on the registry; bump it`);
  } else if (!semver.prerelease(m.version) && topStable !== 'none' && semver.lt(m.version, topStable)) {
    state = `lower than ${topStable}`;
    if (RELEASE) errors.push(`${where}: lower than the highest stable version on the registry (${topStable})`);
  }
  rows.push([m.name, m.version, topStable, state]);
}

// The MCP depends on the SDK through the registry, not the workspace: the range it asks for must
// accept the SDK version in this tree, or users would get a different SDK than the one tested here.
const [sdk, mcp] = manifests;
const range = mcp.dependencies?.[sdk.name];
if (!range) {
  errors.push(`${mcp.name}: does not depend on ${sdk.name}; the publish order assumption is wrong`);
} else if (semver.valid(sdk.version) && !semver.satisfies(sdk.version, range, { includePrerelease: true })) {
  errors.push(`${mcp.name} asks for ${sdk.name}@${range}, but this tree has ${sdk.version}; update the range`);
}

const table = [
  `### Package versions (${RELEASE ? 'release' : 'report'} mode, registry ${REGISTRY})`,
  '| package | in this tree | highest stable on registry | state |',
  '|---|---|---|---|',
  ...rows.map((r) => `| ${r.join(' | ')} |`),
].join('\n');
console.log(table);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${table}\n`);

for (const w of warnings) console.log(`::warning::${w}`);
for (const e of errors) console.log(`::error::${e}`);
process.exit(errors.length ? 1 : 0);
