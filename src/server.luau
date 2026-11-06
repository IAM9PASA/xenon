-- xenon server: watches the project's scripts and serves them to the studio plugin.
-- run from the game folder:  lune run <xenon>/src/server.luau [default.project.json] [port]
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
local process = require("@lune/process")
local task = require("@lune/task")


-- MODULES -------------------------

local mapping = require("./mapping")


-- VARIABLES -------------------------

local PROJECT_FILE = process.args[1] or "default.project.json"
local PORT = tonumber(process.args[2]) or 34872
local POLL_SECONDS = 1
local MAX_LOG = 2000

local project = mapping.load_project(PROJECT_FILE)
local cache = {}
local current = {} -- key -> entry
local version = 0
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
		return json({ name = project.name, placeIds = project.place_ids, version = version, scripts = scripts })
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
		return json({ version = version, entries = list })
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
		if since < oldest - 1 and since < version then
			return json({ version = version, resync = true, changes = {} })
		end
		local changes = {}
		for _, item in log do
			if item.version > since then
				table.insert(changes, { version = item.version, kind = item.kind, entry = public(item.entry, item.kind ~= "remove") })
			end
		end
		return json({ version = version, changes = changes })
	end

	return json({ error = "not found" }, 404)
end


-- MAIN -------------------------

current = index(mapping.snapshot(project, cache))
local count = 0
for _, entry in current do
	if not entry.folder then
		count += 1
	end
end

net.serve(PORT, function(request)
	local ok, response = pcall(handle, request)
	if ok then
		return response
	end
	warn("[xenon] request failed: " .. tostring(response))
	return json({ error = tostring(response) }, 500)
end)

print(`[xenon] serving "{project.name}" on http://localhost:{PORT}  ({count} scripts, never deletes)`)

while true do
	task.wait(POLL_SECONDS)
	local ok, err = pcall(rescan)
	if not ok then
		warn("[xenon] rescan failed: " .. tostring(err))
	end
end
