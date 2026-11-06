-- maps project files to studio instance paths, scripts only. same naming rules as argon / rojo:
--   Name.server.luau -> Script, Name.client.luau -> LocalScript, Name.luau -> ModuleScript
--   Folder/init.*.luau -> the folder itself is that script, Folder/init.meta.json -> folder class / props
--   Name.meta.json -> props for Name (Disabled / Enabled), first line "--disable" -> disabled
-- other file types (.rbxm, .model.json, .json data...) are ignored in v1

-- SERVICES -------------------------

local fs = require("@lune/fs")
local serde = require("@lune/serde")


-- MODULES -------------------------

local checksum = require("./checksum")


-- VARIABLES -------------------------

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".server.lua", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".client.lua", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".lua", "ModuleScript" },
}

local mapping = {}


-- FUNCTIONS -------------------------

local function script_kind(file_name: string): (string?, string?)
	for _, pair in SCRIPT_SUFFIXES do
		local suffix = pair[1]
		if #file_name > #suffix and file_name:sub(-#suffix) == suffix then
			return file_name:sub(1, -#suffix - 1), pair[2]
		end
	end
	return nil, nil
end

local function read_meta(path: string)
	if not fs.isFile(path) then
		return nil
	end
	local ok, data = pcall(serde.decode, "json", fs.readFile(path))
	if ok and type(data) == "table" then
		return data
	end
	warn(`[xenon] bad meta file {path}`)
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

-- reads a script through the mtime cache so unchanged files are not re-read every poll
local function read_script(file: string, cache)
	local modified = fs.metadata(file).modifiedAt
	local stamp = modified and modified.unixTimestampMillis or 0
	local hit = cache[file]
	if hit and hit.stamp == stamp then
		return hit.source, hit.hash
	end

	local source = (fs.readFile(file):gsub("\r\n", "\n"))
	local hash = checksum(source)
	cache[file] = { stamp = stamp, source = source, hash = hash }
	return source, hash
end

local function push_script(out, path, class, file, meta, cache)
	local source, hash = read_script(file, cache)
	-- modules have no Enabled property, so they carry no flag at all
	local disabled = nil
	if class ~= "ModuleScript" then
		disabled = is_disabled(meta, source)
	end
	table.insert(out, {
		key = table.concat(path, "/"),
		path = path,
		class = class,
		source = source,
		hash = hash,
		disabled = disabled,
		file = file,
	})
end

local scan

-- a folder is either a script (init file inside) or a container (Folder / init.meta.json className)
local function scan_folder(dir: string, path: { string }, out, cache)
	local meta = read_meta(dir .. "/init.meta.json")

	for _, pair in SCRIPT_SUFFIXES do
		local init_file = dir .. "/init" .. pair[1]
		if fs.isFile(init_file) then
			push_script(out, path, pair[2], init_file, meta, cache)
			scan(dir, path, out, cache)
			return
		end
	end

	table.insert(out, {
		key = table.concat(path, "/"),
		path = path,
		class = meta and meta.className or "Folder",
		folder = true,
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
			if base and base ~= "init" then
				push_script(out, child_path(path, base), class, full, read_meta(dir .. "/" .. base .. ".meta.json"), cache)
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

	return { name = project.name or "project", place_ids = project.placeIds or {}, roots = roots }
end

-- every script / folder under the mapped roots, parents before children
function mapping.snapshot(project, cache)
	local out = {}
	for _, root in project.roots do
		if fs.isDir(root.dir) then
			scan(root.dir, root.path, out, cache or {})
		end
	end
	return out
end

mapping.script_kind = script_kind

return mapping
