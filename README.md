# The Vektor plugin registry

The registry is two files in a public repository — `index.json` and its signature `index.json.sig` — plus the plugin packages
their authors host themselves. Vektor downloads the index only when you open **Settings ▸ Plugins ▸ Get Plugins**, refuses it
unless the signature verifies with the key built into Vektor, and installs a package only if its SHA-256 equals the one in the
signed index. The project website lists plugins by reading the same `index.json`.

This folder is the **layout and tooling** of that repository. Creating the repository and the signing key are the project
owner's steps; nothing here creates a repository, and no key is stored in it.

## Layout

```
plugins/<id>.json      one file per plugin: what an author submits by pull request
packages/<id>/          zips, icons and READMEs of first-party plugins, served from raw.githubusercontent.com
revoked.json           versions that must not be installed: [{ "id", "version", "reason" }]
index.json             generated: vektor-registry build        (maintainer, after merging)
index.json.sig         generated: vektor-registry sign         (maintainer; the private key stays on their Mac)
index.schema.json      the JSON Schema of an entry and of the index
ci/pull-request-check.yml   the pull-request check as a GitHub Actions workflow (not active yet: it needs the tool published first)
```

An entry has the fields of `index.schema.json`; see `plugins/com.vektor-commander.cloudflare-tunnel.json`. The important ones:
`id`, `name`, `publisher`, `summary`, `categories`, `icon`, `readme`, `permissions`, `screenshots`, `images` and `versions`
(`version`, `api`, `minVektor`, `url`, `sha256`, `changelog`).

* **`permissions` must be exactly the permissions in the plugin's `plugin.json`.** The check compares them.
* **`images`** lists the only remote images a README may show. An image the README uses that is not listed is not loaded.
* **Every address is https.** The package `url` is a zip of the plugin folder, hosted by you (a release asset is fine).
* **`sha256`** is the lowercase hex SHA-256 of that zip: `shasum -a 256 hello-0.1.0.zip`.

## For plugin authors: submit a plugin

1. Write the plugin with the author kit (`docs/plugins/`), check it with `vektor-plugin validate` and test it with
   `vektor-plugin test`.
2. Zip the plugin folder (`cd` into it, `zip -r ../hello-0.1.0.zip .`), publish the zip at an https address, compute its SHA-256.
3. Open a pull request that adds `plugins/<id>.json` (or adds a version to your file).
4. The automatic check must pass: valid manifest, reachable package, matching SHA-256, permissions matching the manifest, no id
   collisions. Run it yourself first:

       vektor-registry check . --plugin com.example.hello

   A plugin that asks for a permission it does not need, or whose entry and manifest disagree, is not merged.

## For the maintainer: publish

After merging:

    vektor-registry build .                            # plugins/*.json + revoked.json → index.json
    vektor-registry check .                            # everything, once more
    vektor-registry sign . --key ~/keys/vektor-registry.key
    vektor-registry verify . --public-key <the key built into Vektor>

`sign` refuses a key file that lies inside a Git repository or that other users can read. Commit `index.json` and
`index.json.sig` together. **Revoking** a version is a line in `revoked.json` (with a reason in plain words), then build and
sign again: Vektor turns the installed version off the next time its owner opens Get Plugins or checks for updates.

The production public key is the one thing Vektor needs from the owner: it goes into `PluginRegistryKeys` in
`Explorer/State/Plugins/Registry/PluginRegistryConfiguration.swift`, with the address of `index.json`. Until then release
builds say that the registry is not configured, and fetch nothing.

## The tools

They are compiled Swift (`Packages/PluginTools`) because the system `openssl` has no Ed25519, and because the check must apply
the very rules Vektor applies (manifest validation, the package reader, the signature check):

    swift build --package-path Packages/PluginTools -c release
    Packages/PluginTools/.build/release/vektor-registry <command>
    Packages/PluginTools/.build/release/vektor-plugin <command>

| Command | What it does |
|---|---|
| `vektor-registry build <folder>` | merges the entries and revocations into `index.json` |
| `vektor-registry check <folder> [--plugin id]… [--all-versions]` | the pull-request check |
| `vektor-registry sign <folder> --key <file>` | writes `index.json.sig` |
| `vektor-registry verify <folder> --public-key <key>` | checks the signature the way Vektor does |
| `vektor-registry test-keygen <folder>` | a **test** key pair, only into a temporary folder |

`--local-test` allows `http://127.0.0.1` (the local test registry of `scripts/probe-plugin-registry.sh`); never use it for the
real registry.
