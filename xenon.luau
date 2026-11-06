-- xenon cli. run through bin/xenon(.cmd), which sets XENON_CWD to the folder you called it from.
--   xenon serve [project.json] [--port N]   sync that project to studio (default: ./default.project.json, port 34872)
--   xenon build                             build + install the studio plugin
--   xenon test                              run the tests
--   xenon version | help

-- SERVICES -------------------------

local fs = require("@lune/fs")
local process = require("@lune/process")


-- VARIABLES -------------------------

local VERSION = "0.7.1"
local DEFAULT_PORT = 34872

local args = process.args
local command = args[1] or "help"
-- the launcher changes into the xenon folder (so lune is found), the user's folder comes in through XENON_CWD
local caller_dir = process.env.XENON_CWD or process.cwd

local HELP = [[
xenon - safe roblox script sync: disk -> studio live, studio -> disk on Pull.

usage:
  xenon serve [project.json] [--port N]   start syncing (run it in your game folder)
  xenon build                             build + install the studio plugin
  xenon test                              run the tests
  xenon version                           print the version

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

if command == "serve" then
	serve()
elseif command == "build" then
	require("./src/build")()
elseif command == "test" then
	run_tests()
elseif command == "version" or command == "--version" or command == "-v" then
	print("xenon " .. VERSION)
elseif command == "help" or command == "--help" or command == "-h" then
	print(HELP)
else
	print(`[xenon] unknown command "{command}"\n`)
	print(HELP)
	process.exit(1)
end
