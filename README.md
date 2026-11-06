# Xenon

Safe script sync for Roblox: disk -> Studio. Built because Argon deletes Studio-only content.

File types (same rules as Rojo / Argon, so Wally packages work):

| File | Becomes |
| --- | --- |
| `.server.luau` / `.client.luau` / `.luau` (or `.lua`) | Script / LocalScript / ModuleScript |
| `Folder/init.*.luau`, `init.meta.json`, `Name.meta.json` | folder is the script / className / Disabled |
| `Folder/default.project.json` | nested project (every Wally package in `_Index`) |
| `.rbxm` / `.rbxmx` / `.model.json` | model, built by the plugin (meshes via AssetService, refs rewired) |
| `.json` / `.toml` | ModuleScript returning the data |
| `.txt` | StringValue |

Wally: map `Packages` / `ServerPackages` in `default.project.json`, run `wally install`, Xenon picks them up.

Rules:
- scripts are created and updated; models are only created when missing (tagged `xenon_hash`, disk changes reported)
- never deletes anything in Studio. Files removed on disk are only reported
- checksum on both sides: only scripts whose code really differs are sent
- shows the plan first (create / update / conflicts / delete 0), applies on Apply
- live: edits reach Studio within ~1s. Batches over 20, or any conflict, wait for Apply
- conflict = script edited in Studio AND on disk since the last sync -> left untouched
- locked to `placeIds` from the project file

## Use

```
# 1. in the game folder (needs lune in rokit.toml)
lune run "D:/coding/roblox work/tools/xenon/src/server.luau" default.project.json 34872

# 2. Studio: Plugins tab -> Xenon -> Connect -> review -> Apply
```

Build / reinstall the plugin after editing `plugin/xenon_plugin.luau`:

```
cd "D:/coding/roblox work/tools/xenon"
lune run build_plugin.luau
```

Tests: `lune run tests/mapping_test.luau`

## Files

| File | Job |
| --- | --- |
| `src/mapping.luau` | project.json + files -> instance paths (argon / rojo naming rules) |
| `src/checksum.luau` | same hash on server and plugin (crlf normalized) |
| `src/server.luau` | watches files, HTTP api on localhost (`/info`, `/snapshot`, `/sources`, `/changes`) |
| `plugin/xenon_plugin.luau` | Studio side: connect, diff, review, apply, live poll |
| `build_plugin.luau` | packs the plugin into `%LOCALAPPDATA%/Roblox/Plugins/Xenon.rbxm` |

## Not in v1

Studio -> disk (pull), syncing UI / models / non-script files, deletes.
