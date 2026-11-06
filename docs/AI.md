# Xenon — specification for AI assistants

Machine-oriented reference. Every fact here matches the code in this repo (v0.3.0). When code and this file disagree, the code wins; update this file in the same change.

## 1. Identity

- **What:** one-way file sync for Roblox, disk → Roblox Studio, for projects laid out like Rojo / Argon (`default.project.json` + `src/`).
- **Parts:** a CLI + HTTP server on the developer's PC (Luau on Lune) and a Studio plugin (Luau).
- **Language:** Luau only. Runtime for the CLI/server: Lune 0.10.4 (pinned in `rokit.toml`). No other dependencies.
- **Repo:** `IAM9PASA/xenon` (private). Local path: `D:/coding/roblox work/tools/xenon`.

## 2. Invariants (never break these)

| ID | Rule |
| --- | --- |
| I1 | The only removal: `remove_scripts` sets `Parent = nil` (undoable, inside the recording) on a script whose file got a live `remove` change, when ALL hold: setting `sync_deletes` on, instance is a LuaSourceContainer of the entry's class, `checksum(Source) == entry.hash` (not edited in Studio, checked at plan and again at apply), no children. Otherwise it becomes a conflict / is kept. Full sync never removes. Folders, models and any other instance are never removed. No `Destroy` / `ClearAllChildren` anywhere. |
| I2 | Scripts are created or updated only when the checksum differs (or `Enabled` differs). |
| I3 | The first sync after Connect, any batch with a conflict, and live batches above `auto_apply_limit` (or any batch when `auto_apply` is off) MUST wait for the user's Apply. |
| I4 | A script edited in Studio since Xenon last synced it, and also changed on disk, is a conflict and MUST NOT be overwritten. |
| I5 | Models (`.rbxm`, `.rbxmx`, `.model.json`, `.txt`) are create-only. Existing ones are never replaced; changes are reported (`models_changed`). |
| I6 | If `placeIds` is non-empty and `game.PlaceId` (non-zero) is not in it, the plugin refuses to sync. |
| I7 | Every apply is one ChangeHistory recording named `Xenon sync` (one Ctrl+Z). |
| I8 | The server has no endpoint that requests deletion. File removals are reported as `kind = "remove"` changes; the plugin decides under I1. |
| I9 | Never store secrets (API keys) in the repo. Asphalt reads `ASPHALT_API_KEY` from the environment. |

## 3. Architecture

```
editor saves file
      │
      ▼
xenon serve (Lune)  ── rescans mapped roots every 1 s (mtime cache) ──► version counter + change log
      │  HTTP JSON, localhost:<port> (default 34872)
      ▼
Studio plugin ── polls /changes every poll_seconds ──► plan (create/update/conflicts/skip/models_changed)
      │                                                   │
      └── auto-apply small batches ◄──────────────────────┴── or wait for Apply button
```

| File | Responsibility |
| --- | --- |
| `xenon.luau` | CLI entry. Commands: `serve`, `build`, `test`, `version`, `help`. Resolves relative paths against env `XENON_CWD`. |
| `bin/xenon.cmd`, `bin/xenon` | Launchers. Set `XENON_CWD` to the caller's folder, `cd` into the xenon folder (so rokit finds Lune), run `lune run xenon.luau <args>`. |
| `src/server.luau` | Module `{ start(project_file, port) }`. Initial snapshot, HTTP server, rescan loop, change log (max 2000 items). |
| `src/mapping.luau` | `load_project(file)`, `snapshot(project, cache)`. Turns files into entries (section 5). |
| `src/model.luau` | `from_rbxm`, `from_model_json`, `from_text`, `from_instances` → instance trees (section 6); `data_module(contents, "json"|"toml")` → Luau source. |
| `src/checksum.luau` | `checksum(source) -> "<length> <hash>"`. CRLF → LF first. Rolling hash `h = (h*31 + byte) % 1000000007`. Same code runs in the plugin. |
| `src/diff.luau` | `diff.lines(old, new)` Myers line diff (common prefix/suffix trimmed, > 1000 edits → shown as full replace), `diff.fold(edits, context)`, `diff.count(edits)`. Pure Luau, used by the plugin's diff page, tested in `tests/diff_test.luau`. |
| `src/build.luau` | Packs `plugin/xenon_plugin.luau` (Script "Xenon") + `src/checksum.luau` and `src/diff.luau` (child ModuleScripts "checksum", "diff") into `Xenon.rbxm`, copies it to `%LOCALAPPDATA%/Roblox/Plugins/`. |
| `plugin/xenon_plugin.luau` | Studio side: UI (main, settings and diff pages, Live indicator), HTTP client, plan, apply, model builder, live poll. |
| `tests/mapping_test.luau`, `tests/wally_test.luau` | Plain Lune scripts; print `all ... tests passed` or error. Run via `xenon test`. |
| `assets/` | Original logo (SVG + PNG), `render_logo.js`. `asphalt.toml` uploads the PNGs as user 1316704411. |

## 4. CLI

```
xenon serve [project.json] [--port N | -p N]   default project: <XENON_CWD>/default.project.json, port 34872. Blocks; Ctrl+C stops.
xenon build                                    writes Xenon.rbxm + installs it to Studio's Plugins folder
xenon test                                     runs tests/*_test.luau, exit 1 on failure
xenon version | --version | -v                 prints "xenon <VERSION>" (VERSION constant in xenon.luau)
xenon help | --help | -h
```

Errors exit with code 1 and a `[xenon] ...` message (e.g. missing project file).

## 5. Mapping rules (`src/mapping.luau`)

`default.project.json` tree: every node with `$path` becomes a root `{ path = {"Service", ...}, dir = <project dir>/<$path> }`. Nested nodes (e.g. `StarterPlayer.StarterPlayerScripts`) are walked. A root's directory children map under that instance path; the root itself is not created (services exist).

| Disk | Entry |
| --- | --- |
| `Name.server.luau` / `.server.lua` | script, class `Script` |
| `Name.client.luau` / `.client.lua` | script, class `LocalScript` |
| `Name.luau` / `.lua` | script, class `ModuleScript` |
| `Folder/init.<kind>.luau` | the folder is that script; other files are its children |
| `Folder/init.meta.json` | folder `className` (container) or meta for the init script |
| `Name.meta.json` | meta for sibling `Name`: `properties.Disabled = true` or `properties.Enabled = false` → `disabled = true` |
| source starting with `--disable` | `disabled = true` |
| `Folder/default.project.json` | nested project: the folder is the project's `tree` (`$path` relative to that folder, `$className`, child nodes). Checked before init files. Every Wally package in `_Index` uses this. |
| `Name.rbxm` / `.rbxmx` | model entry (tree from file) |
| `Name.model.json` | model entry (Rojo JSON model) |
| `Name.txt` | model entry: StringValue with `Value` = file text |
| `Name.json` / `Name.toml` | script entry, class `ModuleScript`, source = generated `return { ... }` |
| `*.meta.json`, `*.project.json` | never instances |
| anything else (`.md`, `.png`, no extension...) | ignored |
| `init.*` files | consumed by their folder, never their own entry |

Entry order: parents before children (server `/snapshot` sorts by path length, then key).

### Entry shape (server side)

```lua
{
	key = "ReplicatedStorage/Modules/ui_kit", -- table.concat(path, "/")
	path = { "ReplicatedStorage", "Modules", "ui_kit" },
	class = "ModuleScript",      -- Studio ClassName to create
	-- exactly one of:
	source = "...",              -- script (LF line endings)
	folder = true,               -- container (Folder or init.meta className)
	model = { ...tree },         -- model (section 6)
	hash = "1234 98765",         -- checksum of source / raw file bytes; nil for folders
	disabled = false,            -- Script / LocalScript only; nil for ModuleScript and others
	file = "D:/.../ui_kit/init.luau",
}
```

## 6. Model tree format (`src/model.luau` ↔ plugin `build_node`)

```lua
node = {
	id = 1,                  -- unique within the tree, used by Ref values
	class = "Part",
	name = "Drop",
	props = { [PropertyName] = Value },   -- only values that differ from the class default
	attrs = { [AttributeName] = Value },
	tags = { "Tag" },
	children = { node, ... },
}
```

Value = array `{ "Type", ... }`:

| Type | Encoding | Decoded with |
| --- | --- | --- |
| string / number / boolean | `{ "string", v }` | v |
| Vector3 | `{ "Vector3", x, y, z }` | `Vector3.new` |
| Vector2 | `{ "Vector2", x, y }` | `Vector2.new` |
| Color3 | `{ "Color3", r, g, b }` (0-1) | `Color3.new` |
| UDim | `{ "UDim", scale, offset }` | `UDim.new` |
| UDim2 | `{ "UDim2", xs, xo, ys, yo }` | `UDim2.new` |
| CFrame | `{ "CFrame", 12 components }` | `CFrame.new(...)` |
| NumberRange | `{ "NumberRange", min, max }` | |
| Rect | `{ "Rect", minx, miny, maxx, maxy }` | |
| BrickColor | `{ "BrickColor", number }` | |
| EnumItem | `{ "EnumItem", "Material", "Glass" }` | `Enum[a][b]` |
| NumberSequence | `{ "NumberSequence", {{t, v, envelope}, ...} }` | |
| ColorSequence | `{ "ColorSequence", {{t, r, g, b}, ...} }` | |
| Font | `{ "Font", family, weightName, styleName }` | `Font.new` |
| Content | `{ "Content", "rbxassetid://..." }` | `Content.fromUri`, fallback to legacy property (`MeshContent`→`MeshId`, `XContent`→`X`) |
| Ref | `{ "Ref", id }` | set after the whole tree is built |

Rules:
- Properties come from Lune's reflection database: scriptability `ReadWrite` / `Custom`, plus every `Content` / `ContentId` property (asset fields are often "not scriptable"). Skipped: `Parent, Name, ClassName, Archivable, UniqueId, HistoryId, Capabilities, Sandboxed, SourceAssetId, Tags, Attributes, AttributesSerialize`.
- One root in a `.rbxm` → that instance renamed to the file name. Several roots → a Folder named after the file holding them.
- Refs to instances outside the tree are dropped.
- `MeshPart` with a mesh is created via `AssetService:CreateMeshPartAsync(Content.fromUri(uri))`, fallback `InsertService:CreateMeshPartAsync(uri, ...)`.
- Built model roots get attribute `xenon_hash = entry.hash`.

## 7. HTTP API (`src/server.luau`)

All responses are JSON. Errors: `{ "error": "..." }` with 400 / 404 / 500.

| Method + path | Request | Response |
| --- | --- | --- |
| `GET /info` | — | `{ name, placeIds: number[], version: number, session: string, scripts: number }` |
| `GET /snapshot` | — | `{ version, session, entries: PublicEntry[] }` (no sources/trees) |
| `POST /sources` | `{ keys: string[] }` | `{ [key]: string (script source) or table (model tree) }` |
| `GET /changes?since=N` | — | `{ version, session, changes: Change[] }` or `{ version, session, resync: true, changes: [] }` when N is older than the log **or newer than `version`** (server restarted) |

```lua
PublicEntry = { key, path, class, hash?, disabled?, folder?, model? (true), source? , tree? }
-- source / tree only inside /changes items (kind ~= "remove")
Change = { version: number, kind: "create" | "update" | "remove", entry: PublicEntry }
```

`version` increases by 1 per change and restarts at 0 with every `xenon serve` run. `session` is a new random id per run (`<os.time>-<random>`). The plugin stores the last seen version + session and asks `/changes?since=version`; a different session means "server restarted" → full resync.

## 8. Plugin algorithms (`plugin/xenon_plugin.luau`)

**connect():** `GET /info` → place check (I6) → `full_sync()` → start `poll_loop(loop_id)` (always, even if the first sync failed). `loop_id` bumps on connect/disconnect so an old loop exits.

**full_sync():** `GET /snapshot` → `plan_for(entries, live = false)` → nothing to do: "In sync"; else `show_review` (waits for Apply, I3).

**plan_for(entries, live):** for each entry (skip models if `sync_models` is off):
- not found in Studio → `create`
- model → if Studio instance has `xenon_hash` ≠ entry hash → `models_changed` (I5)
- folder → nothing
- Studio instance not a script or different ClassName → `skip`
- checksum or Enabled differs → `live` and Studio hash ≠ `known_hash[key]` and ≠ entry hash → `conflicts` (I4); else `update`
- equal → remember `known_hash[key]`

**apply(plan):** fetch sources/trees for create+update in batches of 80 → one ChangeHistory recording (I7) → models: `build_model`; scripts: `ensure(path, class)` (creates missing ancestors as Folder, never removes), `ScriptEditorService:UpdateSourceAsync`, set `Enabled`.

**poll_loop():** every `poll_seconds` one request: `/info` while a plan waits for Apply (heartbeat only), else `/changes`. Request fails → Live indicator "Reconnecting…" (once). Server back after a drop, `session` changed, or `resync` → `full_sync` (replaces a pending plan). While pending nothing else happens. `remove` changes → `plan_removals` (I1), others → `plan_for(live = true)` → review if conflicts / auto_apply off / count > auto_apply_limit, else apply directly.

**UI states** (dot color / big line): off grey "Not connected"; busy blue "Connecting…" "Comparing…" "Applying…"; ok green "In sync" / "Skipped"; review yellow "N changes ready"; error red "Server not running" / "Lost the server" / "Wrong place" / "Apply failed". Primary button: Connect → Apply (with Cancel) → Disconnect.

**plan_removals(plan, removed):** live `remove` changes (last change per key wins, so delete + re-create is an update) → `plan.remove` or `plan.conflicts` per I1. Counts toward the auto-apply limit like creates/updates. `apply` runs `remove_scripts` first, deepest path first.

**open_diff(entry):** list rows for create/update/conflict scripts are buttons. Click → `POST /sources {keys=[key]}` → `diff.lines(studio Source or "", disk source)` → `diff.fold(…, 3)` → rows (red `-` = Studio now, green `+` = disk), max 600 rows, yields every 100. A newer click or Back cancels drawing (`diff_token`). Read-only: never changes Studio.

## 9. Settings (plugin)

Stored with `plugin:SetSetting("xenon_settings", table)`. Defined in `SETTING_LIST` (order = page order). Numbers are clamped to `min..max`.

| key | kind | default | range / meaning |
| --- | --- | --- | --- |
| `port` | number | 34872 | 1-65535, must match `xenon serve --port` |
| `auto_apply` | bool | true | apply small live batches without asking |
| `auto_apply_limit` | number | 20 | 1-5000, larger live batches wait for Apply |
| `sync_deletes` | bool | true | — |
| `poll_seconds` | number | 0.5 | 0.1-10 |
| `sync_models` | bool | true | include `.rbxm` / `.model.json` / `.txt` entries |
| `log_output` | bool | true | print one line per applied batch |
| `icon_decal` | number | 57445653 | decal id; its `Texture` (image id) becomes the toolbar icon at startup |

## 10. How to extend

- **New file type:** add the suffix in `other_kind()` (`src/mapping.luau`), produce either a script entry (`push_script` with a `source_override`) or a model entry (`push_model` + a `model.from_*` builder). Add cases to `tests/wally_test.luau`. Update section 5 and the README table.
- **New value type in models:** add to `encode()` in `src/model.luau` and `decode()` in the plugin, same tag string. Update section 6.
- **New setting:** add one row to `SETTING_LIST` in the plugin; read it as `settings.<key>`. The settings page builds itself. Update section 9 and the README.
- **New endpoint:** add a branch in `handle()` in `src/server.luau`. Must not request deletions (I8). Update section 7.
- **New CLI command:** add a branch in `xenon.luau` MAIN and to `HELP`. Update section 4.
- After any plugin change: `xenon build`, restart Studio. After any change: `xenon test`.

## 11. Verified facts (measured on the Street Town game, 2026-11-06)

- 1,495 scripts, 437 containers; server first scan 1.4 s, cached rescan 0.5 s.
- Studio checksum of all 1,524 place scripts (9.2 MB): 0.14 s.
- Real `wally install` (vide 0.3.1, blood-engine 1.1.3, cmdr 1.13.1): scan 0.12 s, all package roots map to ModuleScripts, Blood Engine `Assets.rbxm` → 73-instance tree (91 KB JSON).
- In Studio: MeshPart created from `MeshContent` via AssetService, Trail `Attachment0` ref rewired, particle sequences/enums/attributes applied, no property failed.

## 12. Known limits / not implemented

- No Studio → disk (pull), no two-way sync, no folder/model deletes (by design, I1/I8). Files deleted while the server was down are not detected (full sync never deletes).
- Detection latency up to ~1.5 s (1 s server rescan + poll). Long-polling is the planned fix.
- `.md`, `.csv`, `.png` and other files are ignored. Terrain, unions (CSG) and binary data in models are not supported (same as Argon).
- Studio MCP `execute_luau` cannot reach localhost (Assistant HTTP allowlist), so the plugin can't be driven from MCP; test plugin logic by copying functions into an `execute_luau` call.
- Lune `task` is a module (`require("@lune/task")`), not a global. Lune instance wrappers are not stable table keys: compare with `==` (see `serialize_node`).

## 13. Glossary

- **entry:** one file-derived item (script, folder or model) with a `key`.
- **plan:** the plugin's diff result: `create`, `update`, `conflicts`, `skip`, `models_changed`.
- **nested project:** a folder containing `default.project.json`; the folder becomes that project's tree.
- **known_hash:** per-key checksum the plugin last saw or wrote; used to detect Studio edits (conflicts).
