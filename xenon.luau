-- xenon cli. from a source checkout it runs through bin/xenon(.cmd), which sets XENON_CWD to the folder
-- you called it from. the release exe (tools/bundle.luau + lune build) runs in your folder directly.
--   xenon init [folder]                     new project from template/ (folder must be new or empty)
--   xenon plugin                            install the studio plugin
--   xenon status [--port N]                 is a xenon server running on that port, and for which project
--   xenon serve [project.json] [--port N]   sync that project to studio (default: ./default.project.json, port 34872)
--   xenon build                             build + install the studio plugin
--   xenon test                              run the tests
--   xenon version | help

-- SERVICES -------------------------

local fs = require("@lune/fs")
local process = require("@lune/process")
local net = require("@lune/net")
local serde = require("@lune/serde")

local assets = require("./src/assets")


-- VARIABLES -------------------------

local VERSION = "0.9.4"
local DEFAULT_PORT = 34872

local args = process.args
local command = args[1] or "help"
-- the launcher changes into the xenon folder (so lune is found), the user's folder comes in through XENON_CWD
local caller_dir = ((process.env.XENON_CWD or process.cwd):gsub("[/\\]+$", ""))

local HELP = [[
xenon - safe roblox script sync: disk -> studio live, studio -> disk on Pull.

usage:
  xenon init [folder] [--name "Name"]     new game project (default: this folder, must be empty)
  xenon serve [project.json] [--port N]   start syncing (run it in your game folder)
  xenon plugin                            install the studio plugin
  xenon status [--port N]                 is a xenon server running on that port, for which project
  xenon version                           print the version

from a source checkout also:
  xenon build                             build Xenon.rbxm + install the plugin
  xenon test                              run the tests

then in studio: Plugins tab -> Xenon -> Connect]]


-- FUNCTIONS -------------------------

local function is_absolute(path: string): boolean
	return path:match("^%a:[/\\]") ~= nil or path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
end

local function fail(message: string)
	print("[xenon] " .. message)
	process.exit(1)
end

local function serve()
	local project_arg, port = nil, DEFAULT_PORT
	local i = 2
	while i <= #args do
		local value = args[i]
		if value == "--port" or value == "-p" then
			port = tonumber(args[i + 1]) or fail("--port needs a number")
			i += 2
		else
			project_arg = value
			i += 1
		end
	end

	local project_file = project_arg or "default.project.json"
	if not is_absolute(project_file) then
		project_file = caller_dir .. "/" .. project_file
	end
	if not fs.isFile(project_file) then
		fail(`no project file at {project_file}\nrun it in your game folder, or pass the path: xenon serve path/to/default.project.json`)
	end

	require("./src/server").start(project_file, port)
end

local function init()
	local folder, display_name = nil, nil
	local i = 2
	while i <= #args do
		if args[i] == "--name" or args[i] == "-n" then
			display_name = args[i + 1] or fail("--name needs a value")
			i += 2
		else
			folder = args[i]
			i += 1
		end
	end
	local target = caller_dir
	if folder then
		target = is_absolute(folder) and folder or (caller_dir .. "/" .. folder)
	end
	target = (target:gsub("[/\\]+$", ""))
	local name = display_name or target:match("([^/\\]+)$") or "game"

	local ok, message, created = require("./src/init_project")(assets.template(), target, name)
	if not ok then
		fail(message)
	end
	print(`[xenon] {message} in {target}`)
	for _, file in created do
		print("  + " .. file:sub(#target + 2))
	end
	local steps = {
		"",
		"next:",
		folder and ("  cd " .. (folder:find(" ") and `"{folder}"` or folder)) or nil,
		"  rokit install      (wally)",
		"  xenon serve",
		"  studio: Plugins -> Xenon -> Connect",
		"  put your place id in placeIds in default.project.json",
	}
	local lines = {}
	for i = 1, 7 do
		if steps[i] then
			table.insert(lines, steps[i])
		end
	end
	print(table.concat(lines, "\n"))
end

local function status()
	local port = DEFAULT_PORT
	if args[2] == "--port" or args[2] == "-p" then
		port = tonumber(args[3]) or fail("--port needs a number")
	elseif args[2] then
		port = tonumber(args[2]) or fail("usage: xenon status [--port N]")
	end

	local asked, response = pcall(net.request, `http://localhost:{port}/info`)
	if asked then
		local decoded, info = pcall(serde.decode, "json", response.body)
		if response.ok and decoded and type(info) == "table" and info.session then
			print(`[xenon] port {port}: xenon is running "{info.name}" ({info.scripts} scripts)`)
			if info.folder then
				print(`  folder: {info.folder}`)
			end
			if info.placeIds and #info.placeIds > 0 then
				print(`  places: {table.concat(info.placeIds, ", ")}`)
			end
			return
		end
		print(`[xenon] port {port} is used by something that is not xenon. pick another: xenon serve --port {port + 1}`)
		process.exit(1)
	end

	-- nothing answered http: free, unless a non-http program holds it (binding tells)
	-- shortcut: a program bound only to 127.0.0.1 still reads as free (serve binds all interfaces), upgrade with a raw tcp connect if that bites
	local bound, handle = pcall(net.serve, port, function()
		return { status = 503, body = "" }
	end)
	if bound then
		handle.stop()
		print(`[xenon] port {port} is free: no xenon server running. start one: xenon serve`)
	else
		print(`[xenon] port {port} is used by another program (not xenon). pick another: xenon serve --port {port + 1}`)
		process.exit(1)
	end
end

local function run_tests()
	local failed = 0
	for _, name in fs.readDir("tests") do
		if name:match("_test%.luau$") then
			local result = process.exec("lune", { "run", "tests/" .. name })
			local last = result.stdout:match("([^\n]+)\n*$") or ""
			print(`{result.ok and "ok  " or "FAIL"} {name}: {last}`)
			if not result.ok then
				failed += 1
				print(result.stdout .. result.stderr)
			end
		end
	end
	if failed > 0 then
		process.exit(1)
	end
end


-- MAIN -------------------------

if command == "init" then
	init()
elseif command == "serve" then
	serve()
elseif command == "status" then
	status()
elseif command == "plugin" then
	require("./src/build")(false)
elseif command == "build" or command == "test" then
	if assets.bundled then
		fail(`"{command}" needs the xenon source folder. to install the plugin: xenon plugin`)
	end
	if command == "build" then
		require("./src/build")(true)
	else
		run_tests()
	end
elseif command == "version" or command == "--version" or command == "-v" then
	print("xenon " .. VERSION)
elseif command == "help" or command == "--help" or command == "-h" then
	print(HELP)
else
	print(`[xenon] unknown command "{command}"\n`)
	print(HELP)
	process.exit(1)
end
