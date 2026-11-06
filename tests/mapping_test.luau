-- run: lune run tests/mapping_test.luau   (from tools/xenon)
-- builds a tiny fake project on disk and checks where every file lands

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local mapping = require("../src/mapping")
local checksum = require("../src/checksum")

local ROOT = "tests/_fixture"
if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end

local files = {
	["src/server/main.server.luau"] = "print('server')",
	["src/server/util.luau"] = "return {}",
	["src/server/off.server.luau"] = "print('off')",
	["src/server/off.meta.json"] = '{"properties":{"Disabled":true}}',
	["src/server/flagged.server.luau"] = "--disable\nprint('flag')",
	["src/server/data.json"] = "{}",
	["src/server/model.rbxm"] = "binary",
	["src/client/hud/init.client.luau"] = "print('hud')\r\nprint('crlf')",
	["src/client/hud/theme.luau"] = "return 1",
	["src/client/gui/init.meta.json"] = '{"className":"ScreenGui"}',
	["src/client/gui/button.client.luau"] = "print('btn')",
	["src/client/empty/readme.txt"] = "hi",
}
for path, text in files do
	local dir = path:match("^(.*)/")
	fs.writeDir(ROOT .. "/" .. dir)
	fs.writeFile(ROOT .. "/" .. path, text)
end
fs.writeFile(ROOT .. "/default.project.json", serde.encode("json", {
	name = "fixture",
	placeIds = { 123 },
	tree = {
		["$className"] = "DataModel",
		ServerScriptService = { ["$path"] = "src/server" },
		StarterPlayer = { StarterPlayerScripts = { ["$path"] = "src/client" } },
	},
}))

local project = mapping.load_project(ROOT .. "/default.project.json")
local entries = mapping.snapshot(project, {})
local by_key = {}
local order = {}
for i, e in entries do
	by_key[e.key] = e
	order[e.key] = i
end

local failures = 0
local function check(label, ok)
	if not ok then
		failures += 1
		print("FAIL", label)
	end
end

check("project name", project.name == "fixture")
check("place ids", project.place_ids[1] == 123)
check("server script", by_key["ServerScriptService/main"] and by_key["ServerScriptService/main"].class == "Script")
check("module", by_key["ServerScriptService/util"] and by_key["ServerScriptService/util"].class == "ModuleScript")
check("meta disabled", by_key["ServerScriptService/off"] and by_key["ServerScriptService/off"].disabled == true)
check("--disable line", by_key["ServerScriptService/flagged"] and by_key["ServerScriptService/flagged"].disabled == true)
check("enabled by default", by_key["ServerScriptService/main"].disabled == false)
check("json -> data module", by_key["ServerScriptService/data"] and by_key["ServerScriptService/data"].class == "ModuleScript")
check("broken rbxm skipped, no crash", by_key["ServerScriptService/model"] == nil)
check("txt -> StringValue", by_key["StarterPlayer/StarterPlayerScripts/empty/readme"] and by_key["StarterPlayer/StarterPlayerScripts/empty/readme"].class == "StringValue")
check("meta.json never an instance", by_key["ServerScriptService/off.meta"] == nil and by_key["ServerScriptService/off"].class == "Script")
local hud = by_key["StarterPlayer/StarterPlayerScripts/hud"]
check("init.client -> folder is LocalScript", hud and hud.class == "LocalScript")
check("crlf normalized", hud and not hud.source:find("\r", 1, true))
check("hash matches normalized source", hud and hud.hash == checksum("print('hud')\nprint('crlf')"))
check("child of init script", by_key["StarterPlayer/StarterPlayerScripts/hud/theme"] ~= nil)
local gui = by_key["StarterPlayer/StarterPlayerScripts/gui"]
check("init.meta className", gui and gui.folder and gui.class == "ScreenGui")
check("parent before child", order["StarterPlayer/StarterPlayerScripts/gui"] < order["StarterPlayer/StarterPlayerScripts/gui/button"])
check("plain folder", by_key["StarterPlayer/StarterPlayerScripts/empty"] and by_key["StarterPlayer/StarterPlayerScripts/empty"].class == "Folder")
check("module has no disabled flag", by_key["ServerScriptService/util"].disabled == nil)

-- cache: unchanged file is not re-read, changed file is
local cache = {}
mapping.snapshot(project, cache)
local before = cache[ROOT .. "/src/server/util.luau"].hash
task = require("@lune/task")
task.wait(0.05)
fs.writeFile(ROOT .. "/src/server/util.luau", "return { changed = true }")
local after_entries = mapping.snapshot(project, cache)
local changed
for _, e in after_entries do
	if e.key == "ServerScriptService/util" then
		changed = e
	end
end
check("cache picks up edits", changed and changed.hash ~= before)

fs.removeDir(ROOT)
print(failures == 0 and "all mapping tests passed" or `{failures} mapping test(s) failed`)
if failures > 0 then
	error("mapping tests failed")
end
