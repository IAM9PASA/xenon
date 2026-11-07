-- run: lune run tests/live_test.luau   (from the xenon folder)
-- live sync end to end: the real server (init / rescan / handle) and the plugin's real tree module
-- (plugin/tree.luau) on a lune DataModel. the poll loop below mirrors poll_loop / full_sync in the plugin.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local server = require("../src/server")
local checksum = require("../src/checksum")
local make_tree = require("../plugin/tree")

local ROOT = "tests/_live_fixture"
local PKG = "Packages/_Index/iam9pasa_bright@0.1.0"
local BRIGHT = { "ReplicatedStorage", "Packages", "_Index", "iam9pasa_bright@0.1.0", "bright" }

if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end

local function write(path, text)
	local dir = path:match("^(.*)/")
	if dir then
		fs.writeDir(ROOT .. "/" .. dir)
	end
	fs.writeFile(ROOT .. "/" .. path, text)
end

local function remove(path)
	local full = ROOT .. "/" .. path
	if fs.isDir(full) then
		fs.removeDir(full)
	elseif fs.isFile(full) then
		fs.removeFile(full)
	end
end

local failures = 0
local function check(label, ok)
	if not ok then
		failures += 1
		print("FAIL", label)
	end
end

-- project: like the playground (ReplicatedStorage.Packages -> Packages) plus a plain src tree
write("src/shared/hello.luau", "return 'hello'")
write("Packages/vide.lua", 'return require(script.Parent._Index["centau_vide@0.3.1"]["vide"])')
write("Packages/_Index/centau_vide@0.3.1/vide/default.project.json", '{"name":"vide","tree":{"$path":"src"}}')
write("Packages/_Index/centau_vide@0.3.1/vide/src/init.luau", "return 'vide'")
write("default.project.json", serde.encode("json", {
	name = "live-fixture",
	tree = {
		["$className"] = "DataModel",
		ReplicatedStorage = {
			["$path"] = "src/shared",
			Packages = { ["$path"] = "Packages" },
		},
	},
}))

-- STUDIO (fake plugin) -------------------------

local game = roblox.Instance.new("DataModel")
local tree = make_tree({
	root = game,
	Instance = roblox.Instance,
	checksum = checksum,
	write_source = function(inst, source)
		inst.Source = source
	end,
})

local plugin = { version = 0, session = nil, known_hash = {} }

local function call(method, path, body, query)
	local response = server.handle({ method = method, path = path, query = query, body = body and serde.encode("json", body) or "" })
	return serde.decode("json", response.body)
end

local function sources_for(entries)
	local keys = {}
	for _, entry in entries do
		if not entry.folder and not entry.source and not entry.tree then
			table.insert(keys, entry.key)
		end
	end
	local sources = #keys > 0 and call("POST", "/sources", { keys = keys }) or {}
	for _, entry in entries do
		if entry.source or entry.tree then
			sources[entry.key] = entry.source or entry.tree
		end
	end
	return sources
end

-- the plugin's apply(): re-check removals with the server, remove deepest first, then write
local function apply(plan)
	local todo = {}
	for _, group in { plan.create, plan.update } do
		for _, entry in group do
			table.insert(todo, entry)
		end
	end
	local sources = sources_for(todo)
	local to_remove = {}
	if #plan.remove > 0 then
		local keys = {}
		for _, entry in plan.remove do
			table.insert(keys, entry.key)
		end
		local back = call("POST", "/sources", { keys = keys })
		for _, entry in plan.remove do
			if back[entry.key] == nil then
				table.insert(to_remove, entry)
			end
		end
	end
	tree.remove(to_remove, plugin.known_hash)
	tree.write(todo, sources, plugin.known_hash)
end

local function full_sync()
	local snapshot = call("GET", "/snapshot")
	plugin.version = snapshot.version
	plugin.session = snapshot.session
	apply(tree.plan(snapshot.entries, false, plugin.known_hash))
end

-- one poll_loop tick (auto-apply on)
local function poll()
	local result = call("GET", "/changes", nil, { since = tostring(plugin.version) })
	if result.session ~= plugin.session or result.resync then
		full_sync()
		return "resync"
	end
	local last, order = {}, {}
	for _, change in result.changes do
		if not last[change.entry.key] then
			table.insert(order, change.entry.key)
		end
		last[change.entry.key] = change
	end
	local entries, removed = {}, {}
	for _, key in order do
		table.insert(last[key].kind == "remove" and removed or entries, last[key].entry)
	end
	plugin.version = result.version
	local plan = tree.plan(entries, true, plugin.known_hash)
	tree.plan_removals(plan, removed)
	apply(plan)
	return "ok"
end

-- n rescans (the server does one a second), then one poll
local function tick(n: number?)
	for _ = 1, n or 1 do
		server.rescan()
	end
	return poll()
end

local function at(path, ...)
	local full = table.clone(path)
	for _, name in { ... } do
		table.insert(full, name)
	end
	return tree.find(full)
end

local function write_bright(order)
	local files = {
		link = { "Packages/Bright.lua", 'return require(script.Parent._Index["iam9pasa_bright@0.1.0"]["bright"])' },
		project = { PKG .. "/bright/default.project.json", '{"name":"bright","tree":{"$path":"src"}}' },
		wally = { PKG .. "/bright/wally.toml", '[package]\nname = "iam9pasa/bright"' },
		init = { PKG .. "/bright/src/init.luau", "return { name = 'bright' }" },
		motion = { PKG .. "/bright/src/motion.luau", "return 'motion'" },
		style = { PKG .. "/bright/src/styles/dark.luau", "return 'dark'" },
		vide_link = { PKG .. "/vide.lua", 'return require(script.Parent.Parent["centau_vide@0.3.1"]["vide"])' },
	}
	for _, step in order do
		for _, name in step do
			write(files[name][1], files[name][2])
		end
		tick() -- the server may scan between any two writes
	end
end

local function bright_ok(label)
	local bright = tree.find(BRIGHT)
	check(label .. ": bright is a ModuleScript", bright and bright.ClassName == "ModuleScript")
	check(label .. ": bright has init's source", bright and bright.ClassName == "ModuleScript" and bright.Source:find("bright") ~= nil)
	check(label .. ": child module", at(BRIGHT, "motion") and at(BRIGHT, "motion").ClassName == "ModuleScript")
	check(label .. ": nested child", at(BRIGHT, "styles", "dark") and at(BRIGHT, "styles", "dark").Source == "return 'dark'")
	check(label .. ": no src left over", at(BRIGHT, "src") == nil)
	check(label .. ": no wally.toml module", at(BRIGHT, "wally") == nil)
	local link = tree.find({ "ReplicatedStorage", "Packages", "Bright" })
	check(label .. ": link module", link and link.ClassName == "ModuleScript")
end

-- TESTS -------------------------

-- 1. connect with no package, then wally installs one (all files land before the next scan)
server.init(ROOT .. "/default.project.json")
full_sync()
check("connect: vide synced", at({ "ReplicatedStorage", "Packages", "_Index", "centau_vide@0.3.1", "vide" }) ~= nil)
write_bright({ { "link", "project", "wally", "init", "motion", "style", "vide_link" } })
tick(6)
bright_ok("new package while serving")

-- 4. wally uninstall: the whole package folder goes, studio follows. studio-only things stay
remove(PKG)
remove("Packages/Bright.lua")
tick(6)
check("package removed: package folder gone", at({ "ReplicatedStorage", "Packages", "_Index" }, "iam9pasa_bright@0.1.0") == nil)
check("package removed: link gone", tree.find({ "ReplicatedStorage", "Packages", "Bright" }) == nil)
check("package removed: other package kept", at({ "ReplicatedStorage", "Packages", "_Index", "centau_vide@0.3.1", "vide" }) ~= nil)

-- 2. same package, files in the worst order, a scan between every step
write_bright({ { "motion", "style" }, { "wally" }, { "init" }, { "vide_link" }, { "link" }, { "project" } })
tick(6) -- the src/... and wally keys that went away are removed after the grace scans
bright_ok("bad write order")

-- removed folder with something studio-only inside: kept, only xenon's scripts go
local note = roblox.Instance.new("Part")
note.Name = "StudioOnly"
note.Parent = at(BRIGHT, "styles")
remove(PKG .. "/bright/src/styles")
tick(6)
check("studio-only child keeps its folder", at(BRIGHT, "styles", "StudioOnly") ~= nil)
check("script in removed folder goes", at(BRIGHT, "styles", "dark") == nil)
note.Parent = nil

-- 3. folder -> script when init appears (children, attributes kept), and back when it goes
write("src/shared/thing/part.luau", "return 'part'")
tick()
local thing = tree.find({ "ReplicatedStorage", "thing" })
check("plain folder first", thing and thing.ClassName == "Folder")
if thing then
	thing:SetAttribute("Keep", 7)
end
write("src/shared/thing/init.luau", "return 'thing'")
tick()
thing = tree.find({ "ReplicatedStorage", "thing" })
check("init added: folder became a ModuleScript", thing and thing.ClassName == "ModuleScript" and thing.Source == "return 'thing'")
check("init added: children kept", thing and thing:FindFirstChild("part") ~= nil)
check("init added: attributes kept", thing and thing:GetAttribute("Keep") == 7)
remove("src/shared/thing/init.luau")
tick()
thing = tree.find({ "ReplicatedStorage", "thing" })
check("init removed: back to a Folder", thing and thing.ClassName == "Folder")
check("init removed: children kept", thing and thing:FindFirstChild("part") ~= nil)

-- a script edited in studio is not turned back into a folder
write("src/shared/thing/init.luau", "return 'thing'")
tick()
thing = tree.find({ "ReplicatedStorage", "thing" })
if thing and thing.ClassName == "ModuleScript" then
	thing.Source = "return 'edited in studio'"
end
remove("src/shared/thing/init.luau")
tick()
thing = tree.find({ "ReplicatedStorage", "thing" })
check("edited script kept as script", thing and thing.ClassName == "ModuleScript" and thing.Source:find("edited") ~= nil)

-- 5. server restart while connected: the plugin notices the new session and ends in sync.
-- the reported case: studio still has bright as a plain Folder (the old bug) -> becomes the module
local bright = tree.find(BRIGHT)
if bright then
	local folder = tree.swap(bright, "Folder")
	check("setup: bright is a Folder again", folder.ClassName == "Folder")
end
write("src/shared/hello.luau", "return 'hello again'")
server.init(ROOT .. "/default.project.json")
check("restart: plugin resyncs", poll() == "resync")
check("restart: change made while down is in", tree.find({ "ReplicatedStorage", "hello" }).Source == "return 'hello again'")
bright = tree.find(BRIGHT)
check("restart: Folder upgraded to the package module", bright and bright.ClassName == "ModuleScript" and bright.Source:find("bright") ~= nil)
check("restart: then live again", tick() == "ok")

fs.removeDir(ROOT)
print(failures == 0 and "all live tests passed" or `{failures} live test(s) failed`)
if failures > 0 then
	error("live tests failed")
end
