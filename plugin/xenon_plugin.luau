-- xenon studio plugin: scripts from disk -> studio. never deletes anything.
-- talks to the xenon server (lune) on localhost. built into Plugins/Xenon.rbxm by build_plugin.luau

-- SERVICES -------------------------

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local CollectionService = game:GetService("CollectionService")


-- MODULES -------------------------

local checksum = require(script.checksum)


-- VARIABLES -------------------------

local PORT = plugin:GetSetting("xenon_port") or 34872
local BASE_URL = `http://localhost:{PORT}`
local POLL_SECONDS = 0.5
local LIVE_PROMPT_OVER = 20 -- bigger live batches wait for Apply instead of going straight in
local SOURCE_BATCH = 80

local connected = false
local version = 0
local known_hash = {} -- key -> hash studio had when xenon last synced it (conflict check)
local pending = nil -- plan waiting for Apply

-- toolbar icon: a decal id (user's choice). toolbar icons need the decal's image id, resolved at startup
local ICON_DECAL_ID = 57445653

local toolbar = plugin:CreateToolbar("Xenon")
local toggle_button = toolbar:CreateButton("Xenon", "Sync scripts from disk (never deletes)", "")
toggle_button.ClickableWhenViewportHidden = true

task.spawn(function()
	local ok, objects = pcall(function()
		return game:GetObjects(`rbxassetid://{ICON_DECAL_ID}`)
	end)
	local decal = ok and objects and objects[1]
	if decal and decal:IsA("Decal") and decal.Texture ~= "" then
		toggle_button.Icon = decal.Texture
	else
		warn(`[xenon] could not load icon decal {ICON_DECAL_ID}`)
	end
end)

local widget = plugin:CreateDockWidgetPluginGui(
	"Xenon",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 380, 300, 320, 220)
)
widget.Title = "Xenon"


-- FUNCTIONS -------------------------

-- ui ---------------------------------

local function make(class, props, parent)
	local inst = Instance.new(class)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local root = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(30, 30, 34), BorderSizePixel = 0 }, widget)
make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }, root)

local status_label = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Font = Enum.Font.BuilderSansBold,
	TextSize = 16,
	TextColor3 = Color3.fromRGB(235, 235, 240),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Disconnected",
}, root)

local detail_box = make("ScrollingFrame", {
	Position = UDim2.new(0, 0, 0, 28),
	Size = UDim2.new(1, 0, 1, -70),
	BackgroundColor3 = Color3.fromRGB(20, 20, 24),
	BorderSizePixel = 0,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 4,
}, root)
local detail_label = make("TextLabel", {
	Size = UDim2.fromScale(1, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(180, 180, 190),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Text = "",
}, detail_box)
make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 6) }, detail_label)

local function button(text, x, color)
	return make("TextButton", {
		Position = UDim2.new(x, x > 0 and 4 or 0, 1, -34),
		Size = UDim2.new(1 / 3, -4, 0, 34),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = Enum.Font.BuilderSansBold,
		TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1),
		Text = text,
		AutoButtonColor = true,
	}, root)
end
local connect_button = button("Connect", 0, Color3.fromRGB(46, 120, 230))
local apply_button = button("Apply", 1 / 3, Color3.fromRGB(40, 150, 90))
local cancel_button = button("Cancel", 2 / 3, Color3.fromRGB(90, 90, 100))

local function set_status(text, detail)
	status_label.Text = text
	if detail then
		detail_label.Text = detail
	end
end

local function refresh_buttons()
	connect_button.Text = connected and "Disconnect" or "Connect"
	apply_button.Visible = pending ~= nil
	cancel_button.Visible = pending ~= nil
end

-- server ------------------------------

local function request(method, path, body)
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = BASE_URL .. path,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
		Body = body and HttpService:JSONEncode(body) or nil,
	})
	if not ok then
		return nil, tostring(response)
	end
	if not response.Success then
		return nil, `{response.StatusCode} {response.StatusMessage}`
	end
	return HttpService:JSONDecode(response.Body)
end

local function fetch_sources(entries)
	local keys = {}
	-- scripts come back as source strings, models as instance trees
	for _, entry in entries do
		if not entry.folder and not entry.source and not entry.tree then
			table.insert(keys, entry.key)
		end
	end
	local sources = {}
	for i = 1, #keys, SOURCE_BATCH do
		local chunk = table.move(keys, i, math.min(i + SOURCE_BATCH - 1, #keys), 1, {})
		local result, err = request("POST", "/sources", { keys = chunk })
		if not result then
			return nil, err
		end
		for key, source in result do
			sources[key] = source
		end
	end
	for _, entry in entries do
		if entry.source or entry.tree then
			sources[entry.key] = entry.source or entry.tree
		end
	end
	return sources
end

-- studio tree --------------------------

local function service(name)
	local ok, found = pcall(game.GetService, game, name)
	return ok and found or game:FindFirstChild(name)
end

local function find(path)
	local node = service(path[1])
	for i = 2, #path do
		if not node then
			return nil
		end
		node = node:FindFirstChild(path[i])
	end
	return node
end

-- creates missing ancestors as Folders, the last one as `class`. never removes or replaces anything
local function ensure(path, class)
	local node = service(path[1])
	for i = 2, #path do
		local child = node:FindFirstChild(path[i])
		if not child then
			local ok, created = pcall(Instance.new, i == #path and class or "Folder")
			child = ok and created or Instance.new("Folder")
			child.Name = path[i]
			child.Parent = node
		end
		node = child
	end
	return node
end

local function studio_hash(inst)
	return checksum(inst.Source)
end

-- models (.rbxm / .model.json / .txt) ---------

local function decode(value)
	local kind = value[1]
	if kind == "string" or kind == "number" or kind == "boolean" then
		return value[2]
	elseif kind == "Vector3" then
		return Vector3.new(value[2], value[3], value[4])
	elseif kind == "Vector2" then
		return Vector2.new(value[2], value[3])
	elseif kind == "Color3" then
		return Color3.new(value[2], value[3], value[4])
	elseif kind == "UDim" then
		return UDim.new(value[2], value[3])
	elseif kind == "UDim2" then
		return UDim2.new(value[2], value[3], value[4], value[5])
	elseif kind == "CFrame" then
		return CFrame.new(table.unpack(value, 2, 13))
	elseif kind == "NumberRange" then
		return NumberRange.new(value[2], value[3])
	elseif kind == "Rect" then
		return Rect.new(value[2], value[3], value[4], value[5])
	elseif kind == "BrickColor" then
		return BrickColor.new(value[2])
	elseif kind == "EnumItem" then
		return (Enum :: any)[value[2]][value[3]]
	elseif kind == "NumberSequence" then
		local points = {}
		for _, p in value[2] do
			table.insert(points, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
		end
		return NumberSequence.new(points)
	elseif kind == "ColorSequence" then
		local points = {}
		for _, p in value[2] do
			table.insert(points, ColorSequenceKeypoint.new(p[1], Color3.new(p[2], p[3], p[4])))
		end
		return ColorSequence.new(points)
	elseif kind == "Font" then
		return Font.new(value[2], Enum.FontWeight[value[3]], Enum.FontStyle[value[4]])
	end
	return nil
end

-- asset fields: new Content properties first, then the older string property (MeshContent -> MeshId)
local function set_content(inst, name, uri)
	local ok = pcall(function()
		inst[name] = Content.fromUri(uri)
	end)
	if ok then
		return
	end
	local legacy = name == "MeshContent" and "MeshId" or name:gsub("Content$", "")
	pcall(function()
		inst[legacy] = uri
	end)
end

local function new_instance(node)
	if node.class == "MeshPart" then
		local mesh = node.props.MeshContent or node.props.MeshId
		local uri = mesh and mesh[2]
		if uri then
			local ok, part = pcall(function()
				return AssetService:CreateMeshPartAsync(Content.fromUri(uri))
			end)
			if not ok then
				ok, part = pcall(function()
					return InsertService:CreateMeshPartAsync(uri, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
				end)
			end
			if ok and part then
				return part
			end
			warn(`[xenon] mesh {uri} could not be loaded, plain MeshPart used`)
		end
	end
	local ok, inst = pcall(Instance.new, node.class)
	if ok then
		return inst
	end
	warn(`[xenon] cannot create {node.class}, Folder used`)
	return Instance.new("Folder")
end

local function build_node(node, by_id, refs)
	local inst = new_instance(node)
	inst.Name = node.name
	by_id[node.id] = inst

	for name, value in node.props do
		local kind = value[1]
		if kind == "Ref" then
			table.insert(refs, { inst = inst, name = name, id = value[2] })
		elseif kind == "Content" then
			if name ~= "MeshContent" and name ~= "MeshId" then
				set_content(inst, name, value[2])
			end
		elseif name == "Source" and inst:IsA("LuaSourceContainer") then
			inst.Source = value[2]
		else
			local decoded = decode(value)
			if decoded ~= nil then
				pcall(function()
					inst[name] = decoded
				end)
			end
		end
	end
	for key, value in node.attrs or {} do
		local decoded = decode(value)
		if decoded ~= nil then
			pcall(inst.SetAttribute, inst, key, decoded)
		end
	end
	for _, tag in node.tags or {} do
		CollectionService:AddTag(inst, tag)
	end
	for _, child in node.children or {} do
		build_node(child, by_id, refs).Parent = inst
	end
	return inst
end

-- builds the tree, wires refs (welds, PrimaryPart...), parents it under path's parent
local function build_model(entry, tree)
	local by_id, refs = {}, {}
	local root = build_node(tree, by_id, refs)
	for _, ref in refs do
		local target = by_id[ref.id]
		if target then
			pcall(function()
				ref.inst[ref.name] = target
			end)
		end
	end
	root.Name = entry.path[#entry.path]
	root:SetAttribute("xenon_hash", entry.hash)

	local parent_path = table.move(entry.path, 1, #entry.path - 1, 1, {})
	root.Parent = #parent_path == 1 and service(parent_path[1]) or ensure(parent_path, "Folder")
	return root
end

-- plan / apply --------------------------

local function describe(plan)
	local lines = {
		`create {#plan.create}   update {#plan.update}   conflicts {#plan.conflicts}   skipped {#plan.skip}   delete 0`,
		"",
	}
	local function list(title, items, limit)
		if #items == 0 then
			return
		end
		table.insert(lines, title)
		for i = 1, math.min(limit, #items) do
			local item = items[i]
			table.insert(lines, "  " .. (type(item) == "table" and item.key or item))
		end
		if #items > limit then
			table.insert(lines, `  ... and {#items - limit} more`)
		end
		table.insert(lines, "")
	end
	list("CONFLICT (edited in studio AND on disk, not touched):", plan.conflicts, 15)
	list("update:", plan.update, 15)
	list("create:", plan.create, 15)
	list("skipped (studio has a different class):", plan.skip, 10)
	list("model changed on disk (kept, delete it in studio to re-create):", plan.models_changed or {}, 10)
	return table.concat(lines, "\n")
end

local function plan_for(entries, live)
	local plan = { create = {}, update = {}, conflicts = {}, skip = {}, models_changed = {} }
	for i, entry in entries do
		local inst = find(entry.path)
		if not inst then
			table.insert(plan.create, entry)
		elseif entry.model then
			-- models are only created, never replaced: report disk changes to models xenon made
			local stamp = inst:GetAttribute("xenon_hash")
			if stamp and stamp ~= entry.hash then
				table.insert(plan.models_changed, entry.key)
			end
		elseif entry.folder then
			-- container exists, nothing to sync
		elseif not inst:IsA("LuaSourceContainer") or inst.ClassName ~= entry.class then
			table.insert(plan.skip, `{entry.key} (studio: {inst.ClassName}, disk: {entry.class})`)
		else
			local current = studio_hash(inst)
			local enabled_differs = entry.disabled ~= nil and inst.Enabled == entry.disabled
			if current ~= entry.hash or enabled_differs then
				-- live: studio changed since our last sync -> someone edited it in studio, keep it
				local last = known_hash[entry.key]
				if live and last and current ~= last and current ~= entry.hash then
					table.insert(plan.conflicts, entry)
				else
					table.insert(plan.update, entry)
				end
			else
				known_hash[entry.key] = current
			end
		end
		if i % 150 == 0 then
			task.wait()
		end
	end
	return plan
end

local function apply(plan)
	local todo = {}
	for _, entry in plan.create do
		table.insert(todo, entry)
	end
	for _, entry in plan.update do
		table.insert(todo, entry)
	end
	local sources, err = fetch_sources(todo)
	if not sources then
		set_status("Apply failed", err)
		return false
	end

	local recording = ChangeHistoryService:TryBeginRecording("Xenon sync")
	local done = 0
	for _, entry in todo do
		if entry.model then
			local tree = sources[entry.key]
			if type(tree) == "table" then
				build_model(entry, tree)
			end
			done += 1
			continue
		end

		local inst = ensure(entry.path, entry.class)
		if not entry.folder and inst:IsA("LuaSourceContainer") then
			local source = sources[entry.key]
			if source then
				ScriptEditorService:UpdateSourceAsync(inst, function()
					return source
				end)
				known_hash[entry.key] = entry.hash
			end
			if entry.disabled ~= nil and inst:IsA("BaseScript") then
				inst.Enabled = not entry.disabled
			end
		end
		done += 1
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	print(`[xenon] applied {done} change(s), deleted 0`)
	return true
end

local function show_pending(plan, title)
	pending = plan
	set_status(title, describe(plan))
	refresh_buttons()
	widget.Enabled = true
end

-- connection ----------------------------

local poll_loop

local function full_sync()
	local snapshot, err = request("GET", "/snapshot")
	if not snapshot then
		set_status("Snapshot failed", err)
		return false
	end
	version = snapshot.version
	set_status("Comparing...", `{#snapshot.entries} entries from disk`)
	local plan = plan_for(snapshot.entries, false)
	if #plan.create + #plan.update == 0 then
		pending = nil
		set_status(`Connected, in sync (v{version})`, describe(plan))
		refresh_buttons()
	else
		show_pending(plan, "Review, then Apply")
	end
	return true
end

local function connect()
	local info, err = request("GET", "/info")
	if not info then
		set_status("Cannot reach xenon server", `{BASE_URL}\n{err}\n\nstart it in the game folder:\nlune run <xenon>/src/server.luau`)
		return
	end
	local place_ids = info.placeIds or {}
	if #place_ids > 0 and game.PlaceId ~= 0 and not table.find(place_ids, game.PlaceId) then
		set_status("Wrong place", `project "{info.name}" is locked to {table.concat(place_ids, ", ")}\nthis place: {game.PlaceId}`)
		return
	end

	connected = true
	refresh_buttons()
	if full_sync() then
		task.spawn(poll_loop)
	end
end

local function disconnect()
	connected = false
	pending = nil
	set_status("Disconnected", "")
	refresh_buttons()
end

function poll_loop()
	while connected do
		task.wait(POLL_SECONDS)
		if not connected or pending then
			continue
		end

		local result, err = request("GET", `/changes?since={version}`)
		if not result then
			set_status("Lost server, retrying...", err)
			continue
		end
		if result.resync then
			full_sync()
			continue
		end

		local entries, removed = {}, {}
		for _, change in result.changes or {} do
			if change.kind == "remove" then
				table.insert(removed, change.entry.key)
			else
				table.insert(entries, change.entry)
			end
		end
		version = result.version

		for _, key in removed do
			warn(`[xenon] file removed on disk, kept in studio: {key}`)
		end
		if #entries > 0 then
			local plan = plan_for(entries, true)
			local count = #plan.create + #plan.update
			if #plan.conflicts > 0 or count > LIVE_PROMPT_OVER then
				show_pending(plan, "Review, then Apply")
			elseif count > 0 then
				apply(plan)
				set_status(`Connected (v{version})`, describe(plan))
			end
		end
	end
end


-- MAIN -------------------------

toggle_button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

connect_button.MouseButton1Click:Connect(function()
	if connected then
		disconnect()
	else
		connect()
	end
end)

apply_button.MouseButton1Click:Connect(function()
	local plan = pending
	if not plan then
		return
	end
	pending = nil
	refresh_buttons()
	set_status("Applying...", "")
	if apply(plan) then
		set_status(`Connected (v{version})`, describe(plan))
	end
end)

cancel_button.MouseButton1Click:Connect(function()
	pending = nil
	set_status(connected and `Connected (v{version}), last batch skipped` or "Disconnected", "")
	refresh_buttons()
end)

plugin.Unloading:Connect(disconnect)
refresh_buttons()
