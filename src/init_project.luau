-- xenon init: copies the project template into a new project folder.
-- never writes into a folder that already has files, so it can't overwrite anything.
--
--   init_project(template, target_dir, name) -> (ok, message, created_files)
--   template: a folder path, or { ["sub/path.ext"] = contents } (what assets.template() gives)

local fs = require("@lune/fs")

local assets = require("./assets")

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

local function make_dirs(path: string)
	local parent = path:match("^(.+)[/\\][^/\\]+$")
	if parent and not fs.isDir(parent) then
		make_dirs(parent)
	end
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

return function(template: string | { [string]: string }, target_dir: string, name: string)
	if type(template) == "string" then
		if not fs.isDir(template) then
			return false, `template folder missing: {template}`, {}
		end
		template = assets.read_tree(template)
	end
	if fs.isFile(target_dir) then
		return false, `{target_dir} is a file`, {}
	end
	if fs.isDir(target_dir) and #fs.readDir(target_dir) > 0 then
		return false, `{target_dir} is not empty. xenon init only writes into a new or empty folder`, {}
	end

	local paths = {}
	for path in template :: { [string]: string } do
		table.insert(paths, path)
	end
	table.sort(paths)

	local created = {}
	make_dirs(target_dir)
	for _, path in paths do
		local dir, file = path:match("^(.*)/([^/]+)$")
		dir, file = dir or "", file or path
		local target = target_dir .. (dir ~= "" and "/" .. dir or "") .. "/" .. (RENAME[file] or file)
		make_dirs(target:match("^(.+)/[^/]+$"))
		fs.writeFile(target, fill((template :: any)[path], name))
		table.insert(created, target)
	end
	return true, `created {name} ({#created} files)`, created
end
