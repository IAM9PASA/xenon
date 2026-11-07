-- xenon server: watches the project's files and serves them to the studio plugin.
-- started by the cli:  xenon serve [project.json] [--port N]   (see xenon.luau)
-- api (json, localhost only):
--   GET  /info              { name, placeIds, version, session, scripts, folder }
--   GET  /snapshot          { version, entries = [{ key, path, class, hash, disabled, folder }] }   no sources
--   POST /sources {keys}    { [key] = source | model tree | true (folder) }
--   GET  /changes?since=N   { version, resync?, changes = [{ version, kind, entry(+source) }] }
-- there is no delete endpoint: removed files are reported as "remove" and the plugin keeps the instance
-- models (.rbxm / .model.json / .txt) come back from /sources as instance trees, scripts as source strings

-- SERVICES -------------------------

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")


-- MODULES -------------------------

local mapping = require("./mapping")
local pull = require("./pull")


-- VARIABLES -------------------------

local POLL_SECONDS = 1
local MAX_LOG = 2000
local REMOVE_AFTER = 5 -- rescans (~5 s) a file must stay gone before it is reported deleted

local project -- set by server.start
local cache = {}
local current = {} -- key -> entry
local version = 0
local session = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) -- new id every server start
local log = {} -- { version, kind, entry }
local missing = {} -- key -> { entry, scans }: gone from disk, not reported yet


-- FUNCTIONS -------------------------

local function index(list)
	local map = {}
	for _, entry in list do
		map[entry.key] = entry
	end
	return map
end

local function public(entry, with_source: boolean?)
	return {
		key = entry.key,
		path = entry.path,
		class = entry.class,
		hash = entry.hash,
		disabled = entry.disabled,
		run_context = entry.run_context,
		folder = entry.folder,
		model = entry.model ~= nil or nil,
		data = entry.data,
		source = with_source and entry.source or nil,
		tree = with_source and entry.model or nil,
	}
end

local function record(kind: string, entry)
	version += 1
	table.insert(log, { version = version, kind = kind, entry = entry })
	if #log > MAX_LOG then
		table.remove(log, 1)
	end
end

local function rescan()
	local list = mapping.snapshot(project, cache)
	local fresh = index(list)

	-- parents before children, so the plugin never has to guess a container
	table.sort(list, function(a, b)
		if #a.path ~= #b.path then
			return #a.path < #b.path
		end
		return a.key < b.key
	end)
	for _, entry in list do
		local key = entry.key
		-- back within the grace time: compare with what it was before it went missing
		local old = current[key] or (missing[key] and missing[key].entry)
		missing[key] = nil
		if not old then
			record("create", entry)
		elseif entry.hash ~= old.hash or entry.class ~= old.class or entry.disabled ~= old.disabled or entry.run_context ~= old.run_context then
			record("update", entry)
		end
	end

	-- a file counts as deleted only after REMOVE_AFTER rescans in a row without it.
	-- `wally install` wipes Packages/ and refills it over a few seconds, editors save by rename
	for key, entry in current do
		if not fresh[key] then
			missing[key] = { entry = entry, scans = 0 }
		end
	end
	for key, item in missing do
		item.scans += 1
		if item.scans >= REMOVE_AFTER then
			record("remove", item.entry)
			missing[key] = nil
		end
	end

	current = fresh
end

local function json(data, status: number?)
	return {
		status = status or 200,
		headers = { ["Content-Type"] = "application/json" },
		body = serde.encode("json", data),
	}
end

local function handle(request)
	local path = request.path

	if path == "/info" then
		local scripts = 0
		for _, entry in current do
			if not entry.folder then
				scripts += 1
			end
		end
		return json({ name = project.name, placeIds = project.place_ids, version = version, session = session, scripts = scripts, folder = project.base_dir })
	end

	if path == "/snapshot" then
		-- parents before children so the plugin can create containers first
		local list = {}
		for _, entry in current do
			table.insert(list, public(entry))
		end
		table.sort(list, function(a, b)
			if #a.path ~= #b.path then
				return #a.path < #b.path
			end
			return a.key < b.key
		end)
		local roots = {}
		for _, root in project.roots do
			table.insert(roots, root.path)
		end
		return json({ version = version, session = session, roots = roots, entries = list })
	end

	if path == "/sources" and request.method == "POST" then
		local ok, body = pcall(serde.decode, "json", request.body)
		if not ok or type(body) ~= "table" or type(body.keys) ~= "table" then
			return json({ error = "expected { keys = [...] }" }, 400)
		end
		-- scripts -> source string, models -> instance tree table
		local out = {}
		for _, key in body.keys do
			local entry = current[key]
			if entry then
				out[key] = entry.source or entry.model or (entry.folder and true) or nil -- true: folder still on disk
			end
		end
		return json(out)
	end

	if path == "/pull" and request.method == "POST" then
		local ok, body = pcall(serde.decode, "json", request.body)
		if not ok or type(body) ~= "table" or type(body.items) ~= "table" then
			return json({ error = "expected { items = [...], dry = bool }" }, 400)
		end
		local result = pull.run(project, current, body.items, body.dry == true)
		if not body.dry then
			local count = 0
			for key, file in result.written do
				count += 1
				print(`[xenon] pulled {key} -> {file}`)
			end
			if count > 0 then
				rescan() -- written files show up as changes with studio's hash, so nothing bounces back
			end
		end
		return json(result)
	end

	if path == "/changes" then
		local since = tonumber(request.query and request.query.since) or 0
		local oldest = log[1] and log[1].version or version + 1
		-- since > version: the plugin knew a newer server run, this one restarted
		if since > version or (since < oldest - 1 and since < version) then
			return json({ version = version, session = session, resync = true, changes = {} })
		end
		local changes = {}
		for _, item in log do
			if item.version > since then
				table.insert(changes, { version = item.version, kind = item.kind, entry = public(item.entry, item.kind ~= "remove") })
			end
		end
		return json({ version = version, session = session, changes = changes })
	end

	return json({ error = "not found" }, 404)
end


-- MAIN -------------------------

local server = {}

-- loads the project and does the first scan. a fresh run: new session, version 0, empty log.
-- tests call init / rescan / handle directly, without the http server
function server.init(project_file: string)
	project = mapping.load_project(project_file)
	cache = {}
	version = 0
	log = {}
	missing = {}
	session = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
	current = index(mapping.snapshot(project, cache))
end

server.rescan = rescan
server.handle = handle

-- blocks forever: initial scan, http server, rescan loop
function server.start(project_file: string, port: number)
	server.init(project_file)

	local count = 0
	for _, entry in current do
		if not entry.folder then
			count += 1
		end
	end

	local served, serve_error = pcall(net.serve, port, function(request)
		local ok, response = pcall(handle, request)
		if ok then
			return response
		end
		warn("[xenon] request failed: " .. tostring(response))
		return json({ error = tostring(response) }, 500)
	end)
	if not served then
		local message = tostring(serve_error)
		if message:find("10048", 1, true) or message:lower():find("address already in use", 1, true) then
			print(`[xenon] port {port} is already in use: another xenon serve is probably still running (another terminal, or a game folder you synced before).`)
			print(`[xenon] see which: xenon status --port {port}`)
			print(`[xenon] stop that one (Ctrl+C in its terminal), or use another port: xenon serve --port {port + 1}  (and set the same port in the plugin's settings)`)
		else
			print(`[xenon] can't start the server on port {port}: {message}`)
		end
		process.exit(1)
	end

	print(`[xenon] serving "{project.name}" on http://localhost:{port}  ({count} scripts)`)
	print("[xenon] studio: Plugins tab -> Xenon -> Connect.  stop: Ctrl+C")

	while true do
		task.wait(POLL_SECONDS)
		local ok, err = pcall(rescan)
		if not ok then
			warn("[xenon] rescan failed: " .. tostring(err))
		end
	end
end

return server
