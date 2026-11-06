-- packs plugin/xenon_plugin.luau + src/checksum.luau + src/diff.luau into Xenon.rbxm and installs it into studio's Plugins folder.
-- called by the cli:  xenon build   (paths are relative to the xenon folder, the cli runs from there)

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

return function()
	local plugin_script = roblox.Instance.new("Script")
	plugin_script.Name = "Xenon"
	plugin_script.Source = fs.readFile("plugin/xenon_plugin.luau")

	local checksum = roblox.Instance.new("ModuleScript")
	checksum.Name = "checksum"
	checksum.Source = fs.readFile("src/checksum.luau")
	checksum.Parent = plugin_script

	local diff = roblox.Instance.new("ModuleScript")
	diff.Name = "diff"
	diff.Source = fs.readFile("src/diff.luau")
	diff.Parent = plugin_script

	-- windows: %LOCALAPPDATA%\Roblox\Plugins, mac: ~/Documents/Roblox/Plugins
	local plugins_dir
	if process.env.LOCALAPPDATA then
		plugins_dir = process.env.LOCALAPPDATA .. "/Roblox/Plugins"
	elseif process.env.HOME then
		plugins_dir = process.env.HOME .. "/Documents/Roblox/Plugins"
	else
		error("can't find the Roblox Plugins folder (no LOCALAPPDATA or HOME)")
	end
	if not fs.isDir(plugins_dir) then
		fs.writeDir(plugins_dir)
	end

	local model = roblox.serializeModel({ plugin_script })
	fs.writeFile("Xenon.rbxm", model)
	fs.writeFile(plugins_dir .. "/Xenon.rbxm", model)
	print(`[xenon] built Xenon.rbxm ({#model} bytes) -> {plugins_dir}/Xenon.rbxm`)
	print("[xenon] restart studio (or reload plugins) to load it")
end
