-- xenon server: watches the project's files and serves them to the studio plugin.
-- started by the cli:  xenon serve [project.json] [--port N]   (see xenon.luau)
-- api (json, localhost only):
--   GET  /info              { name, placeIds, version, scripts }
--   GET  /snapshot          { version, entries = [{ key, path, class, hash, disabled, folder }] }   no sources
--   POST /sources {keys}    { [key] = source }
--   GET  /changes?since=N   { version, resync?, changes = [{ version, kind, entry(+source) }] }
-- there is no delete endpoint: removed files are reported as "remove" and the plugin keeps the instance
-- models (.rbxm / .model.json / .txt) come back from /sources as instance trees, scripts as source strings

-- SERVICES -------------------------

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")


-- MODULES -------------------------

local mapping = require("./mapping")


-- VARIABLES -------------------------

local POLL_SECONDS = 1
local MAX_LOG = 2000

local project -- set by server.start
local cache = {}
local current = {} -- key -> entry
local version = 0
local session = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) -- new id every server start
local log = {} -- { version, kind, entry }


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
		folder = entry.folder,
		model = entry.model ~= nil or nil,
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
	local fresh = index(mapping.snapshot(project, cache))

	for key, entry in fresh do
		local old = current[key]
		if not old then
			record("create", entry)
		elseif entry.hash ~= old.hash or entry.class ~= old.class or entry.disabled ~= old.disabled then
			record("update", entry)
		end
	end
	for key, entry in current do
		if not fresh[key] then
			record("remove", entry)
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
		return json({ name = project.name, placeIds = project.place_ids, version = version, session = session, scripts = scripts })
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
		return json({ version = version, session = session, entries = list })
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
				out[key] = entry.source or entry.model
			end
		end
		return json(out)
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

-- blocks forever: initial scan, http server, rescan loop
function server.start(project_file: string, port: number)
	project = mapping.load_project(project_file)
	current = index(mapping.snapshot(project, cache))

	local count = 0
	for _, entry in current do
		if not entry.folder then
			count += 1
		end
	end

	net.serve(port, function(request)
		local ok, response = pcall(handle, request)
		if ok then
			return response
		end
		warn("[xenon] request failed: " .. tostring(response))
		return json({ error = tostring(response) }, 500)
	end)

	print(`[xenon] serving "{project.name}" on http://localhost:{port}  ({count} scripts, never deletes)`)
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
