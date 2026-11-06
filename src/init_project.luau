-- xenon init: copies template/ into a new project folder.
-- never writes into a folder that already has files, so it can't overwrite anything.
--
--   init_project(template_dir, target_dir, name) -> (ok, message, created_files)

local fs = require("@lune/fs")

-- template files with a different name on disk (so they don't act on the xenon repo itself)
local RENAME = {
	["gitignore.txt"] = ".gitignore",
}

local function package_name(name: string): string
	-- wally package names: lowercase, digits, dashes
	local out = name:lower():gsub("[^%w%-]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
	return out ~= "" and out or "game"
end

local function fill(text: string, name: string): string
	return (text:gsub("{{name}}", name):gsub("{{package}}", package_name(name)))
end

local function copy(from_dir: string, to_dir: string, name: string, created)
	fs.writeDir(to_dir)
	local entries = fs.readDir(from_dir)
	table.sort(entries)
	for _, entry in entries do
		local source = from_dir .. "/" .. entry
		local target = to_dir .. "/" .. (RENAME[entry] or entry)
		if fs.isDir(source) then
			copy(source, target, name, created)
		else
			fs.writeFile(target, fill(fs.readFile(source), name))
			table.insert(created, target)
		end
	end
end

return function(template_dir: string, target_dir: string, name: string)
	if not fs.isDir(template_dir) then
		return false, `template folder missing: {template_dir}`, {}
	end
	if fs.isFile(target_dir) then
		return false, `{target_dir} is a file`, {}
	end
	if fs.isDir(target_dir) and #fs.readDir(target_dir) > 0 then
		return false, `{target_dir} is not empty. xenon init only writes into a new or empty folder`, {}
	end

	local created = {}
	copy(template_dir, target_dir, name, created)
	return true, `created {name} ({#created} files)`, created
end
