#!/bin/bash
# Run the pull-request check on this Mac, the way the workflow runs it, without GitHub.
#
#   run-check-locally.sh <registry-repo> <base-rev> <head-rev> --tool <zip> --sha <sha256> [--local-test]
#
# <registry-repo> is a Git repository (the registry, or a fixture of it); <base-rev> and <head-rev> are revisions in it (a
# branch, a tag, a commit). The repository itself is only read: the head revision is cloned into a temporary folder and checked
# out there, which is what `actions/checkout` gives the workflow, and pr-check.sh runs inside that clone with the same
# arguments the workflow passes. --tool is a local zip (the zip of the tools release); its SHA-256 is verified
# against --sha exactly as in the workflow. --local-test lets the check read packages from http://127.0.0.1 (a local test
# server); never use it against a real registry.
#
# Example, after a release build:
#   ci/run-check-locally.sh ~/vektor-plugins origin/main my-branch \
#       --tool build/registry-tool/1.0.0/vektor-plugin-tools-macos.zip --sha <the hash the release script printed>
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -ge 3 ]] || { sed -n '2,16p' "${BASH_SOURCE[0]}" >&2; exit 2; }
repo=$1 base=$2 head=$3; shift 3
tool="" sha="" extra=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool) tool=${2:-}; shift 2 ;;
        --sha) sha=${2:-}; shift 2 ;;
        --local-test) extra+=(--local-test); shift ;;
        *) echo "run-check-locally.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "$tool" && -n "$sha" ]] || { echo "run-check-locally.sh: --tool and --sha are required" >&2; exit 2; }

[[ "$base" != -* && "$head" != -* ]] || { echo "run-check-locally.sh: a revision may not start with \"-\"" >&2; exit 2; }
base_sha=$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}") || { echo "run-check-locally.sh: no revision \"$base\" in $repo" >&2; exit 2; }
head_sha=$(git -C "$repo" rev-parse --verify --quiet "$head^{commit}") || { echo "run-check-locally.sh: no revision \"$head\" in $repo" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/vektor-local-check.XXXXXX") || exit 2
trap 'rm -rf "$scratch"' EXIT
git clone -q --no-checkout -- "$repo" "$scratch/checkout" || exit 2
git -C "$scratch/checkout" checkout -q --detach "$head_sha" || exit 2

# A relative tool path must still resolve after pr-check.sh changes directory.
case "$tool" in /*|https://*) ;; *) tool="$PWD/$tool" ;; esac
bash "$HERE/pr-check.sh" --registry "$scratch/checkout" --base "$base_sha" --head "$head_sha" \
    --tool "$tool" --sha "$sha" --work "$scratch/work" ${extra[@]+"${extra[@]}"}
