-- run: lune run tests/wally_test.luau   (from tools/xenon)
-- fake wally install (nested default.project.json per package) + every non-script file type

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local mapping = require("../src/mapping")

local ROOT = "tests/_wally_fixture"
if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end

local function write(path, text)
	fs.writeDir(ROOT .. "/" .. path:match("^(.*)/"))
	fs.writeFile(ROOT .. "/" .. path, text)
end

-- a tiny rbxm: Folder "Assets" > Part (non-default color + size) + Weld whose Part0 points at the part
local assets = roblox.Instance.new("Folder")
assets.Name = "Assets"
local part = roblox.Instance.new("Part")
part.Name = "Drop"
part.Size = roblox.Vector3.new(1, 2, 3)
part.Color = roblox.Color3.new(1, 0, 0)
part:SetAttribute("Bloody", true)
part.Parent = assets
local weld = roblox.Instance.new("WeldConstraint")
weld.Part0 = part
weld.Parent = part
local fx = roblox.Instance.new("ParticleEmitter")
fx.Rate = 42
fx.Parent = assets

-- wally layout
write("Packages/vide.lua", 'return require(script.Parent._Index["centau_vide@0.3.1"]["vide"])')
write("Packages/_Index/centau_vide@0.3.1/vide/default.project.json", '{"name":"vide","tree":{"$path":"src"}}')
write("Packages/_Index/centau_vide@0.3.1/vide/wally.toml", '[package]\nname = "centau/vide"')
write("Packages/_Index/centau_vide@0.3.1/vide/sourcemap.json", "{}")
write("Packages/_Index/centau_vide@0.3.1/vide/src/init.luau", "return { create = true }")
write("Packages/_Index/centau_vide@0.3.1/vide/src/create.luau", "return function() end")
write("Packages/BloodEngine.lua", 'return require(script.Parent._Index["rotntake_blood-engine@1.1.3"]["blood-engine"])')
write("Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine/default.project.json", '{"name":"blood-engine","tree":{"$path":"src"}}')
write("Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine/src/init.lua", "return {}")
fs.writeFile(ROOT .. "/Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine/src/Assets.rbxm", roblox.serializeModel({ assets }))
write("ServerPackages/Cmdr.lua", 'return require(script.Parent._Index["evaera_cmdr@1.13.1"]["cmdr"])')
write("ServerPackages/_Index/evaera_cmdr@1.13.1/cmdr/default.project.json", '{"name":"cmdr","tree":{"$path":"Cmdr"}}')
write("ServerPackages/_Index/evaera_cmdr@1.13.1/cmdr/Cmdr/init.luau", "return 'cmdr'")

-- other file types in a normal src tree
write("src/shared/config.json", '{"speed": 16, "names": ["a", "b"], "nested": {"on": true}}')
write("src/shared/settings.toml", 'gravity = 196.2\nmode = "fast"')
write("src/shared/notes.txt", "hello")
write("src/shared/Remote.model.json", '{"ClassName":"RemoteEvent","Properties":{"Archivable":true}}')

fs.writeFile(ROOT .. "/default.project.json", serde.encode("json", {
	name = "wally-fixture",
	tree = {
		["$className"] = "DataModel",
		ReplicatedStorage = {
			["$path"] = "src/shared",
			Packages = { ["$path"] = "Packages" },
		},
		ServerScriptService = { ServerPackages = { ["$path"] = "ServerPackages" } },
	},
}))

local project = mapping.load_project(ROOT .. "/default.project.json")
local by_key = {}
for _, e in mapping.snapshot(project, {}) do
	by_key[e.key] = e
end

local failures = 0
local function check(label, ok)
	if not ok then
		failures += 1
		print("FAIL", label)
	end
end

local vide = by_key["ReplicatedStorage/Packages/_Index/centau_vide@0.3.1/vide"]
check("nested project -> package root is the src init module", vide and vide.class == "ModuleScript" and vide.source:find("create = true"))
check("nested project child", by_key["ReplicatedStorage/Packages/_Index/centau_vide@0.3.1/vide/create"] ~= nil)
check("no src folder leaks in", by_key["ReplicatedStorage/Packages/_Index/centau_vide@0.3.1/vide/src"] == nil)
check("wally.toml outside $path ignored", by_key["ReplicatedStorage/Packages/_Index/centau_vide@0.3.1/vide/wally"] == nil)
check("sourcemap.json outside $path ignored", by_key["ReplicatedStorage/Packages/_Index/centau_vide@0.3.1/vide/sourcemap"] == nil)
check("link module", by_key["ReplicatedStorage/Packages/vide"] and by_key["ReplicatedStorage/Packages/vide"].class == "ModuleScript")
check(".lua init works", by_key["ReplicatedStorage/Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine"] and by_key["ReplicatedStorage/Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine"].class == "ModuleScript")
check("server packages + $path to a non-src folder", by_key["ServerScriptService/ServerPackages/_Index/evaera_cmdr@1.13.1/cmdr"] and by_key["ServerScriptService/ServerPackages/_Index/evaera_cmdr@1.13.1/cmdr"].class == "ModuleScript")

local asset = by_key["ReplicatedStorage/Packages/_Index/rotntake_blood-engine@1.1.3/blood-engine/Assets"]
check("rbxm -> model entry", asset and asset.model and asset.class == "Folder")
local tree = asset and asset.model
local drop = tree and tree.children[1]
check("rbxm root renamed to file name", tree and tree.name == "Assets")
check("rbxm child + non-default props", drop and drop.class == "Part" and drop.props.Size and drop.props.Size[1] == "Vector3" and drop.props.Size[3] == 2)
check("rbxm attribute", drop and drop.attrs.Bloody and drop.attrs.Bloody[2] == true)
local weld_node = drop and drop.children[1]
check("rbxm ref -> id inside tree", weld_node and weld_node.props.Part0 and weld_node.props.Part0[1] == "Ref" and weld_node.props.Part0[2] == drop.id)
local fx_node = tree and tree.children[2]
check("rbxm default props skipped", fx_node and fx_node.props.Rate and fx_node.props.Enabled == nil)

local config = by_key["ReplicatedStorage/config"]
check(".json -> module", config and config.class == "ModuleScript" and config.source:find("speed = 16") and config.source:find('"a"'))
local settings = by_key["ReplicatedStorage/settings"]
check(".toml -> module", settings and settings.source:find('mode = "fast"'))
local notes = by_key["ReplicatedStorage/notes"]
check(".txt -> StringValue", notes and notes.model and notes.class == "StringValue" and notes.model.props.Value[2] == "hello")
local remote = by_key["ReplicatedStorage/Remote"]
check(".model.json -> model", remote and remote.model and remote.class == "RemoteEvent")

-- generated data module must be valid luau that returns the data
local fn = loadstring and loadstring(config.source)
if fn then
	local data = fn()
	check("data module runs", data.speed == 16 and data.names[2] == "b" and data.nested.on == true)
end

fs.removeDir(ROOT)
print(failures == 0 and "all wally tests passed" or `{failures} wally test(s) failed`)
if failures > 0 then
	error("wally tests failed")
end
