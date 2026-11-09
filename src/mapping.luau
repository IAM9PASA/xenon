-- maps project files to studio instance paths. same naming rules as rojo / argon:
--   Name.server.luau -> Script, Name.client.luau -> LocalScript, Name.luau -> ModuleScript
--   Folder/init.*.luau -> the folder itself is that script, Folder/init.meta.json -> folder class / props
--   Name.meta.json -> props for Name (Disabled / Enabled), first line "--disable" -> disabled
--   Folder/default.project.json -> nested project (every wally package): folder = its tree
--   Name.rbxm / .rbxmx / .model.json -> model, Name.txt -> StringValue
--   Name.json / .toml -> ModuleScript returning the data
-- entry kinds: script (source), folder (container), model (tree built by the plugin)

-- SERVICES -------------------------

local fs = table.clone(require("@lune/fs")) -- a copy, so tools/bench.luau can count calls (mapping.fs)
local serde = require("@lune/serde")
local datetime = require("@lune/datetime")


-- MODULES -------------------------

local checksum = require("./checksum")
local model = require("./model")


-- VARIABLES -------------------------

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".server.lua", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".client.lua", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".lua", "ModuleScript" },
}

-- checked before the plain .json rule
local IGNORED_SUFFIXES = { ".meta.json", ".project.json" }

local mapping = {}

-- wally packages (folders right under an _Index) are reused between rescans while none of their
-- folders changed: wally only writes new files, so a changed package always changes a folder stamp.
-- a package touched in the last SETTLE_MS (being installed) is scanned in full, and every
-- FULL_EVERY-th rescan ignores the reuse (safety net for in-place edits inside _Index)
mapping.SETTLE_MS = 2000
mapping.FULL_EVERY = 30

local recorder = nil -- folder -> stamp, while scanning one wally package


-- FUNCTIONS -------------------------

local function ends_with(text: string, suffix: string): boolean
	return #text > #suffix and text:sub(-#suffix) == suffix
end

local function script_kind(file_name: string): (string?, string?)
	for _, pair in SCRIPT_SUFFIXES do
		if ends_with(file_name, pair[1]) then
			return file_name:sub(1, -#pair[1] - 1), pair[2]
		end
	end
	return nil, nil
end

-- non-script file -> (instance name, kind) or nil when the file is not an instance
local function other_kind(file_name: string): (string?, string?)
	for _, suffix in IGNORED_SUFFIXES do
		if ends_with(file_name, suffix) then
			return nil, nil
		end
	end
	for _, pair in { { ".model.json", "model_json" }, { ".rbxmx", "rbxm" }, { ".rbxm", "rbxm" }, { ".txt", "text" }, { ".json", "json" }, { ".toml", "toml" } } do
		if ends_with(file_name, pair[1]) then
			return file_name:sub(1, -#pair[1] - 1), pair[2]
		end
	end
	return nil, nil
end

local function is_disabled(meta, source: string): boolean
	if source:sub(1, 9) == "--disable" then
		return true
	end
	local props = meta and meta.properties
	return props ~= nil and (props.Disabled == true or props.Enabled == false)
end

local function child_path(path: { string }, name: string): { string }
	local copy = table.clone(path)
	table.insert(copy, name)
	return copy
end

local function stamp_of(meta): number
	local modified = meta and meta.modifiedAt
	return modified and modified.unixTimestampMillis or 0
end

-- one readDir + one metadata per entry: names (sorted) and name -> { dir, stamp }.
-- every other check (init files, meta files, project files) looks the name up here, no extra fs call
local function list_dir(dir: string)
	local names = fs.readDir(dir)
	table.sort(names)
	local info = {}
	for _, name in names do
		local full = dir .. "/" .. name
		local ok, meta = pcall(fs.metadata, full)
		if ok and meta and meta.exists then
			local is_dir = meta.kind == "dir"
			if meta.kind == "symlink" then
				is_dir = fs.isDir(full)
			end
			info[name] = { dir = is_dir, stamp = stamp_of(meta) }
			if is_dir and recorder then
				recorder[full] = info[name].stamp
			end
		end
	end
	return names, info
end

-- mtime cache: a file is only re-read and re-converted when its timestamp changes.
-- stamp comes from list_dir; nil = look it up (a $path that points straight at a file)
local function cached(file: string, cache, build, stamp: number?)
	stamp = stamp or stamp_of(fs.metadata(file))
	local hit = cache[file]
	if hit and hit.stamp == stamp then
		return hit
	end
	local contents = fs.readFile(file)
	local fresh = build(contents)
	fresh.stamp = stamp
	cache[file] = fresh
	return fresh
end

-- project / meta json from a listed folder, decoded once per change. nil when missing or bad
local function listed_json(dir: string, name: string, info, cache, label: string)
	local item = info[name]
	if not item or item.dir then
		return nil
	end
	local file = dir .. "/" .. name
	local hit = cached(file, cache, function(contents)
		local ok, data = pcall(serde.decode, "json", contents)
		if ok and type(data) == "table" then
			return { data = data }
		end
		warn(`[xenon] bad {label} {file}`)
		return {}
	end, item.stamp)
	return hit.data
end

local function push_script(out, path, class, file, meta, cache, source_override, stamp: number?)
	local item = cached(file, cache, function(contents)
		local source = source_override and source_override(contents) or (contents:gsub("\r\n", "\n"))
		return { source = source, hash = checksum(source) }
	end, stamp)

	-- modules have no Enabled / RunContext, so they carry neither
	local disabled, run_context = nil, nil
	if class ~= "ModuleScript" then
		disabled = is_disabled(meta, item.source)
		local props = meta and meta.properties
		if props and type(props.RunContext) == "string" then
			run_context = props.RunContext -- "Legacy" | "Server" | "Client" | "Plugin"
		end
	end
	table.insert(out, {
		key = table.concat(path, "/"),
		path = path,
		class = class,
		source = item.source,
		hash = item.hash,
		disabled = disabled,
		run_context = run_context,
		file = file,
		data = source_override ~= nil or nil, -- generated from .json / .toml: never pulled back
	})
end

local function push_model(out, path, kind, file, cache, stamp: number?)
	local name = path[#path]
	local item = cached(file, cache, function(contents)
		local ok, tree = pcall(function()
			if kind == "rbxm" then
				return (model.from_rbxm(contents, name))
			elseif kind == "model_json" then
				return (model.from_model_json(contents, name))
			end
			return (model.from_text(contents, name))
		end)
		if not ok then
			warn(`[xenon] cannot read model {file}: {tree}`)
			return { failed = true }
		end
		return { tree = tree, hash = checksum(contents) }
	end, stamp)
	if item.failed then
		return
	end

	table.insert(out, {
		key = table.concat(path, "/"),
		path = path,
		class = item.tree.class,
		model = item.tree,
		hash = item.hash,
		file = file,
	})
end

local scan, scan_folder, scan_target

-- a nested project's tree node: { $path, $className, children... } relative to the project file
local function scan_project_node(node, base_dir: string, path: { string }, out, cache)
	if node["$path"] then
		scan_target(base_dir .. "/" .. node["$path"], path, out, cache, node["$className"])
	else
		table.insert(out, { key = table.concat(path, "/"), path = path, class = node["$className"] or "Folder", folder = true })
	end
	for key, child in node do
		if type(child) == "table" and key:sub(1, 1) ~= "$" then
			scan_project_node(child, base_dir, child_path(path, key), out, cache)
		end
	end
end

-- a $path can point at a folder or straight at a file
function scan_target(target: string, path: { string }, out, cache, class_name: string?)
	if fs.isDir(target) then
		scan_folder(target, path, out, cache, class_name)
		return
	end
	if not fs.isFile(target) then
		warn(`[xenon] project path not found: {target}`)
		return
	end
	local file_name = target:match("[^/\\]+$")
	local _, class = script_kind(file_name)
	if class then
		push_script(out, path, class, target, nil, cache)
		return
	end
	local _, kind = other_kind(file_name)
	if kind == "json" or kind == "toml" then
		push_script(out, path, "ModuleScript", target, nil, cache, function(contents)
			return model.data_module(contents, kind)
		end)
	elseif kind then
		push_model(out, path, kind, target, cache)
	end
end

-- a folder is a nested project, a script (init file inside), or a container (Folder / init.meta.json className)
function scan_folder(dir: string, path: { string }, out, cache, class_name: string?)
	local names, info = list_dir(dir)
	local project = listed_json(dir, "default.project.json", info, cache, "project file")
	if project and type(project.tree) == "table" then
		scan_project_node(project.tree, dir, path, out, cache)
		return
	end

	local meta = listed_json(dir, "init.meta.json", info, cache, "meta file")
	for _, pair in SCRIPT_SUFFIXES do
		local init_name = "init" .. pair[1]
		local item = info[init_name]
		if item and not item.dir then
			push_script(out, path, pair[2], dir .. "/" .. init_name, meta, cache, nil, item.stamp)
			out[#out].dir = dir -- children of this script live in this folder
			scan(dir, path, out, cache, names, info)
			return
		end
	end

	table.insert(out, {
		key = table.concat(path, "/"),
		path = path,
		class = class_name or (meta and meta.className) or "Folder",
		folder = true,
		dir = dir,
	})
	scan(dir, path, out, cache, names, info)
end

-- a reused package is valid while every folder in it still has the stamp it had
local function package_unchanged(package, stamp: number, cache): boolean
	if cache.full_scan or package.stamp ~= stamp or package.recent then
		return false
	end
	for dir, dir_stamp in package.dirs do
		local ok, meta = pcall(fs.metadata, dir)
		if not ok or not meta or not meta.exists or stamp_of(meta) ~= dir_stamp then
			return false
		end
	end
	return true
end

local function scan_package(full: string, path: { string }, stamp: number, out, cache)
	cache.packages = cache.packages or {}
	local package = cache.packages[full]
	if package and package_unchanged(package, stamp, cache) then
		table.move(package.entries, 1, #package.entries, #out + 1, out)
		return
	end

	local before = #out
	local saved = recorder
	recorder = {}
	scan_folder(full, path, out, cache)
	local dirs = recorder
	recorder = saved

	local settled = datetime.now().unixTimestampMillis - mapping.SETTLE_MS
	local recent = stamp > settled
	for _, dir_stamp in dirs do
		if dir_stamp > settled then
			recent = true
			break
		end
	end
	cache.packages[full] = { stamp = stamp, dirs = dirs, recent = recent, entries = table.move(out, before + 1, #out, 1, {}) }
end

-- names / info: the folder's listing when the caller already has it
function scan(dir: string, path: { string }, out, cache, names, info)
	if not names then
		names, info = list_dir(dir)
	end
	local wally_index = dir:match("[/\\]_Index$") ~= nil and recorder == nil

	for _, name in names do
		local item = info[name]
		if not item then
			continue -- gone between readDir and metadata
		end
		local full = dir .. "/" .. name
		if item.dir and wally_index then
			scan_package(full, child_path(path, name), item.stamp, out, cache)
		elseif item.dir then
			scan_folder(full, child_path(path, name), out, cache)
		else
			local base, class = script_kind(name)
			if base then
				if base ~= "init" then
					local meta = listed_json(dir, base .. ".meta.json", info, cache, "meta file")
					push_script(out, child_path(path, base), class, full, meta, cache, nil, item.stamp)
				end
			else
				local other, kind = other_kind(name)
				if other and other ~= "init" then
					if kind == "json" or kind == "toml" then
						push_script(out, child_path(path, other), "ModuleScript", full, nil, cache, function(contents)
							return model.data_module(contents, kind)
						end, item.stamp)
					else
						push_model(out, child_path(path, other), kind, full, cache, item.stamp)
					end
				end
			end
		end
	end
end

-- project.json -> { name, place_ids, roots = { { path = {"ReplicatedStorage"}, dir = "src/..." } } }
function mapping.load_project(project_file: string)
	local project = serde.decode("json", fs.readFile(project_file))
	local base_dir = project_file:match("^(.*)[/\\]") or "."
	local roots = {}

	local function walk(node, path)
		for key, child in node do
			if type(child) == "table" and key:sub(1, 1) ~= "$" then
				local next_path = child_path(path, key)
				if child["$path"] then
					table.insert(roots, { path = next_path, dir = base_dir .. "/" .. child["$path"] })
				end
				walk(child, next_path)
			end
		end
	end
	walk(project.tree, {})

	return { name = project.name or "project", place_ids = project.placeIds or {}, roots = roots, base_dir = base_dir }
end

-- everything under the mapped roots, parents before children
function mapping.snapshot(project, cache)
	local out = {}
	cache = cache or {}
	cache.scans = (cache.scans or 0) + 1
	cache.full_scan = cache.scans % mapping.FULL_EVERY == 0
	for _, root in project.roots do
		if fs.isDir(root.dir) then
			-- the root is a service (or a node under one): only its children are mapped
			scan(root.dir, root.path, out, cache)
		elseif fs.isFile(root.dir) then
			scan_target(root.dir, root.path, out, cache)
		end
	end
	return out
end

mapping.script_kind = script_kind
mapping.fs = fs

return mapping
