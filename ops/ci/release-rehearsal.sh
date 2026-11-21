#!/usr/bin/env bash
# Rehearse the package release against the throwaway registry (registry-up.sh must have run).
# Publishes ONLY to that local registry. It edits the two package.json files temporarily and
# restores them on exit. Needs: Node, npm, jq, a finished `npm ci`.
#
# The rehearsal, in the order a real release would go:
#   1. pre-release under dist-tag "next": SDK first, then MCP
#   2. install the MCP from the registry like a user would, check it pulled OUR SDK, start it
#   3. the stable release (dist-tag "latest"), SDK first, then MCP
#   4. drills that must be BLOCKED: same version again, a lower version, a mismatched SDK range
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

REGISTRY="${REGISTRY:-http://127.0.0.1:4873/}"
export REGISTRY
SDK="@clevercon/agent-sdk"
MCP="@clevercon/mcp"
MANIFESTS=(packages/agent-sdk/package.json packages/mcp/package.json)

case "$REGISTRY" in
  http://127.0.0.1:* | http://localhost:*) ;;
  *) echo "refusing to run: REGISTRY must be a local address, got $REGISTRY" >&2; exit 1 ;;
esac
if ! git diff --quiet -- "${MANIFESTS[@]}"; then
  echo "the two package.json files have uncommitted changes; this script edits them temporarily" >&2
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() {
  git checkout -- "${MANIFESTS[@]}"
  rm -rf "$WORK"
}
trap cleanup EXIT

# A throwaway token: the local registry accepts any, npm just insists on having one.
host="${REGISTRY#http://}"
host="${host%/}"
printf 'registry=%s\n//%s/:_authToken=rehearsal-not-a-secret\n' "$REGISTRY" "$host" > "$WORK/npmrc"
NPM_CONFIG_USERCONFIG="$WORK/npmrc"
export NPM_CONFIG_USERCONFIG

PASSED=()
pass() { PASSED+=("$1"); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Run a command that must exit non-zero. Its output is shown without CI error annotations,
# so an expected block does not paint the run red.
expect_blocked() {
  local what="$1"
  shift
  if "$@" > "$WORK/blocked.log" 2>&1; then
    sed 's/^::error::/   /' "$WORK/blocked.log"
    fail "$what was NOT blocked"
  fi
  sed 's/^::error::/   (expected) /' "$WORK/blocked.log"
  pass "$what is blocked"
}

pkg_version() { node -p "JSON.parse(require('fs').readFileSync('$1','utf8')).version"; }
next_patch() {
  local core="${1%%-*}" major minor patch
  IFS=. read -r major minor patch <<< "$core"
  echo "${major}.${minor}.$((patch + 1))"
}
# set_versions SDK_VERSION MCP_VERSION: what a person does in the release PR (the MCP asks for the new SDK).
set_versions() {
  node -e '
    const fs = require("fs");
    const [sdkV, mcpV] = process.argv.slice(1);
    const edit = (f, fn) => { const j = JSON.parse(fs.readFileSync(f, "utf8")); fn(j); fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n"); };
    edit("packages/agent-sdk/package.json", (j) => { j.version = sdkV; });
    edit("packages/mcp/package.json", (j) => {
      j.version = mcpV;
      // keep whichever list holds the SDK (runtime dependency, or dev dependency when it is bundled) in step
      for (const list of ["dependencies", "devDependencies"]) {
        if (j[list] && j[list]["@clevercon/agent-sdk"]) j[list]["@clevercon/agent-sdk"] = "^" + sdkV;
      }
    });
  ' "$1" "$2"
}
check_release() { node ops/ci/check-versions.mjs --release; }
# publish_both [extra npm flags]: SDK first, because the MCP depends on it.
publish_both() {
  npm publish -w "$SDK" --registry "$REGISTRY" "$@"
  npm publish -w "$MCP" --registry "$REGISTRY" "$@"
}

base_sdk="$(pkg_version packages/agent-sdk/package.json)"
base_mcp="$(pkg_version packages/mcp/package.json)"
new_sdk="$(next_patch "$base_sdk")"
new_mcp="$(next_patch "$base_mcp")"
pre_sdk="${new_sdk}-next.1"
pre_mcp="${new_mcp}-next.1"
sdk_is_runtime_dep="$(node -p "JSON.parse(require('fs').readFileSync('packages/mcp/package.json','utf8')).dependencies?.['@clevercon/agent-sdk'] ? 'yes' : 'no'")"
echo "tree: ${SDK}@${base_sdk}, ${MCP}@${base_mcp}; rehearsing ${new_sdk} / ${new_mcp}"

echo "== 1. pre-release under dist-tag next"
set_versions "$pre_sdk" "$pre_mcp"
check_release
publish_both --tag next
[ "$(npm view "$SDK" dist-tags.next --registry "$REGISTRY")" = "$pre_sdk" ] || fail "SDK tag next is wrong"
[ "$(npm view "$MCP" dist-tags.next --registry "$REGISTRY")" = "$pre_mcp" ] || fail "MCP tag next is wrong"
pass "pre-release published, SDK then MCP, under next"

echo "== 2. install like a user and start the server"
consumer="$WORK/consumer"
mkdir "$consumer"
(
  cd "$consumer"
  npm init -y > /dev/null
  npm install "${MCP}@next" --registry "$REGISTRY" --no-audit --no-fund
)
if [ "$sdk_is_runtime_dep" = yes ]; then
  installed_sdk="$(pkg_version "$consumer/node_modules/@clevercon/agent-sdk/package.json")"
  [ "$installed_sdk" = "$pre_sdk" ] || fail "the MCP pulled SDK $installed_sdk, expected $pre_sdk"
  pass "installed MCP uses the SDK from this release ($installed_sdk)"
else
  [ ! -e "$consumer/node_modules/@clevercon/agent-sdk" ] || fail "the SDK was installed although the MCP should bundle it"
  pass "installed MCP is self-contained (SDK bundled, not installed)"
fi
reply="$(cd "$consumer" && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | timeout 60 ./node_modules/.bin/clevercon-mcp)"
jq -e 'select(.id == 1) | .result.tools | length > 0' <<< "$reply" > /dev/null || fail "the installed MCP did not list its tools"
pass "installed MCP starts and lists its tools"

echo "== 3. stable release under latest"
set_versions "$new_sdk" "$new_mcp"
check_release
publish_both
[ "$(npm view "$SDK" dist-tags.latest --registry "$REGISTRY")" = "$new_sdk" ] || fail "SDK tag latest is wrong"
[ "$(npm view "$MCP" dist-tags.latest --registry "$REGISTRY")" = "$new_mcp" ] || fail "MCP tag latest is wrong"
[ "$(npm view "$MCP" dist-tags.next --registry "$REGISTRY")" = "$pre_mcp" ] || fail "MCP tag next moved"
pass "stable published under latest, next left alone"

echo "== 4. drills that must be blocked"
expect_blocked "a repeated version (version check)" check_release
expect_blocked "a repeated version (registry)" npm publish -w "$MCP" --registry "$REGISTRY"
set_versions "$base_sdk" "$base_mcp"
expect_blocked "a lower version" check_release
if [ "$sdk_is_runtime_dep" = yes ]; then
  node -e '
    const fs = require("fs");
    const f = "packages/mcp/package.json";
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.dependencies["@clevercon/agent-sdk"] = "^0.0.1";
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  '
  expect_blocked "an MCP range that excludes this SDK" node ops/ci/check-versions.mjs
else
  echo "skipped: range drill (the MCP bundles the SDK, so there is no runtime range)"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Release rehearsal (local registry only)"
    for p in "${PASSED[@]}"; do echo "- $p"; done
    echo
    echo "Not covered here: npm provenance and trusted publishing (they need the real npm and Sigstore)."
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "all ${#PASSED[@]} checks passed"