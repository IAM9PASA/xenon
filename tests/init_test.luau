-- run: lune run tests/init_test.luau   (from tools/xenon)
-- xenon init: template copied, names filled in, never writes into a non-empty folder,
-- and the new project maps to the right studio paths

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local init_project = require("../src/init_project")
local mapping = require("../src/mapping")

local ROOT = "tests/_init_fixture"
if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end
fs.writeDir(ROOT)

local failures = 0
local function check(label, ok)
	if not ok then
		failures += 1
		print("FAIL", label)
	end
end

local target = ROOT .. "/My Cool Game"
local ok, message, created = init_project("template", target, "My Cool Game")
check("init ok: " .. tostring(message), ok)
check("files created", #created >= 8)

check(".gitignore renamed", fs.isFile(target .. "/.gitignore") and not fs.isFile(target .. "/gitignore.txt"))
check("gitignore has Packages", fs.readFile(target .. "/.gitignore"):find("Packages/", 1, true) ~= nil)

local project = serde.decode("json", fs.readFile(target .. "/default.project.json"))
check("project name filled", project.name == "My Cool Game")
check("no leftover placeholders", not fs.readFile(target .. "/default.project.json"):find("{{", 1, true))
check("wally package name", fs.readFile(target .. "/wally.toml"):find('name = "me/my-cool-game"', 1, true) ~= nil)
check("readme title", fs.readFile(target .. "/README.md"):find("# My Cool Game", 1, true) ~= nil)
check("greet module filled", fs.readFile(target .. "/src/ReplicatedStorage/Shared/greet.luau"):find("welcome to My Cool Game", 1, true) ~= nil)

-- the generated project maps cleanly
local loaded = mapping.load_project(target .. "/default.project.json")
local by_key = {}
for _, entry in mapping.snapshot(loaded, {}) do
	by_key[entry.key] = entry
end
check("server script", by_key["ServerScriptService/Server/main"] and by_key["ServerScriptService/Server/main"].class == "Script")
check("client script", by_key["StarterPlayer/StarterPlayerScripts/Client/main"] and by_key["StarterPlayer/StarterPlayerScripts/Client/main"].class == "LocalScript")
check("shared module", by_key["ReplicatedStorage/Shared/greet"] and by_key["ReplicatedStorage/Shared/greet"].class == "ModuleScript")
check(".gitkeep not mapped", by_key["StarterGui/.gitkeep"] == nil)

-- never writes into a folder that has files
local before = fs.readFile(target .. "/README.md")
local again_ok, again_message = init_project("template", target, "Other")
check("refuses non-empty folder", not again_ok and again_message:find("not empty", 1, true) ~= nil)
check("existing files untouched", fs.readFile(target .. "/README.md") == before)

-- an empty folder is fine
fs.writeDir(ROOT .. "/empty")
check("empty folder ok", (init_project("template", ROOT .. "/empty", "empty")))

fs.removeDir(ROOT)
print(failures == 0 and "all init tests passed" or `{failures} init test(s) failed`)
if failures > 0 then
	error("init tests failed")
end
