# Maintaining the registry

For the registry's maintainer. Plugin users start at the [README](README.md); plugin authors at
[CONTRIBUTING.md](CONTRIBUTING.md).

## After merging a pull request

Run in a clean checkout of `main`, with the merged entry in place:

    vektor-registry build .                                   # plugins/*.json + revoked.json → index.json
    vektor-registry check .                                   # every entry, once more
    vektor-registry sign . --key <your key file>               # writes index.json.sig
    vektor-registry verify . --public-key <the key built into Vektor>

Commit `index.json` and `index.json.sig` **together**, in one commit. Vektor refuses an index whose signature does not match, so a
pushed `index.json` without its new signature turns Get Plugins off for everyone until the signature follows.

## Revoking a version

Add a line to `revoked.json`: `{ "id": "<plugin id>", "version": "<version>", "reason": "<plain words for the user>" }`, then build,
check, sign and verify as above. Vektor turns that version off on every Mac the next time its owner opens Get Plugins or checks for
updates, and shows the reason.

## The signing key

* The private key never goes into any repository, this one included. `vektor-registry sign` refuses a key file that lies inside a
  Git work tree or that other users can read.
* The matching public key is built into Vektor. Replacing the key therefore means a Vektor release with the new public key **before**
  the registry is signed with it.

## The pull-request check

The workflow is `ci/pull-request-check.yml` with the scripts in `ci/`. It runs `vektor-registry check` on exactly the entries a pull
request adds or changes, and fails a pull request that removes or renames an entry, adds a link, or touches `ci/` or `.github/`
(those need the maintainer). A green check is not approval: every change is still reviewed by hand.

To arm it (once):

1. Publish the tools release: a release tagged `tools-<version>` with the asset `vektor-plugin-tools-macos.zip`, built from the
   Vektor source tree with its release script, which prints the zip's SHA-256. A rebuild gives a different hash (the zip stores file
   times), so publish the very zip whose hash was printed.
2. Write that SHA-256 into `TOOL_SHA256` in `ci/pull-request-check.yml` (the placeholder is refused by the scripts), and copy the
   file to `.github/workflows/pull-request-check.yml`.
3. Repository settings: require approval for workflow runs from outside collaborators, and require the check before merging into
   `main`.
4. Open one test pull request with a deliberately wrong `sha256` in a new entry: the check must fail, naming the plugin and the hash.
   Fix it and the check must pass. Close the pull request without merging.

A new tools version repeats steps 1–2 with the new tag and hash. The workflow downloads the asset and compares its SHA-256 **before**
opening it, so a replaced asset is refused.

To try the check on a Mac without GitHub:

    ci/run-check-locally.sh <registry clone> origin/main <branch> --tool <zip> --sha <hash>
