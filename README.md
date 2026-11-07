<p align="center"><img src="assets/xenon_logo_256.png" width="128" alt="Xenon logo"></p>

# Xenon

**Safe file sync for Roblox: disk → Studio, plus Pull from Studio for scripts. It only deletes scripts you delete on disk, nothing else.**

You write code in your editor, Xenon puts it into Roblox Studio within about a second.
Built because Argon wanted to delete 1,386 Studio-only things (UI, models) from our game.

- Scripts, models and data files from disk show up in Studio
- **Delete a script file → it's removed in Studio** (only while connected, only if you didn't edit it in Studio). Studio-only things are never touched
- You see the changes first and press **Apply**. Ctrl+Z undoes it
- If you edited a script in Studio *and* on disk, Xenon leaves it alone and tells you
- Works with **Wally** packages, `.rbxm` models, `.json` / `.toml` data, `.txt`
- Locked to your place, so it can't sync into the wrong game

---

## Quick start

New game? `xenon init my-game` makes a ready project (see [New project](#new-project)).

1. **Start the server** in your game folder (where `default.project.json` is):
   ```
   xenon serve
   ```
2. **In Studio:** Plugins tab → **Xenon** → **Connect**.
3. Look at the list, press **Apply**. Done. From now on, every file you save shows up in Studio.

Stop the server with **Ctrl+C**.

---

## Install

You need [rokit](https://github.com/rojo-rbx/rokit). No clone, no Lune needed: xenon is one standalone binary.

```
rokit add --global IAM9PASA/xenon
xenon plugin
```

`xenon plugin` installs the Studio plugin (restart Studio after). Check: `xenon version`.
Update later: `rokit update --global xenon`, then `xenon plugin` again.

Pin it per project instead (so the whole team uses one version): run `rokit add IAM9PASA/xenon` in the game folder.
Each [release](https://github.com/IAM9PASA/xenon/releases) also has `Xenon.rbxm` if you'd rather drop the plugin into Studio's Plugins folder yourself.

### From source (to work on xenon)

```
git clone https://github.com/IAM9PASA/xenon
cd xenon
```
Windows: `powershell -ExecutionPolicy Bypass -File install.ps1` - macOS / Linux / Git Bash: `sh install.sh`

The installer installs Lune, adds `xenon/bin` to your PATH, and builds + installs the plugin. Update: `git pull`, run it again.

---

## New project

```
xenon init my-game
cd my-game
rokit install
xenon serve
```

`xenon init` copies the template into a **new or empty** folder (it refuses a folder that has files, so it can't overwrite anything):

```
my-game/
  default.project.json   every service mapped, Wally Packages + ServerPackages, $keepUnknowns
  wally.toml             add packages here, then `wally install`
  rokit.toml             wally
  selene.toml, .gitignore, README.md
  src/
    ReplicatedStorage/Shared/greet.luau          shared module
    ServerScriptService/Server/main.server.luau  server entry
    StarterPlayer/StarterPlayerScripts/Client/main.client.luau   client entry
    StarterPlayer/StarterCharacterScripts/, StarterGui/, ServerStorage/, ReplicatedFirst/
```

The project name (`"name"` in `default.project.json`, set it with `xenon init my-game --name "Street Town"`) is what the plugin shows: before you press Connect it says which project is waiting on the port, and if the server restarts into a different project the plugin disconnects instead of syncing it.

Put your place id in `placeIds` so Xenon only syncs into that game. The template lives in `template/`; edit it to change what new projects start with (`{{name}}` and `{{package}}` are filled in).

---

## The plugin

<table><tr><td>

- **Dot + big line** tell you what's going on:
  - grey **Not connected**, green **In sync**, yellow **N changes ready**, red **something's wrong**
- **One sentence** tells you what to do next
- **Chips** count the changes: `update`, `new`, `conflict`, `kept as is`
- **The list** shows each change with a tag:

| Tag | Meaning |
| --- | --- |
| `UPDATE` | script exists in Studio, code on disk is different → will be replaced with the disk version |
| `NEW` | not in Studio yet → will be created |
| `CONFLICT` | edited in Studio **and** on disk since the last sync → **left alone** |
| `KEPT` | a model changed on disk → left alone (delete it in Studio to re-create it) |
| `DELETE` | script file was deleted on disk → will be removed from Studio (Ctrl+Z brings it back) |
| `SKIPPED` | Studio has something with the same name but a different type → left alone |

- **Click a script** in the list to see its **diff**: red lines = Studio now, green = what disk will put in. Unchanged parts are folded. **Back** returns
- **● Live** in the header = the server answers. **● Reconnecting…** = it doesn't; Xenon keeps trying and catches up by itself (also after you restart `xenon serve`), no need to Disconnect / Connect
- **Auto ON / OFF** (next to the big line): on = Xenon never asks, everything is applied right away, also on Connect. Edited-in-both-places scripts are still left alone. Turning it on while a review waits applies that review. Pull from Studio still asks, because it writes files
- **One button** that changes: **Connect** → **Apply** / **Cancel** → **Disconnect**
- **Pull from Studio** (next to Disconnect) copies Studio scripts back into your files, see below

</td></tr></table>

### Pull from Studio (Studio → files)

Edited scripts in Studio, or made new ones? Press **Pull from Studio**:

1. Xenon lists every script that differs from your files: `TO DISK` (file will be overwritten with the Studio code) and `NEW FILE` (a file will be created)
2. Click one to see the diff (red = file now, green = Studio)
3. Press **Write to disk**. Check with `git diff`, git is your undo here

It only writes scripts. It never deletes, renames or moves a file, never overwrites a file when creating one, and never writes into Wally packages or `.json` / `.toml` data files.
New scripts are written where their parent is on disk, or inside plain Folders (those folders are created, e.g. `ServerScriptService/services/`). Scripts inside models, tools, UI or Wally packages are skipped and counted.
A script with child scripts becomes `Name/init.server.luau` with the children inside. Disabled scripts get a `.meta.json`.

### Settings

Click **Settings** in the plugin. Saved per user, take effect right away.

| Setting | Default | What it does |
| --- | --- | --- |
| On Connect, take data from | Server | **Server** = files on disk go into Studio (the normal Apply review). **Studio** = Connect opens the Pull review instead, so Studio scripts are written to disk (Write to disk). After that, live sync works as usual. Files that only exist on disk are not pushed into Studio on a Studio-mode Connect |
| Auto-accept (never ask) | Off | On = every change goes in without Apply, also on Connect. Same as the **Auto** button. Conflicts are still left alone |
| Server port | `34872` | Must match `xenon serve --port` |
| Apply small changes automatically | On | Off = every change waits for Apply |
| Ask first above this many changes | `20` | Bigger batches always wait for Apply |
| Check for changes every (seconds) | `0.5` | Lower = faster updates |
| Remove scripts deleted on disk | On | Off = deleted files are only reported |
| Sync models | On | `.rbxm`, `.model.json`, `.txt` (created only, never replaced) |
| Print changes in Output | On | One line per applied batch |
| Toolbar icon (decal id) | `57445653` | Any decal id, after a Studio restart |

---

## Commands

```
xenon init [folder]                     new game project from the template
xenon serve [project.json] [--port N]   start syncing (default ./default.project.json, port 34872)
xenon plugin                            install the Studio plugin
xenon status [--port N]                 is xenon running on that port, and for which project folder
xenon build                             (source checkout) build Xenon.rbxm + install the plugin
xenon test                              (source checkout) run the tests
xenon version                           print the version
xenon help                              show this list
```

---

## What becomes what

Same rules as Rojo and Argon, so existing projects just work.

| On disk | In Studio |
| --- | --- |
| `Name.server.luau` | Script |
| `Name.client.luau` | LocalScript |
| `Name.luau` (or `.lua`) | ModuleScript |
| `Folder/init.server.luau` (or `.client` / plain) | the folder itself becomes that script, other files become its children |
| `Folder/init.meta.json` `{"className": "ScreenGui"}` | the folder becomes that class |
| `Name.meta.json` `{"properties": {"Disabled": true}}` | the script starts disabled |
| `Name.meta.json` `{"properties": {"RunContext": "Client"}}` | the script's RunContext (Legacy / Server / Client / Plugin) |
| first line `--disable` | the script starts disabled |
| `Folder/default.project.json` | nested project (every Wally package) |
| `Name.rbxm` / `Name.rbxmx` | the model inside (one root → renamed to `Name`) |
| `Name.model.json` | instances described in JSON |
| `Name.json` / `Name.toml` | ModuleScript that returns the data |
| `Name.txt` | StringValue |

Where things go is decided by `default.project.json` (`$path` per service), like Rojo.

### Wally

Map Wally's folders in `default.project.json`, then run `wally install`:

```json
"ReplicatedStorage": { "Packages": { "$path": "Packages" } },
"ServerScriptService": { "ServerPackages": { "$path": "ServerPackages" } }
```

Xenon follows each package's own `default.project.json`, so `require(ReplicatedStorage.Packages.vide)` just works.

---

## Safety rules

1. **Deletes only what you deleted.** A script is removed only when its file is deleted while connected, Studio still has exactly the disk version, and it has no children. Connect / full sync never deletes, folders and models are never deleted. A file must stay gone for ~5 s first (so `wally install` refilling Packages/ is not a delete), and Wally `_Index` is never touched
2. **Only sends real changes.** Both sides compare a checksum of the code.
3. **Shows first.** First connect and big batches wait for Apply.
4. **Protects Studio edits.** Edited in both places → conflict, untouched.
5. **Models are create-only.** Changed models are reported, not replaced.
6. **Place lock.** `placeIds` in `default.project.json` → only that place.
7. **Undo.** Every apply is one Ctrl+Z step.

---

## Troubleshooting

| You see | Do this |
| --- | --- |
| **Server not running** | Run `xenon serve` in your game folder. Check the port in Settings matches |
| **● Reconnecting…** | The server stopped. Start `xenon serve` again, the plugin reconnects and re-compares on its own |
| `os error 10048` on serve | Another `xenon serve` (lune) is still running on that port. Close it first |
| Studio asks to allow `localhost` | Allow it, Xenon talks to the server on your own PC |
| **Wrong place** | You opened a different place. `placeIds` in `default.project.json` decides |
| `xenon` is not recognized | Add `tools/xenon/bin` to PATH (see Install), open a new terminal |
| `Failed to find tool 'lune'` | Run `rokit install` inside the xenon folder |
| Lots of `SKIPPED` | Studio has a different type with that name (e.g. a Folder where disk has a script). Fix one side |
| A model shows `KEPT` | Xenon never replaces models. Delete it in Studio, Xenon re-creates it |

---

## Development

```
xenon test      # mapping, wally, diff and pull tests
xenon build     # rebuild the plugin after editing plugin/xenon_plugin.luau
```

| Path | Job |
| --- | --- |
| `xenon.luau` | the CLI (`serve`, `build`, `test`) |
| `bin/xenon`, `bin/xenon.cmd` | launchers you put on PATH |
| `src/mapping.luau` | files → Studio paths (the Rojo rules above) |
| `src/model.luau` | `.rbxm` / `.model.json` / `.txt` → JSON trees, `.json` / `.toml` → modules |
| `src/checksum.luau` | same hash on server and plugin |
| `src/diff.luau` | line diff for the review page (Myers) |
| `src/pull.luau` | Studio → disk rules: where a pulled script goes, what is refused |
| `src/server.luau` | watches files, HTTP API on localhost |
| `src/build.luau` | packs the plugin into `Xenon.rbxm` |
| `src/init_project.luau` | `xenon init`: copies `template/` |
| `template/` | what a new project starts with |
| `install.ps1`, `install.sh` | installers for a source checkout |
| `src/assets.luau` | plugin sources + template (from disk; baked in for the release binary) |
| `tools/bundle.luau` | packs everything into `dist/xenon.luau` for `lune build` |
| `.github/workflows/release.yml` | tag `vX.Y.Z` -> tests, binaries for windows / mac / linux, GitHub release |
| `plugin/xenon_plugin.luau` | the Studio side: UI, settings, compare, apply |
| `tests/` | `mapping_test.luau`, `wally_test.luau`, `diff_test.luau`, `pull_test.luau`, `init_test.luau` |
| `docs/AI.md` | full spec for AI assistants |

Stack: Luau everywhere. Server on [Lune](https://lune-org.github.io/docs) (Rust-based Luau runtime), Studio plugin in Luau, no other dependencies.

### Releasing

1. Bump `VERSION` in `xenon.luau`, commit.
2. `git tag v0.9.0 && git push --tags`
3. The release workflow runs the tests, builds `xenon-<version>-<os>-<arch>.zip` for windows-x86_64, linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64 plus `Xenon.rbxm`, and publishes the release (rokit picks the right zip by name).

Try the binary locally: `lune run tools/bundle.luau` then `lune build dist/xenon.luau -o dist/xenon`.

## Not yet

Pulling models / UI (scripts only for now), live long-polling, deleting folders or models (on purpose).
