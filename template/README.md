# {{name}}

Roblox game, synced into Studio with [Xenon](https://github.com/IAM9PASA/xenon).

## Start

```
rokit install      # tools (wally)
wally install      # packages, if wally.toml has any
xenon serve        # start syncing
```

In Studio: **Plugins → Xenon → Connect**.
Put your place id in `placeIds` in `default.project.json` so Xenon only syncs into this game.

## Where things go

| Folder | In Studio |
| --- | --- |
| `src/ReplicatedStorage` | ReplicatedStorage (shared modules, `Shared/greet.luau`) |
| `src/ServerScriptService` | ServerScriptService (`Server/main.server.luau`) |
| `src/StarterPlayer/StarterPlayerScripts` | client scripts (`Client/main.client.luau`) |
| `src/StarterPlayer/StarterCharacterScripts` | scripts that run in each character |
| `src/StarterGui` | UI |
| `src/ServerStorage` | server-only assets and modules |
| `src/ReplicatedFirst` | loads first on the client |
| `Packages/` | Wally shared packages → `ReplicatedStorage.Packages` |
| `ServerPackages/` | Wally server packages → `ServerScriptService.ServerPackages` |

`Name.server.luau` = Script, `Name.client.luau` = LocalScript, `Name.luau` = ModuleScript.
Anything you build in Studio (models, UI, maps) stays there: Xenon never removes Studio-only things.
