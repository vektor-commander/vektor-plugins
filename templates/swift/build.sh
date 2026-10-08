#!/bin/bash
# Build the plugin program into bin/hello and sign it ad hoc. Needs the Command Line Tools (xcode-select --install) on the AUTHOR's
# Mac only: the user of the plugin needs nothing.
#
#   ./build.sh              one architecture (arm64): what the registry's check expects
#   ./build.sh universal    arm64 + x86_64 in one file, for Macs of both kinds
#
# Run it again after every change to main.swift: a change after signing invalidates the signature and macOS kills the program.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p bin
target_arm=arm64-apple-macos13
if [[ "${1:-}" == "universal" ]]; then
    swiftc -O -target "$target_arm" Sources/main.swift -o bin/hello-arm64
    swiftc -O -target x86_64-apple-macos13 Sources/main.swift -o bin/hello-x86_64
    lipo -create bin/hello-arm64 bin/hello-x86_64 -output bin/hello
    rm -f bin/hello-arm64 bin/hello-x86_64
else
    swiftc -O -target "$target_arm" Sources/main.swift -o bin/hello
fi
codesign --force -s - bin/hello         # ad hoc: no Developer ID and no notarization are needed
codesign --verify bin/hello
lipo -archs bin/hello
