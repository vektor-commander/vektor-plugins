#!/bin/bash
# The pull-request check, as one script. The workflow calls it; run-check-locally.sh calls the same one.
#
#   pr-check.sh --registry <checkout> --base <rev> --head <rev> --tool <https-url | zip> --sha <sha256> [--work <folder>]
#               [--local-test]
#
# 1. changed-entries.sh says which entries the pull request added or changed (or "all" for revoked.json) and what it cannot
#    approve (a removal, a path that is not plugins/<id>.json, a change to the check itself).
# 2. fetch-tool.sh downloads the tool and verifies its SHA-256 against the pinned value before anything runs.
# 3. `vektor-registry check <checkout> --plugin <id>...` (or without --plugin for "all") reports in plain words.
# The exit status is 0 only if there was nothing to refuse and the check passed. The report goes to stdout and, when
# $GITHUB_STEP_SUMMARY is set, to the job summary too.
#
# Nothing from the pull request is executed: its files are read as data by git and by the verified tool, which never runs a
# plugin. `--local-test` (http://127.0.0.1, for the fixture server) is for the local runner and is never passed by the workflow.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry="." base="" head="" tool="" sha="" work="" local_test=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry) registry=${2:-}; shift 2 ;;
        --base) base=${2:-}; shift 2 ;;
        --head) head=${2:-}; shift 2 ;;
        --tool) tool=${2:-}; shift 2 ;;
        --sha) sha=${2:-}; shift 2 ;;
        --work) work=${2:-}; shift 2 ;;
        --local-test) local_test=1; shift ;;
        *) echo "pr-check.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "$base" && -n "$head" && -n "$tool" ]] || { echo "usage: pr-check.sh --registry <checkout> --base <rev> --head <rev> --tool <url|zip> --sha <sha256> [--work <folder>]" >&2; exit 2; }
cd "$registry" || exit 2

own_work=0
if [[ -z "$work" ]]; then work=$(mktemp -d "${TMPDIR:-/tmp}/vektor-pr-check.XXXXXX") || exit 2; own_work=1; fi
[[ $own_work -eq 1 ]] && trap 'rm -rf "$work"' EXIT

report=""
say() { report+="$1"$'\n'; }
finish() {  # exit-code
    printf '%s' "$report"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        # An indented code block, not a ``` fence: the report carries text from the pull request (file names, manifest
        # fields), and a fence can be closed by a line holding ```; an indented block cannot be left from inside.
        { echo '### Plugin registry check'; echo; printf '%s' "$report" | sed 's/^/    /'; } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null
    fi
    exit "$1"
}

# Run with bash explicitly: a copy that lost its executable bit must not turn into "could not compare".
changes=$(bash "$HERE/changed-entries.sh" "$base" "$head"); rc=$?
[[ $rc -eq 0 ]] || { say "PULL REQUEST CHECK FAILED: the changes between $base and $head could not be compared."; finish 1; }

ids=() all=0 problems=()
while IFS=$'\t' read -r kind value; do
    case "$kind" in
        plugin)  # changed-entries.sh only prints ids of this shape; checked again because each becomes an argument of the tool
            if [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then ids+=("$value"); else problems+=("an entry id the check cannot pass on safely."); fi ;;
        all) all=1 ;;
        problem) problems+=("$value") ;;
    esac
done <<<"$changes"

failed=0
for p in ${problems[@]+"${problems[@]}"}; do say "problem: $p"; failed=1; done

if [[ $all -eq 0 && ${#ids[@]} -eq 0 ]]; then
    if [[ $failed -eq 1 ]]; then say "PULL REQUEST CHECK FAILED: ${#problems[@]} problem(s) found before any package was looked at."; finish 1; fi
    say "No registry entry was added or changed; nothing to check."
    finish 0
fi

fetched=$(bash "$HERE/fetch-tool.sh" "$tool" "$sha" "$work" 2>&1); rc=$?
say "$fetched"
[[ $rc -eq 0 ]] || { say "PULL REQUEST CHECK FAILED: the registry tool was not verified, so nothing was checked."; finish 1; }

# --all-versions: a pull request may change an older version's address or hash, and the tool checks only the newest without it.
args=(check . --all-versions)
if [[ $all -eq 1 ]]; then say "revoked.json changed: checking every entry."
else
    for id in "${ids[@]}"; do args+=(--plugin "$id"); done
    say "Checking: ${ids[*]}"
fi
[[ $local_test -eq 1 ]] && args+=(--local-test)
# Debug builds of the tool honour VEKTOR_REGISTRY_CHECK_CONTROL=skip-hash (a test control); the released tool
# does not contain it (the release build refuses one that does). Outside a local test it is removed anyway.
[[ $local_test -eq 1 ]] || unset VEKTOR_REGISTRY_CHECK_CONTROL

output=$("$work/tool/vektor-registry" "${args[@]}" 2>&1); rc=$?
say "$output"
[[ $rc -eq 0 ]] || failed=1
if [[ $failed -eq 1 ]]; then say "PULL REQUEST CHECK FAILED."; finish 1; fi
finish 0
