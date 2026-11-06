-- studio -> disk. the plugin sends scripts, this decides what may be written and where.
-- never deletes, renames or moves a file. never overwrites when creating. never writes into
-- wally packages (nested default.project.json, _Index) or .json / .toml data modules.
--
--   pull.run(project, current, items, dry) -> { written = { key -> file }, refused = { key -> reason } }
--   item = { key, path, class, source?, has_children?, disabled? }   (source not needed when dry)

local fs = require("@lune/fs")

local pull = {}

local SUFFIX = { Script = ".server.luau", LocalScript = ".client.luau", ModuleScript = ".luau" }
local TAKEN = { ".server.luau", ".server.lua", ".client.luau", ".client.lua", ".luau", ".lua", ".meta.json", ".json", ".toml", ".rbxm", ".rbxmx", ".model.json", ".txt", "" }

local function parent_dir(file: string): string
	return file:match("^(.*)[/\\]") or "."
end

-- inside the project, not inside a wally package or any other nested project
local function writable_dir(project, dir: string): (boolean, string?)
	local base = project.base_dir
	if dir:sub(1, #base) ~= base then
		return false, "outside the project folder"
	end
	if dir:find("_Index", 1, true) then
		return false, "inside a Wally package"
	end
	local current = dir
	while #current > #base do
		if fs.isFile(current .. "/default.project.json") or fs.isDir(current .. "/_Index") then
			return false, "inside a nested project (Wally package)"
		end
		current = parent_dir(current)
	end
	return true
end

local function bad_name(name: string): boolean
	return name == "" or name:find("[/\\:%*%?\"<>|]") ~= nil or name:match("^[%s%.]") ~= nil or name:match("[%s%.]$") ~= nil
		or name:lower():match("^init$") ~= nil
end

local function name_taken(dir: string, name: string): boolean
	for _, suffix in TAKEN do
		local p = dir .. "/" .. name .. suffix
		if fs.isFile(p) or fs.isDir(p) then
			return true
		end
	end
	return false
end

-- keep the file's line endings so git shows only the real change
local function write_source(file: string, source: string)
	source = source:gsub("\r\n", "\n")
	if fs.isFile(file) and fs.readFile(file):find("\r\n", 1, true) then
		source = source:gsub("\n", "\r\n")
	end
	fs.writeFile(file, source)
end

local DISABLED_META = '{\n  "properties": {\n    "Disabled": true\n  }\n}\n'

function pull.run(project, current, items, dry: boolean)
	local written, refused = {}, {}

	-- folders that exist on disk for a path key
	local dirs = {}
	for _, root in project.roots do
		if fs.isDir(root.dir) then
			dirs[table.concat(root.path, "/")] = root.dir
		end
	end
	for key, entry in current do
		if entry.dir then
			dirs[key] = entry.dir
		end
	end

	local sorted = table.clone(items)
	table.sort(sorted, function(a, b)
		return #a.path < #b.path
	end)

	for _, item in sorted do
		local key = item.key
		local entry = current[key]
		local file

		if not dry and type(item.source) ~= "string" then
			refused[key] = "no source sent"
			continue
		end

		if type(item.path) ~= "table" or #item.path < 2 or table.concat(item.path, "/") ~= key then
			refused[key] = "bad path"
			continue
		end
		if not SUFFIX[item.class] then
			refused[key] = `{item.class} is not a script`
			continue
		end

		if entry then
			-- update an existing file
			if entry.folder or entry.model then
				refused[key] = "disk has a folder or model here"
				continue
			elseif entry.data then
				refused[key] = "comes from a .json / .toml file"
				continue
			elseif entry.class ~= item.class then
				refused[key] = `disk has a {entry.class}, Studio a {item.class}`
				continue
			end
			local ok, reason = writable_dir(project, parent_dir(entry.file))
			if not ok then
				refused[key] = reason
				continue
			end
			file = entry.file
		else
			-- new file: only next to things that are already on disk
			local name = item.path[#item.path]
			local parent_key = table.concat(item.path, "/", 1, #item.path - 1)
			local dir = dirs[parent_key]
			if not dir then
				local parent = current[parent_key]
				refused[key] = parent and "parent is a script file, make it a folder (init.luau) first"
					or "its parent folder is not on disk (Studio-only)"
				continue
			end
			if bad_name(name) then
				refused[key] = `name "{name}" can't be a file name`
				continue
			end
			local ok, reason = writable_dir(project, dir)
			if not ok then
				refused[key] = reason
				continue
			end
			if name_taken(dir, name) then
				refused[key] = "a file with that name already exists"
				continue
			end

			if item.has_children then
				-- script with child scripts -> Name/init.server.luau, children go inside
				local folder = dir .. "/" .. name
				file = folder .. "/init" .. SUFFIX[item.class]
				dirs[key] = folder
				if not dry then
					fs.writeDir(folder)
					if item.disabled and item.class ~= "ModuleScript" then
						fs.writeFile(folder .. "/init.meta.json", DISABLED_META)
					end
				end
			else
				file = dir .. "/" .. name .. SUFFIX[item.class]
				if not dry and item.disabled and item.class ~= "ModuleScript" then
					fs.writeFile(dir .. "/" .. name .. ".meta.json", DISABLED_META)
				end
			end
		end

		if not dry then
			write_source(file, item.source)
		end
		written[key] = file
	end

	return { written = written, refused = refused }
end

return pull
