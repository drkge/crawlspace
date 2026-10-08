#!/bin/bash
# Builds the Lighthouse runtime for one architecture: Node plus the pinned Lighthouse package,
# as lighthouse-runtime-<version>-<arch>.tar.gz in dist/.
#
#   Tools/Release/make-lighthouse-runtime.sh arm64|x64
#
# The version names both pins, so the app's updater fetches a new runtime only when one changes.
set -euo pipefail

cd "$(dirname "$0")/../.."
arch=${1:?arm64 or x64}
node_version=$(tr -d '[:space:]' < Tools/Lighthouse/node-version)
lighthouse_version=$(node -p "require('./Tools/Lighthouse/package.json').dependencies.lighthouse")
version="node${node_version}-lighthouse${lighthouse_version}"
output="dist/lighthouse-runtime-${version}-${arch}.tar.gz"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# Node, checked against the checksums nodejs.org publishes.
archive="node-v${node_version}-darwin-${arch}.tar.gz"
curl -fsSL "https://nodejs.org/dist/v${node_version}/${archive}" -o "$staging/$archive"
curl -fsSL "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" -o "$staging/SHASUMS256.txt"
(cd "$staging" && grep " ${archive}\$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null)
mkdir -p "$staging/runtime/node/bin"
tar -xzf "$staging/$archive" -C "$staging" "node-v${node_version}-darwin-${arch}/bin/node" "node-v${node_version}-darwin-${arch}/LICENSE"
mv "$staging/node-v${node_version}-darwin-${arch}/bin/node" "$staging/runtime/node/bin/node"
mv "$staging/node-v${node_version}-darwin-${arch}/LICENSE" "$staging/runtime/node/LICENSE"

# Lighthouse is plain JavaScript, so the same install works for either architecture.
mkdir -p "$staging/runtime/lighthouse"
cp Tools/Lighthouse/package.json Tools/Lighthouse/package-lock.json "$staging/runtime/lighthouse/"
(cd "$staging/runtime/lighthouse" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null)
test -f "$staging/runtime/lighthouse/node_modules/lighthouse/cli/index.js"

mkdir -p dist
tar -C "$staging/runtime" -czf "$output" node lighthouse
echo "Wrote $output ($(du -h "$output" | cut -f1))"
echo "version=$version"
