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

Existing user configs in the base package (`addons/counterstrikesharp/configs/`, `metaplugins.ini`, Metamod `.vdf` files) are kept. Ray-Trace is kept from the base package.

## After a CS2 update

1. Wait for CounterStrikeSharp (and Metamod, if needed) to ship a build for the update.
2. Bump `CSS_TAG` / `MMS_BUILD` in `versions.env`.
3. Update any plugin submodule whose signatures broke (`git submodule update --remote <path>`), or fix the patch bytes in your own fork of that plugin.
4. Actions → **Release package** → Run workflow. Leave **release** off first; download the `packages` artifact and test it in CS2.
5. Run it again with **release** on to publish.

The run summary lists every component version and which files changed in each zip.

## Scope

- This fork ships Windows packages only; the base release's Linux zip is ignored.
- The Panel is copied from the base release (its Tauri backend isn't in this repo).
