#!/bin/bash
# Build the plugin program into bin/board and sign it ad hoc. Needs the Command Line Tools (xcode-select --install) on the
# AUTHOR's Mac only: the user of the plugin needs nothing.
#
# The program is built for Apple silicon (arm64) only: Vektor runs on nothing else, and it is what the registry's check expects.
#
# Run it again after every change: a change after signing invalidates the signature and macOS kills the program.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p bin
build() {  # triple -> path of the built program
    swift build -c release --product board --triple "$1" >&2
    echo "$(swift build -c release --triple "$1" --show-bin-path)/board"   # --show-bin-path with --product prints an error
}
cp "$(build arm64-apple-macosx13.0)" bin/board
codesign --force -s - bin/board         # ad hoc: no Developer ID and no notarization are needed
codesign --verify bin/board
lipo -archs bin/board
