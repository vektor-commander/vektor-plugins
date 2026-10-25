#!/bin/bash
# Build the plugin program into bin/board and sign it ad hoc. Needs the Command Line Tools (xcode-select --install) on the
# AUTHOR's Mac only: the user of the plugin needs nothing.
#
#   ./build.sh              one architecture (arm64): what the registry's check expects
#   ./build.sh universal    arm64 + x86_64 in one file, for Macs of both kinds
#
# Run it again after every change: a change after signing invalidates the signature and macOS kills the program.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p bin
build() {  # triple -> path of the built program
    swift build -c release --product board --triple "$1" >&2
    echo "$(swift build -c release --triple "$1" --show-bin-path)/board"   # --show-bin-path with --product prints an error
}
if [[ "${1:-}" == "universal" ]]; then
    arm=$(build arm64-apple-macosx13.0)
    intel=$(build x86_64-apple-macosx13.0)
    lipo -create "$arm" "$intel" -output bin/board
else
    cp "$(build arm64-apple-macosx13.0)" bin/board
fi
codesign --force -s - bin/board         # ad hoc: no Developer ID and no notarization are needed
codesign --verify bin/board
lipo -archs bin/board
