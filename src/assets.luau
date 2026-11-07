-- the files xenon ships with: the studio plugin sources and the project template.
-- from a source checkout they are read from disk (the cli runs in the xenon folder).
-- the release exe has them baked in: tools/bundle.luau swaps this module for one that holds the contents.

local fs = require("@lune/fs")

local assets = {}

assets.bundled = false

-- { main, checksum, diff, tree } source text for the plugin
function assets.plugin()
	return {
		main = fs.readFile("plugin/xenon_plugin.luau"),
		checksum = fs.readFile("src/checksum.luau"),
		diff = fs.readFile("src/diff.luau"),
		tree = fs.readFile("plugin/tree.luau"),
	}
end

-- every file under dir as { ["sub/path.ext"] = contents }
function assets.read_tree(dir: string)
	local files = {}
	local function walk(path: string, prefix: string)
		for _, name in fs.readDir(path) do
			local full = path .. "/" .. name
			if fs.isDir(full) then
				walk(full, prefix .. name .. "/")
			else
				files[prefix .. name] = fs.readFile(full)
			end
		end
	end
	walk(dir, "")
	return files
end

function assets.template()
	return assets.read_tree("template")
end

return assets
