# Release packaging

The **Release package** workflow (`.github/workflows/release-package.yml`) rebuilds the Windows release zips so a CS2 update can be fixed without waiting for upstream.

It starts from the upstream release named in `versions.env` (Panel, `gameinfo.gi`, bot profiles, configs) and lays these over it:

| Layer | Source |
| --- | --- |
| CounterStrikeSharp | `CSS_TAG` with-runtime Windows zip |
| Metamod:Source | `MMS_BUILD` Windows dev build |
| CounterStrikeSharp plugins | built from the pinned submodules (BotAI, BotAimImprover, BotBuy, BotRandomizer, BotState, NadeSystem, RoundDamageRecap, BotController/BotHider managed parts) |
| Metamod plugins | BotController, BotHider, BotVision built from the pinned submodules |
| Plugin data | `addons/counterstrikesharp/data` from this repo |
| Content updater | `release/updater` (see below) |

Existing user configs in the base package (`addons/counterstrikesharp/configs/`, `metaplugins.ini`, Metamod `.vdf` files) are kept. Ray-Trace is kept from the base package.

## Content updater

Users install a package by hand once. After that, new releases are applied in place by double-clicking `CS2BotImprover-Update.cmd` in `game/csgo` (it runs `addons/cs2botimprover/update.ps1`, Windows PowerShell 5.1 or later, nothing to install). `-Check` shows what would change without touching anything.

How a release reaches an install:

1. Each package gets an install manifest, `addons/cs2botimprover/install.json`: version, build number (the workflow run number, which orders releases), variant, and the SHA-256 of every file it puts in `game/csgo`. The Panel `.exe` is not listed; the updater never touches it.
2. The release also carries `latest.json` (each package's URL, size and SHA-256) and `latest.json.sig`, an RSA-SHA256 signature made with the `UPDATE_SIGNING_KEY` secret. The public key and the feed URL (`releases/latest/download`) are written into `update.ps1` at build time.
3. The updater only proceeds if the signature checks out, the zip matches `latest.json`, and every file matches the manifest inside the zip.
4. It then compares three versions of each file: the last install manifest, what is on disk, and the new package.
   - Unchanged since the last install, or missing: updated.
   - Changed locally: code and game data (dll, gamedata, runtime) are updated anyway. Settings (`.cfg`, `.ini`, `.vdf`, `.json` configs, `gameinfo.gi`, `backup/`, `overrides/botprofile.vpk`) are kept, and listed if the release has a newer version of them.
   - Dropped from the package: removed, unless changed locally.
5. Every replaced or removed file is copied to `addons/cs2botimprover/backups/<time>/` first (the newest 3 are kept). If anything fails part-way, the update is rolled back.

`release/tests/test-updater.ps1` runs these cases against the built packages; the workflow's **updater-test** job runs it on Windows PowerShell 5.1 for every build, and a release is only published if it passes.

### Signing key (one-time setup)

Generate a key (Git for Windows includes `openssl`) and store it as a repository secret:

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out update-signing-key.pem
gh secret set UPDATE_SIGNING_KEY -R jkganzan13/CS2-Bot-Improver < update-signing-key.pem
```

Keep a copy of `update-signing-key.pem` somewhere safe and offline, then delete the working copy. Installed updaters only accept feeds signed with the key their release was built with, so **if the key is lost or replaced, every existing install has to be updated by hand once**. The run summary shows the key's SHA-256 so you can confirm which key signed a build.

Publishing fails if the secret is missing. Test builds without it are signed with a throwaway key (fine for the test job, useless for real installs).

## After a CS2 update

1. Wait for CounterStrikeSharp (and Metamod, if needed) to ship a build for the update.
2. Bump `CSS_TAG` / `MMS_BUILD` in `versions.env`.
3. Update any plugin submodule whose signatures broke (`git submodule update --remote <path>`), or fix the patch bytes in your own fork of that plugin.
4. Actions → **Release package** → Run workflow. Leave **release** off first; download the `packages` artifact and test it in CS2.
5. Run it again with **release** on to publish. It is marked as the latest release, which is what installed updaters pick up.

The run summary lists every component version and which files changed in each zip.

## Scope

- This fork ships Windows packages only; the base release's Linux zip is ignored.
- The Panel is copied from the base release (its Tauri backend isn't in this repo), and the content updater does not update it.
