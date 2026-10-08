#!/bin/bash
# Which registry entries does a pull request touch?
#
#   changed-entries.sh <base-rev> <head-rev>      run inside the registry checkout
#
# Compares `<base>...<head>` (the pull request's own changes, from the merge base) and prints one line per finding on stdout,
# tab-separated, in a stable order:
#
#   all              revoked.json changed: check every entry
#   plugin <id>      plugins/<id>.json was added or modified: check this entry
#   problem <text>   something the check cannot approve on its own; the pull request fails with this text
#
# Never prints "plugin" for a path it does not fully understand. Exit status 0 whenever it could compare; 2 on wrong usage or
# an unusable revision (a pull request that could not be compared must not pass by accident).
#
# Why `--raw -z --no-renames`, not `--name-only` + sed (measured):
#   * `--name-only` lists a deleted entry like any other, and `--name-status` reports a rename as `R100 old new` (two paths).
#     With `--no-renames` a rename is a deletion of the old name plus an addition of the new one, which is what it means
#     here: the old id disappears from the registry.
#   * `-z` keeps a file name with spaces, quotes or `$(...)` in it as one literal token, never quoted or split.
#   * `--raw` carries the new file mode, so a symlink (120000) or submodule (160000) named plugins/x.json is refused instead
#     of being read through by the check.
# Nothing here executes anything from the pull request: names are only compared against patterns.
set -u
[[ $# -eq 2 ]] || { echo "usage: changed-entries.sh <base-rev> <head-rev>" >&2; exit 2; }
base=$1 head=$2
# A revision is a name or a commit, never an option: "-..." would reach git diff as a flag.
[[ "$base" != -* && "$head" != -* && -n "$base" && -n "$head" ]] || { echo "changed-entries: a revision may not be empty or start with \"-\"" >&2; exit 2; }

raw=$(mktemp "${TMPDIR:-/tmp}/vektor-changed.XXXXXX") || exit 2
trap 'rm -f "$raw"' EXIT
git diff --raw -z --no-renames "$base...$head" -- >"$raw" || { echo "changed-entries: could not compare $base...$head" >&2; exit 2; }

plugins=""
all=0
problems=""
add_problem() { problems+="problem"$'\t'"$1"$'\n'; }

while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    # meta = ":<old mode> <new mode> <old sha> <new sha> <status>"
    set -- $meta
    newmode=$2 status=$5
    # The name as it may appear in a message: a newline, tab or other control character would otherwise forge a line of this
    # script's output ("plugin<TAB>x") or of the report.
    shown=${path//[^[:print:]]/?}
    # A link or submodule anywhere (not only at plugins/<id>.json: a linked plugins/ folder or revoked.json would be read
    # through by the check) is never a submission.
    if [[ "$status" != D && "$newmode" != "100644" && "$newmode" != "100755" ]]; then
        add_problem "$shown is not a regular file (mode $newmode); the registry holds plain files only."
        continue
    fi
    case "$path" in
        revoked.json)
            case "$status" in
                D) add_problem "revoked.json was deleted; removing the revocation list needs the owner." ;;
                *) all=1 ;;
            esac ;;
        plugins/*)
            name=${path#plugins/}
            if [[ "$name" != */* && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.json$ ]]; then
                id=${name%.json}
                case "$status" in
                    D) add_problem "$shown was removed: removal, needs the owner. Taking a published plugin out of the registry is a revocation decision, not a submission." ;;
                    A|M) plugins+="$id"$'\n' ;;   # a regular file: links and submodules were refused above
                    *) add_problem "$shown has a change of kind \"$status\" that the check does not understand; needs the owner." ;;
                esac
            else
                add_problem "$shown is not named plugins/<id>.json (letters, digits, dots, dashes and underscores; no sub-folders); the check cannot read it."
            fi ;;
        ci/*|.github/*)
            add_problem "$shown changes the pull-request check itself; needs the owner." ;;
        *) ;;   # README, example, anything else: not a registry entry
    esac
done <"$raw"

[[ $all -eq 1 ]] && printf 'all\n'
[[ -n "$plugins" ]] && printf '%s' "$plugins" | LC_ALL=C sort -u | while IFS= read -r id; do printf 'plugin\t%s\n' "$id"; done
printf '%s' "$problems"
exit 0
