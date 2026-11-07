-- packs the plugin (plugin/xenon_plugin.luau + checksum + diff modules) into Xenon.rbxm
-- and installs it into studio's Plugins folder.
--   xenon build    from a source checkout (also writes Xenon.rbxm in the xenon folder)
--   xenon plugin   from anywhere, the release exe uses the copy baked into it

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local assets = require("./assets")

local function plugins_folder(): string
	-- windows: %LOCALAPPDATA%\Roblox\Plugins, mac: ~/Documents/Roblox/Plugins
	if process.env.LOCALAPPDATA then
		return process.env.LOCALAPPDATA .. "/Roblox/Plugins"
	elseif process.env.HOME then
		return process.env.HOME .. "/Documents/Roblox/Plugins"
	end
	error("can't find the Roblox Plugins folder (no LOCALAPPDATA or HOME)")
end

return function(write_local: boolean?)
	local sources = assets.plugin()

	local plugin_script = roblox.Instance.new("Script")
	plugin_script.Name = "Xenon"
	plugin_script.Source = sources.main

	for _, name in { "checksum", "diff" } do
		local module = roblox.Instance.new("ModuleScript")
		module.Name = name
		module.Source = sources[name]
		module.Parent = plugin_script
	end

	local plugins_dir = plugins_folder()
	if not fs.isDir(plugins_dir) then
		fs.writeDir(plugins_dir)
	end

	local model = roblox.serializeModel({ plugin_script })
	if write_local then
		fs.writeFile("Xenon.rbxm", model)
	end
	fs.writeFile(plugins_dir .. "/Xenon.rbxm", model)
	print(`[xenon] installed the studio plugin ({#model} bytes) -> {plugins_dir}/Xenon.rbxm`)
	print("[xenon] restart studio (or reload plugins) to load it")
end
