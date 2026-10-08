#!/bin/bash
# Fetch the registry tool and verify it BEFORE anything of it runs.
#
#   fetch-tool.sh <https-url | local-zip> <sha256> <work-folder>
#
# The workflow passes a fixed https address of a `vektor-plugins` release asset and the SHA-256 written in the workflow file;
# the local runner (run-check-locally.sh) passes a file. The zip is hashed first and only a zip whose SHA-256 equals the pinned
# value is opened: a replaced asset is refused with a message, and changing the value takes a reviewed commit. Nothing from it
# has run when the refusal comes. On success the tool is <work-folder>/tool/vektor-registry.
# The zip is the tools release, which also holds `vektor-plugin` (for authors). The check never needs it, so only
# `vektor-registry` and VERSION are unpacked, as before the author tool joined the zip.
set -u
[[ $# -eq 3 ]] || { echo "usage: fetch-tool.sh <https-url | zip-file> <sha256> <work-folder>" >&2; exit 2; }
source_arg=$1 expected=$2 work=$3

refuse() { echo "REFUSED: $1" >&2; exit 1; }

if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    refuse "the pinned SHA-256 in the workflow is not a 64-digit lowercase hex value (\"$expected\"). Publish the tools release and write the hash it prints into the workflow."
fi

mkdir -p "$work" || exit 2
zip="$work/vektor-plugin-tools-macos.zip"
rm -rf "$work/tool"
rm -f "$zip"

if [[ "$source_arg" == https://* ]]; then
    # https only (no redirect to http), TLS 1.2+, a size ceiling, a few retries. A failure here is the network's, not a verdict.
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-filesize 104857600 --retry 3 --output "$zip" "$source_arg" || refuse "the tool could not be downloaded from $source_arg"
elif [[ "$source_arg" != *://* && -f "$source_arg" ]]; then
    cp "$source_arg" "$zip" || exit 2
else
    refuse "\"$source_arg\" is neither an https address nor a file."
fi

actual=$(shasum -a 256 "$zip" | cut -d' ' -f1)
if [[ "$actual" != "$expected" ]]; then   # the verification: nothing is opened before this passes
    rm -f "$zip"
    refuse "the tool's SHA-256 is $actual, not the $expected pinned in the workflow. The release asset was replaced or the pinned value is out of date. Nothing was run."
fi

# Only the two named members are unpacked (never the whole archive), and the tool must be a plain file, not a link: the hash
# makes the zip the owner's, but nothing else in it has a reason to land on the runner.
mkdir "$work/tool" || exit 2
unzip -qq -o "$zip" vektor-registry -d "$work/tool" || refuse "the verified tool zip has no vektor-registry, or it could not be unpacked."
unzip -qq -o "$zip" VERSION -d "$work/tool" >/dev/null 2>&1
[[ -f "$work/tool/vektor-registry" && ! -L "$work/tool/vektor-registry" ]] || refuse "the verified tool zip's vektor-registry is not a plain file."
chmod 755 "$work/tool/vektor-registry"
echo "tool verified: SHA-256 $actual"
[[ -f "$work/tool/VERSION" && ! -L "$work/tool/VERSION" ]] && sed 's/^/  /' "$work/tool/VERSION"
exit 0
