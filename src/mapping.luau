-- maps project files to studio instance paths. same naming rules as rojo / argon:
--   Name.server.luau -> Script, Name.client.luau -> LocalScript, Name.luau -> ModuleScript
--   Folder/init.*.luau -> the folder itself is that script, Folder/init.meta.json -> folder class / props
--   Name.meta.json -> props for Name (Disabled / Enabled), first line "--disable" -> disabled
--   Folder/default.project.json -> nested project (every wally package): folder = its tree
--   Name.rbxm / .rbxmx / .model.json -> model, Name.txt -> StringValue
--   Name.json / .toml -> ModuleScript returning the data
-- entry kinds: script (source), folder (container), model (tree built by the plugin)

-- SERVICES -------------------------

local fs = require("@lune/fs")
local serde = require("@lune/serde")


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

local function read_json(path: string, label: string)
	if not fs.isFile(path) then
		return nil
	end
	local ok, data = pcall(serde.decode, "json", fs.readFile(path))
	if ok and type(data) == "table" then
		return data
	end
	warn(`[xenon] bad {label} {path}`)
	return nil
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

-- mtime cache: a file is only re-read and re-converted when its timestamp changes
local function cached(file: string, cache, build)
	local modified = fs.metadata(file).modifiedAt
	local stamp = modified and modified.unixTimestampMillis or 0
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

local function push_script(out, path, class, file, meta, cache, source_override)
	local item = cached(file, cache, function(contents)
		local source = source_override and source_override(contents) or (contents:gsub("\r\n", "\n"))
		return { source = source, hash = checksum(source) }
	end)

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

local function push_model(out, path, kind, file, cache)
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
	end)
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
	local project = read_json(dir .. "/default.project.json", "project file")
	if project and type(project.tree) == "table" then
		scan_project_node(project.tree, dir, path, out, cache)
		return
	end

	local meta = read_json(dir .. "/init.meta.json", "meta file")
	for _, pair in SCRIPT_SUFFIXES do
		local init_file = dir .. "/init" .. pair[1]
		if fs.isFile(init_file) then
			push_script(out, path, pair[2], init_file, meta, cache)
			out[#out].dir = dir -- children of this script live in this folder
			scan(dir, path, out, cache)
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
	scan(dir, path, out, cache)
end

function scan(dir: string, path: { string }, out, cache)
	local names = fs.readDir(dir)
	table.sort(names)

	for _, name in names do
		local full = dir .. "/" .. name
		if fs.isDir(full) then
			scan_folder(full, child_path(path, name), out, cache)
		else
			local base, class = script_kind(name)
			if base then
				if base ~= "init" then
					push_script(out, child_path(path, base), class, full, read_json(dir .. "/" .. base .. ".meta.json", "meta file"), cache)
				end
			else
				local other, kind = other_kind(name)
				if other and other ~= "init" then
					if kind == "json" or kind == "toml" then
						push_script(out, child_path(path, other), "ModuleScript", full, nil, cache, function(contents)
							return model.data_module(contents, kind)
						end)
					else
						push_model(out, child_path(path, other), kind, full, cache)
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

return mapping
