#!/bin/bash
# Compiles src/ (TypeScript) to dist/ (CommonJS + type declarations), then copies dist/ into the Node template's and the
# Todo (Node) sample's vektor-sdk/ folder, so each carries the SDK it was tested with. A plugin may only load files from its own folder,
# which is why the template has a copy rather than a path to this one.
#
#   ./build.sh            needs a TypeScript compiler: `npm install` here first (typescript is the only dev dependency),
#                         or TSC=/path/to/tsc ./build.sh
#
# The SDK has no runtime dependencies: dist/ needs nothing but Node.js 18 or later.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
TSC=${TSC:-./node_modules/.bin/tsc}
[[ -x "$TSC" ]] || { echo "No TypeScript compiler at $TSC: run npm install, or set TSC." >&2; exit 1; }
rm -rf dist
"$TSC" -p .
template=../../templates/node/vektor-sdk
rm -rf "$template"
mkdir -p "$template"
cp -R dist/. "$template"/
# The Todo sample in Node carries the same copy, for the same reason.
sample=../../samples/todo-node/vektor-sdk
rm -rf "$sample"
mkdir -p "$sample"
cp -R dist/. "$sample"/
echo "built dist/ and copied it to templates/node/vektor-sdk/ and samples/todo-node/vektor-sdk/"
