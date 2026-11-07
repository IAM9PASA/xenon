-- run: lune run tests/pull_test.luau   (from tools/xenon)
-- studio -> disk rules: what gets written where, and everything that must be refused

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local mapping = require("../src/mapping")
local pull = require("../src/pull")

local ROOT = "tests/_pull_fixture"
if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end

local files = {
	["src/server/main.server.luau"] = "print('old')\r\nprint('crlf')\r\n",
	["src/server/util.luau"] = "return {}",
	["src/server/lib/init.luau"] = "return 'lib'",
	["src/server/config.json"] = "{}",
	["src/server/empty/.keep"] = "",
	["Packages/pkg/default.project.json"] = '{"name":"pkg","tree":{"$path":"src"}}',
	["Packages/pkg/src/init.luau"] = "return 1",
	["Packages/_Index/x/.keep"] = "",
}
for path, text in files do
	fs.writeDir(ROOT .. "/" .. path:match("^(.*)/"))
	fs.writeFile(ROOT .. "/" .. path, text)
end
fs.writeFile(ROOT .. "/default.project.json", serde.encode("json", {
	name = "fixture",
	tree = {
		["$className"] = "DataModel",
		ServerScriptService = { ["$path"] = "src/server" },
		ReplicatedStorage = { Packages = { ["$path"] = "Packages" } },
		ServerStorage = { ServerPackages = { ["$path"] = "ServerPackages" } },
	},
}))

local project = mapping.load_project(ROOT .. "/default.project.json")
local function current()
	local map = {}
	for _, entry in mapping.snapshot(project, {}) do
		map[entry.key] = entry
	end
	return map
end

local failures = 0
local function check(label, ok)
	if ok then
		print("  ok  " .. label)
	else
		failures += 1
		print("  FAIL " .. label)
	end
end

local function item(path, class, source, extra)
	local out = { key = table.concat(path, "/"), path = path, class = class, source = source }
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

local S = "ServerScriptService"
local items = {
	item({ S, "main" }, "Script", "print('new')\nprint('crlf')"),
	item({ S, "fresh" }, "ModuleScript", "return 'fresh'"),
	item({ S, "off" }, "Script", "print('off')", { disabled = true }),
	item({ S, "tool" }, "Script", "print('tool')", { has_children = true }),
	item({ S, "tool", "part" }, "ModuleScript", "return 'part'"),
	item({ S, "lib", "inner" }, "ModuleScript", "return 'inner'"),
	item({ S, "empty", "x" }, "LocalScript", "print('x')"),
	item({ S, "Assets", "gun" }, "Script", "print('gun')"),
	item({ S, "util", "child" }, "ModuleScript", "return 1"),
	item({ S, "config" }, "ModuleScript", "return {}"),
	item({ "ReplicatedStorage", "Packages", "pkg" }, "ModuleScript", "return 2"),
	item({ "ReplicatedStorage", "Packages", "pkg", "evil" }, "ModuleScript", "return 3"),
	item({ S, "util" }, "Script", "print('class')"),
	item({ "ReplicatedStorage", "Packages", "loose" }, "ModuleScript", "return 4"),
	item({ S, "bad:name" }, "ModuleScript", "return 1"),
	item({ S, "part" }, "Part", ""),
	-- studio folders that aren't on disk yet
	item({ S, "services", "data" }, "ModuleScript", "return 'data'", { folder_parents = true }),
	item({ S, "services", "shop" }, "ModuleScript", "return 'shop'", { folder_parents = true }),
	item({ S, "admin", "commands", "give" }, "ModuleScript", "return 'give'", { folder_parents = true }),
	item({ S, "util", "deep", "x" }, "ModuleScript", "return 1", { folder_parents = true }),
	item({ S, "services", "_Index", "y" }, "ModuleScript", "return 1", { folder_parents = true }),
	item({ "ServerStorage", "ServerPackages", "store" }, "ModuleScript", "return 1", { folder_parents = true }),
}

-- dry run writes nothing
local dry = pull.run(project, current(), items, true)
check("dry: main would be written", dry.written[S .. "/main"] ~= nil)
check("dry: nothing on disk", not fs.isFile(ROOT .. "/src/server/fresh.luau") and fs.readFile(ROOT .. "/src/server/main.server.luau"):find("old"))

local result = pull.run(project, current(), items, false)
local w, r = result.written, result.refused
local function read(path)
	local full = ROOT .. "/" .. path
	return fs.isFile(full) and fs.readFile(full) or nil
end

check("update existing file", read("src/server/main.server.luau") == "print('new')\r\nprint('crlf')")
check("crlf kept", w[S .. "/main"] ~= nil)
check("new module next to others", read("src/server/fresh.luau") == "return 'fresh'")
check("new disabled script + meta", read("src/server/off.server.luau") ~= nil and (read("src/server/off.meta.json") or ""):find('"Disabled": true') ~= nil)
check("script with children -> folder/init", read("src/server/tool/init.server.luau") == "print('tool')")
check("child inside it", read("src/server/tool/part.luau") == "return 'part'")
check("into init-script folder", read("src/server/lib/inner.luau") == "return 'inner'")
check("into existing folder", read("src/server/empty/x.client.luau") == "print('x')")

check("refuse studio-only parent", r[S .. "/Assets/gun"] ~= nil and not fs.isDir(ROOT .. "/src/server/Assets"))
check("refuse child of file script", r[S .. "/util/child"] ~= nil and (r[S .. "/util/child"]):find("script file") ~= nil)
check("refuse data module", r[S .. "/config"] ~= nil and read("src/server/config.json") == "{}")
check("refuse wally package", r["ReplicatedStorage/Packages/pkg"] ~= nil and read("Packages/pkg/src/init.luau") == "return 1")
check("refuse inside wally package", r["ReplicatedStorage/Packages/pkg/evil"] ~= nil and not fs.isFile(ROOT .. "/Packages/pkg/src/evil.luau"))
check("refuse wally root folder", r["ReplicatedStorage/Packages/loose"] ~= nil and not fs.isFile(ROOT .. "/Packages/loose.luau"))
check("refuse class change", r[S .. "/util"] ~= nil and read("src/server/util.luau") == "return {}")
check("refuse bad name", r[S .. "/bad:name"] ~= nil)
check("refuse non-script", r[S .. "/part"] ~= nil)

check("dry: plans new folders, makes none", dry.written[S .. "/services/data"] ~= nil)
check("folder made for studio folder", read("src/server/services/data.luau") == "return 'data'" and read("src/server/services/shop.luau") == "return 'shop'")
check("nested folders made", read("src/server/admin/commands/give.luau") == "return 'give'")
check("refuse folder over a script file", r[S .. "/util/deep/x"] ~= nil and not fs.isDir(ROOT .. "/src/server/util"))
check("refuse _Index folder", r[S .. "/services/_Index/y"] ~= nil and not fs.isDir(ROOT .. "/src/server/services/_Index"))
check("refuse mapped root that doesn't exist", r["ServerStorage/ServerPackages/store"] ~= nil and not fs.isDir(ROOT .. "/ServerPackages"))

-- written files map back to the same keys (round trip)
local after = current()
check("round trip: tool is a Script with child", after[S .. "/tool"] and after[S .. "/tool"].class == "Script" and after[S .. "/tool/part"] ~= nil)
check("round trip: off is disabled", after[S .. "/off"] and after[S .. "/off"].disabled == true)
check("round trip: services is a Folder", after[S .. "/services"] and after[S .. "/services"].class == "Folder" and after[S .. "/services/data"] ~= nil)

-- second create of the same name must not overwrite
local again = pull.run(project, {}, { item({ S, "fresh" }, "ModuleScript", "return 'clobber'") }, false)
check("never overwrite on create", again.refused[S .. "/fresh"] ~= nil and read("src/server/fresh.luau") == "return 'fresh'")

fs.removeDir(ROOT)
print(failures == 0 and "all pull tests passed" or `{failures} pull test(s) failed`)
if failures > 0 then
	error("pull tests failed")
end
