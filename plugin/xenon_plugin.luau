-- xenon studio plugin: files from disk -> studio. only removes scripts whose files were deleted (see plan_removals).
-- talks to `xenon serve` on localhost. built into Plugins/Xenon.rbxm by `xenon build`

-- SERVICES -------------------------

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local CollectionService = game:GetService("CollectionService")


-- MODULES -------------------------

local checksum = require(script.checksum)
local diff = require(script.diff)


-- VARIABLES -------------------------

local SOURCE_BATCH = 80
local SETTINGS_KEY = "xenon_settings"

-- every setting the Settings page shows. order = page order
local SETTING_LIST = {
	{ key = "auto_accept", label = "Auto-accept (never ask)", hint = "Every change goes in without Apply, also on Connect. Conflicts are still left alone", kind = "bool", default = false },
	{ key = "port", label = "Server port", hint = "Must match `xenon serve --port` (default 34872)", kind = "number", default = 34872, min = 1, max = 65535 },
	{ key = "auto_apply", label = "Apply small changes automatically", hint = "Off = every change waits for Apply", kind = "bool", default = true },
	{ key = "auto_apply_limit", label = "Ask first above this many changes", hint = "Bigger batches always wait for Apply", kind = "number", default = 20, min = 1, max = 5000 },
	{ key = "poll_seconds", label = "Check for changes every (seconds)", hint = "Lower = faster updates, a bit more work", kind = "number", default = 0.5, min = 0.1, max = 10 },
	{ key = "sync_deletes", label = "Remove scripts deleted on disk", hint = "Only while connected, only if unchanged in Studio. Ctrl+Z brings it back", kind = "bool", default = true },
	{ key = "sync_models", label = "Sync models", hint = ".rbxm, .model.json and .txt files (created only, never replaced)", kind = "bool", default = true },
	{ key = "log_output", label = "Print changes in Output", hint = "One line per applied batch", kind = "bool", default = true },
	{ key = "icon_decal", label = "Toolbar icon (decal id)", hint = "Any decal id. Takes effect after a Studio restart", kind = "number", default = 57445653, min = 0, max = 1e15 },
}

local COLOR = {
	background = Color3.fromRGB(28, 29, 34),
	card = Color3.fromRGB(38, 40, 47),
	line = Color3.fromRGB(56, 59, 70),
	text = Color3.fromRGB(236, 237, 242),
	dim = Color3.fromRGB(150, 153, 166),
	blue = Color3.fromRGB(64, 132, 245),
	green = Color3.fromRGB(52, 178, 110),
	yellow = Color3.fromRGB(233, 178, 52),
	red = Color3.fromRGB(226, 82, 82),
	grey = Color3.fromRGB(96, 99, 112),
}

local settings = {}
local connected = false
local version = 0
local known_hash = {} -- key -> hash studio had when xenon last synced it (conflict check)
local pending = nil -- plan waiting for Apply
local session = nil -- id of the server run we synced with. changes when `xenon serve` restarts
local project = nil -- { name, folder } of the project we connected to, so a restart into another project is caught
local status_state = "off"
local unloading = false
local server_ok = true -- false while the server does not answer
local loop_id = 0 -- bumps on connect / disconnect so an old poll loop stops
local diff_token = nil -- newest diff request, older answers are dropped

local DIFF_MAX_ROWS = 600

local toolbar = plugin:CreateToolbar("Xenon")
local toggle_button = toolbar:CreateButton("Xenon", "Sync files from disk into Studio", "")
toggle_button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"Xenon",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 360, 380, 320, 300)
)
widget.Title = "Xenon"


-- FUNCTIONS -------------------------

-- settings ------------------------------

local function load_settings()
	local saved = plugin:GetSetting(SETTINGS_KEY) or {}
	for _, item in SETTING_LIST do
		local value = saved[item.key]
		if item.kind == "number" and type(value) == "number" then
			settings[item.key] = math.clamp(value, item.min, item.max)
		elseif item.kind == "bool" and type(value) == "boolean" then
			settings[item.key] = value
		else
			settings[item.key] = item.default
		end
	end
end

local function save_settings()
	plugin:SetSetting(SETTINGS_KEY, settings)
end

local function base_url()
	return `http://localhost:{settings.port}`
end

local function log(message: string)
	if settings.log_output then
		print("[xenon] " .. message)
	end
end

-- ui helpers ---------------------------

local function make(class, props, parent)
	local inst = Instance.new(class)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function corner(parent, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function text(props, parent)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.BuilderSans
	props.TextColor3 = props.TextColor3 or COLOR.text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextWrapped = true
	return make("TextLabel", props, parent)
end

local function button(label, color, parent)
	local b = make("TextButton", {
		Size = UDim2.new(0.5, -4, 0, 36),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = Enum.Font.BuilderSansBold,
		TextSize = 16,
		TextColor3 = Color3.new(1, 1, 1),
		Text = label,
		AutoButtonColor = true,
	}, parent)
	corner(b)
	return b
end

-- layout --------------------------------

local root = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLOR.background, BorderSizePixel = 0 }, widget)
make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12) }, root)

-- header: status dot + name + settings button
local header = make("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, root)
local status_dot = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = COLOR.grey, BorderSizePixel = 0 }, header)
corner(status_dot, 5)
local header_title = text({ Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -210, 1, 0), Font = Enum.Font.BuilderSansBold, TextSize = 15, Text = "Xenon", TextTruncate = Enum.TextTruncate.AtEnd }, header)
-- connection check: green "Live" while the server answers, red "Reconnecting" while it does not
local live_label = text({
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -92, 0, 0),
	Size = UDim2.new(0, 104, 1, 0),
	Font = Enum.Font.BuilderSansBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "",
}, header)
local settings_button = make("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(1, 0),
	Size = UDim2.fromOffset(84, 26),
	BackgroundColor3 = COLOR.card,
	BorderSizePixel = 0,
	Font = Enum.Font.BuilderSansMedium,
	TextSize = 14,
	TextColor3 = COLOR.dim,
	Text = "Settings",
}, header)
corner(settings_button)

-- main page
local main_page = make("Frame", { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 1, -36), BackgroundTransparency = 1 }, root)
local summary = text({ Size = UDim2.new(1, -84, 0, 30), Font = Enum.Font.BuilderSansBold, TextSize = 24, Text = "Not connected", TextTruncate = Enum.TextTruncate.AtEnd }, main_page)
-- one-click auto-accept switch (same as the setting)
local auto_button = make("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 2),
	Size = UDim2.fromOffset(78, 26),
	BorderSizePixel = 0,
	Font = Enum.Font.BuilderSansBold,
	TextSize = 13,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "Auto",
}, main_page)
corner(auto_button, 13)
local hint = text({ Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 38), TextSize = 14, TextColor3 = COLOR.dim, TextYAlignment = Enum.TextYAlignment.Top, Text = "" }, main_page)

local chips = make("Frame", { Position = UDim2.fromOffset(0, 74), Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1 }, main_page)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, chips)
local function chip(color)
	local c = make("TextLabel", {
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
		Font = Enum.Font.BuilderSansBold,
		TextSize = 13,
		TextColor3 = color,
		Text = "",
		Visible = false,
	}, chips)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, c)
	corner(c, 12)
	return c
end
local chip_update = chip(COLOR.blue)
local chip_new = chip(COLOR.green)
local chip_conflict = chip(COLOR.red)
local chip_kept = chip(COLOR.yellow)
local chip_remove = chip(COLOR.red)

local list = make("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 106),
	Size = UDim2.new(1, 0, 1, -152),
	BackgroundColor3 = COLOR.card,
	BorderSizePixel = 0,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = COLOR.line,
}, main_page)
corner(list)
make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)
make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, list)

local buttons = make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1 }, main_page)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, buttons)
local primary_button = button("Connect", COLOR.blue, buttons)
local secondary_button = button("Cancel", COLOR.grey, buttons)

-- settings page
local settings_page = make("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 4,
	Visible = false,
}, root)
make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, settings_page)

-- diff page: one script, studio (red) -> disk (green)
local diff_page = make("Frame", { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 1, -36), BackgroundTransparency = 1, Visible = false }, root)
local diff_title = text({ Size = UDim2.new(1, 0, 0, 20), Font = Enum.Font.BuilderSansBold, TextSize = 15, Text = "", TextTruncate = Enum.TextTruncate.AtEnd }, diff_page)
local diff_sub = text({ Position = UDim2.fromOffset(0, 21), Size = UDim2.new(1, 0, 0, 18), TextSize = 13, TextColor3 = COLOR.dim, Text = "" }, diff_page)
local diff_list = make("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 46),
	Size = UDim2.new(1, 0, 1, -46),
	BackgroundColor3 = COLOR.card,
	BorderSizePixel = 0,
	AutomaticCanvasSize = Enum.AutomaticSize.XY,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = COLOR.line,
}, diff_page)
corner(diff_list)
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, diff_list)
make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingRight = UDim.new(0, 8) }, diff_list)

-- status ---------------------------------

local function set_status(state: string, title: string, sentence: string)
	local colors = { off = COLOR.grey, ok = COLOR.green, busy = COLOR.blue, review = COLOR.yellow, error = COLOR.red }
	status_dot.BackgroundColor3 = colors[state] or COLOR.grey
	status_state = state
	header_title.Text = (connected and project) and `{project.name}  ·  localhost:{settings.port}` or "Xenon"
	summary.Text = title
	hint.Text = sentence
end

local function set_live(state: string)
	if state == "live" then
		live_label.Text = "● Live"
		live_label.TextColor3 = COLOR.green
	elseif state == "lost" then
		live_label.Text = "● Reconnecting…"
		live_label.TextColor3 = COLOR.red
	else
		live_label.Text = ""
	end
end

-- pages: "main", "settings", "diff"
local function show_page(name: string)
	main_page.Visible = name == "main"
	settings_page.Visible = name == "settings"
	diff_page.Visible = name == "diff"
	settings_button.Text = name == "main" and "Settings" or "Back"
end

local function short_path(key: string): string
	local parts = string.split(key, "/")
	if #parts <= 3 then
		return key
	end
	return parts[1] .. " / … / " .. parts[#parts - 1] .. " / " .. parts[#parts]
end

local function clear_list()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local open_diff -- defined below, needs the server + studio helpers

-- entry given (a script) -> the row is clickable and opens its diff
local function add_row(tag: string, color: Color3, key: string, order: number, entry)
	local clickable = entry ~= nil and not entry.folder and not entry.model and not entry.reason
	local row = make(clickable and "TextButton" or "Frame", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundColor3 = COLOR.line,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, list)
	text({ Position = UDim2.fromOffset(4, 0), Size = UDim2.fromOffset(62, 20), Font = Enum.Font.BuilderSansBold, TextSize = 12, TextColor3 = color, Text = tag }, row)
	local label = text({ Position = UDim2.fromOffset(68, 0), Size = UDim2.new(1, clickable and -88 or -68, 1, 0), TextSize = 13, Text = short_path(key) .. (entry and entry.reason and `   · {entry.reason}` or ""), TextTruncate = Enum.TextTruncate.AtEnd }, row)
	label.TextWrapped = false
	if not clickable then
		return
	end
	corner(row, 4)
	row.Text = ""
	row.AutoButtonColor = false
	text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(18, 20), TextSize = 16, TextColor3 = COLOR.dim, TextXAlignment = Enum.TextXAlignment.Center, Text = "›" }, row)
	row.MouseEnter:Connect(function()
		row.BackgroundTransparency = 0.4
	end)
	row.MouseLeave:Connect(function()
		row.BackgroundTransparency = 1
	end)
	row.MouseButton1Click:Connect(function()
		open_diff(entry, tag, color)
	end)
end

local function set_chip(c, count, word)
	c.Visible = count > 0
	c.Text = `{count} {word}`
end

-- plan = { create, update, conflicts, skip, models_changed }
local function show_plan(plan)
	clear_list()
	set_chip(chip_update, #plan.update, plan.pull and "to disk" or "update")
	set_chip(chip_new, #plan.create, plan.pull and "new file" or "new")
	set_chip(chip_conflict, #plan.conflicts, #plan.conflicts == 1 and "conflict" or "conflicts")
	set_chip(chip_kept, #plan.skip + #plan.models_changed, "kept as is")
	set_chip(chip_remove, #plan.remove, "delete")

	local order, shown, limit = 0, 0, 150
	local function rows(items, tag, color)
		for _, item in items do
			if shown >= limit then
				return
			end
			order += 1
			shown += 1
			local entry = type(item) == "table" and item or nil
			add_row(tag, color, entry and entry.key or item, order, entry)
		end
	end
	rows(plan.conflicts, "CONFLICT", COLOR.red)
	rows(plan.remove, "DELETE", COLOR.red)
	rows(plan.update, plan.pull and "TO DISK" or "UPDATE", COLOR.blue)
	rows(plan.create, plan.pull and "NEW FILE" or "NEW", COLOR.green)
	rows(plan.models_changed, "KEPT", COLOR.yellow)
	rows(plan.skip, "SKIPPED", COLOR.dim)
	local total = #plan.conflicts + #plan.remove + #plan.update + #plan.create + #plan.models_changed + #plan.skip
	if total > shown then
		order += 1
		add_row("", COLOR.dim, `… and {total - shown} more`, order)
	end
end

local function refresh_buttons()
	if pending then
		primary_button.Text = pending.pull and "Write to disk" or "Apply"
		primary_button.BackgroundColor3 = COLOR.green
		secondary_button.Text = "Cancel"
		secondary_button.BackgroundColor3 = COLOR.grey
		secondary_button.Visible = true
	elseif connected then
		primary_button.Text = "Disconnect"
		primary_button.BackgroundColor3 = COLOR.grey
		secondary_button.Text = "Pull from Studio"
		secondary_button.BackgroundColor3 = COLOR.blue
		secondary_button.Visible = true
	else
		primary_button.Text = "Connect"
		primary_button.BackgroundColor3 = COLOR.blue
		secondary_button.Visible = false
	end
	primary_button.Size = secondary_button.Visible and UDim2.new(0.5, -4, 0, 36) or UDim2.new(1, 0, 0, 36)
end

-- server ----------------------------------

local function request(method, path, body)
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = base_url() .. path,
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

-- scripts come back as source strings, models as instance trees
local function fetch_sources(entries)
	local keys = {}
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
		for key, value in result do
			sources[key] = value
		end
	end
	for _, entry in entries do
		if entry.source or entry.tree then
			sources[entry.key] = entry.source or entry.tree
		end
	end
	return sources
end

-- studio tree -----------------------------

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

-- diff review -------------------------------

local DIFF_STYLE = {
	add = { sign = "+", color = COLOR.green },
	del = { sign = "-", color = COLOR.red },
	same = { sign = " " },
}

local function diff_row(order: number, number_text: string, code: string, style)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 17),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = style.color or COLOR.card,
		BackgroundTransparency = style.color and 0.82 or 1,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, diff_list)
	text({ Size = UDim2.new(0, 40, 1, 0), Font = Enum.Font.Code, TextSize = 12, TextColor3 = COLOR.dim, TextXAlignment = Enum.TextXAlignment.Right, Text = number_text }, row)
	local label = text({
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = style.color or COLOR.text,
		Text = code,
	}, row)
	label.TextWrapped = false
end

function open_diff(entry, tag: string, color: Color3)
	for _, child in diff_list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	diff_title.Text = entry.key
	diff_title.TextColor3 = color
	diff_sub.Text = "Loading the file from disk…"
	diff_list.CanvasPosition = Vector2.zero
	show_page("diff")

	local token = {}
	diff_token = token
	local result, err
	if tag == "DELETE" or (entry.pull and not entry.exists) then
		result = { [entry.key] = "" } -- no file on disk
	else
		result, err = request("POST", "/sources", { keys = { entry.key } })
	end
	if diff_token ~= token then
		return -- another diff was opened meanwhile
	end
	local disk = result and result[entry.key]
	if type(disk) ~= "string" then
		diff_sub.Text = `Could not load it from the server. {err or "file is gone"}`
		return
	end

	local inst = find(entry.path)
	local studio = inst and inst:IsA("LuaSourceContainer") and inst.Source or ""
	local edits = if entry.pull then diff.lines(disk, studio) else diff.lines(studio, disk)
	local added, removed = diff.count(edits)

	if entry.pull then
		diff_sub.Text = entry.exists and `{tag}  ·  +{added}  -{removed}  ·  red = file now, green = Studio`
			or `{tag}  ·  new file, {added} lines from Studio`
	elseif tag == "DELETE" then
		diff_sub.Text = `DELETE  ·  file removed on disk, Apply removes these {removed} lines from Studio`
	elseif added + removed == 0 then
		diff_sub.Text = `{tag}  ·  same code, only Enabled / RunContext change (disabled: {entry.disabled}, RunContext: {entry.run_context or "-"})`
	elseif inst then
		diff_sub.Text = `{tag}  ·  +{added}  -{removed}  ·  red = Studio now, green = disk`
	else
		diff_sub.Text = `{tag}  ·  new script, {added} lines`
	end

	local order = 0
	for _, edit in diff.fold(edits, 3) do
		order += 1
		if order > DIFF_MAX_ROWS then
			diff_row(order, "", `… {DIFF_MAX_ROWS}+ rows, open the file in your editor for the rest`, { color = nil })
			break
		end
		if edit.kind == "fold" then
			diff_row(order, "", `⋯  {edit.count} unchanged line{edit.count == 1 and "" or "s"}`, { color = nil })
		else
			local style = DIFF_STYLE[edit.kind]
			local code = edit.text:gsub("\t", "    ")
			diff_row(order, tostring(edit.new or edit.old), `{style.sign} {code}`, style)
		end
		if order % 100 == 0 then
			task.wait()
			if diff_token ~= token then
				return
			end
		end
	end
end

-- models (.rbxm / .model.json / .txt) ------

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
	local root_inst = build_node(tree, by_id, refs)
	for _, ref in refs do
		local target = by_id[ref.id]
		if target then
			pcall(function()
				ref.inst[ref.name] = target
			end)
		end
	end
	root_inst.Name = entry.path[#entry.path]
	root_inst:SetAttribute("xenon_hash", entry.hash)

	local parent_path = table.move(entry.path, 1, #entry.path - 1, 1, {})
	root_inst.Parent = #parent_path == 1 and service(parent_path[1]) or ensure(parent_path, "Folder")
end

-- plan / apply ------------------------------

local function plan_for(entries, live)
	local plan = { create = {}, update = {}, conflicts = {}, skip = {}, models_changed = {}, remove = {} }
	for i, entry in entries do
		if entry.model and not settings.sync_models then
			continue
		end
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
			table.insert(plan.skip, entry.key)
		else
			local current = checksum(inst.Source)
			local enabled_differs = entry.disabled ~= nil and inst.Enabled == entry.disabled
			local context_differs = entry.run_context ~= nil and inst:IsA("Script") and inst.RunContext.Name ~= entry.run_context
			if current ~= entry.hash or enabled_differs or context_differs then
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

-- files deleted on disk during a live session. only scripts, only if studio still has exactly
-- what disk had (not edited in studio), never folders / models / anything else
local function plan_removals(plan, removed)
	if not settings.sync_deletes then
		return
	end
	for _, entry in removed do
		-- wally owns _Index: `wally install` wipes and refills it, old versions there are harmless
		if entry.folder or entry.model or entry.key:find("/_Index/", 1, true) then
			continue
		end
		local inst = find(entry.path)
		if not inst or not inst:IsA("LuaSourceContainer") or inst.ClassName ~= entry.class then
			continue
		end
		if checksum(inst.Source) == entry.hash then
			table.insert(plan.remove, entry)
		else
			table.insert(plan.conflicts, entry) -- edited in studio, keep it
		end
	end
end

local function remove_scripts(entries): number
	-- deepest first, so an init script whose children were removed too can go after them
	local sorted = table.clone(entries)
	table.sort(sorted, function(a, b)
		return #a.path > #b.path
	end)
	local removed = 0
	for _, entry in sorted do
		local inst = find(entry.path)
		-- check again right before: unchanged script without children
		if inst and inst:IsA("LuaSourceContainer") and inst.ClassName == entry.class
			and checksum(inst.Source) == entry.hash and #inst:GetChildren() == 0 then
			inst.Parent = nil -- inside the recording, so Ctrl+Z puts it back
			known_hash[entry.key] = nil
			removed += 1
		else
			warn(`[xenon] kept {entry.key} (changed in Studio or has children)`)
		end
	end
	return removed
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
		set_status("error", "Apply failed", `Could not get files from the server.\n{err}`)
		return false
	end

	-- last check before deleting: the server must still have no file for it (it may be back by now)
	local to_remove = {}
	if #plan.remove > 0 then
		local keys = {}
		for _, entry in plan.remove do
			table.insert(keys, entry.key)
		end
		local back, back_err = request("POST", "/sources", { keys = keys })
		if not back then
			set_status("error", "Apply failed", `Could not check deleted files with the server.\n{back_err}`)
			return false
		end
		for _, entry in plan.remove do
			if back[entry.key] == nil then
				table.insert(to_remove, entry)
			else
				log(`kept {entry.key}: the file is back on disk`)
			end
		end
	end

	local recording = ChangeHistoryService:TryBeginRecording("Xenon sync")
	local removed = remove_scripts(to_remove)
	for _, entry in todo do
		if entry.model then
			local tree = sources[entry.key]
			if type(tree) == "table" then
				build_model(entry, tree)
			end
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
			if entry.run_context and inst:IsA("Script") then
				pcall(function()
					inst.RunContext = (Enum.RunContext :: any)[entry.run_context]
				end)
			end
			if entry.disabled ~= nil and inst:IsA("BaseScript") then
				inst.Enabled = not entry.disabled
			end
		end
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	log(`applied {#plan.update} update(s), {#plan.create} new, {removed} deleted`)
	return true
end

local function show_in_sync(plan)
	pending = nil
	local kept = #plan.conflicts
	set_status(
		"ok",
		"In sync",
		kept > 0 and `{kept} script(s) edited in Studio and on disk were left alone (red). Everything else is in.`
			or "Studio matches the files on disk. Edits you save will show up here automatically."
	)
	show_plan(plan)
	refresh_buttons()
end

local function show_review(plan)
	pending = plan
	local count = #plan.create + #plan.update + #plan.remove
	local deletes = #plan.remove > 0 and ` {#plan.remove} script(s) deleted on disk will be removed.` or " Nothing is deleted."
	set_status(
		"review",
		count == 1 and "1 change ready" or `{count} changes ready`,
		#plan.conflicts > 0 and `Some scripts were edited in Studio and on disk. Those are left alone. Apply brings in the rest.{deletes}`
			or `Click a script to see what changes. Apply brings them into Studio.{deletes} Ctrl+Z undoes it.`
	)
	show_plan(plan)
	refresh_buttons()
	widget.Enabled = true
end

-- pull: studio -> disk ----------------------

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local function path_of(inst: Instance): { string }
	local path = {}
	local node = inst
	while node and node ~= game do
		table.insert(path, 1, node.Name)
		node = node.Parent
	end
	return path
end

local function show_pull_review(plan, studio_only: number)
	local count = #plan.create + #plan.update
	local skipped = studio_only > 0 and ` {studio_only} Studio-only script(s) skipped (their folder isn't on disk).` or ""
	if count == 0 then
		pending = nil
		set_status("ok", "Nothing to pull", `Your files already match Studio.{skipped}`)
	else
		pending = plan
		set_status(
			"review",
			count == 1 and "1 script to write to disk" or `{count} scripts to write to disk`,
			`Studio → your files. Click one to see the diff. No file is deleted.{skipped}`
		)
	end
	show_plan(plan)
	refresh_buttons()
end

-- the server gets plain data: drop the Instance the plugin keeps on each item
local function strip_instances(items)
	local out = {}
	for _, item in items do
		local copy = table.clone(item)
		copy.instance = nil
		table.insert(out, copy)
	end
	return out
end

-- compares studio scripts under the mapped roots with the files, asks the server (dry run) what it may write
local function start_pull()
	set_status("busy", "Reading Studio…", "Looking for scripts that differ from your files.")
	local snapshot, err = request("GET", "/snapshot")
	if not snapshot then
		set_status("error", "Lost the server", tostring(err))
		return
	end
	local by_key = {}
	for _, entry in snapshot.entries do
		by_key[entry.key] = entry
	end
	local roots = {}
	for _, root_path in snapshot.roots or {} do
		roots[table.concat(root_path, "/")] = true
	end

	local plan = { create = {}, update = {}, conflicts = {}, skip = {}, models_changed = {}, remove = {}, pull = true }
	local candidates, seen, new_keys = {}, {}, {}
	local scanned = 0
	for _, root_path in snapshot.roots or {} do
		local root_inst = find(root_path)
		for _, inst in root_inst and root_inst:GetDescendants() or {} do
			scanned += 1
			if scanned % 500 == 0 then
				task.wait()
			end
			if not SCRIPT_CLASSES[inst.ClassName] then
				continue
			end
			local path = path_of(inst)
			local key = table.concat(path, "/")
			if seen[key] then
				continue -- nested roots see it twice, or two siblings share a name
			end
			seen[key] = true

			local entry = by_key[key]
			local current = checksum(inst.Source)
			local item = { key = key, path = path, class = inst.ClassName, pull = true, exists = entry ~= nil, instance = inst }
			if inst:IsA("BaseScript") then
				item.disabled = not inst.Enabled
			end
			if entry then
				if entry.folder or entry.model or entry.data or current == entry.hash then
					continue
				end
				local last = known_hash[key]
				if last and current == last then
					continue -- studio untouched since our last sync: the file is newer, push brings it in
				elseif last and entry.hash ~= last then
					table.insert(plan.conflicts, item) -- edited in studio and on disk
					continue
				end
			else
				new_keys[key] = true
			end
			table.insert(candidates, item)
		end
	end

	-- new scripts only where their parent is on disk (or is a new script that will be)
	local studio_only = 0
	local filtered = {}
	for _, item in candidates do
		if item.exists then
			table.insert(filtered, item)
			continue
		end
		local parent_key = table.concat(item.path, "/", 1, #item.path - 1)
		local parent = by_key[parent_key]
		if not (roots[parent_key] or new_keys[parent_key] or parent) then
			-- parents missing on disk: fine when they are all plain Folders up to something on disk
			local node = item.instance.Parent
			local ok = false
			while node and node ~= game and node:IsA("Folder") and node.Name ~= "_Index" do
				node = node.Parent
				local key = table.concat(path_of(node), "/")
				if roots[key] or (by_key[key] and by_key[key].folder) then
					ok = true
					break
				end
			end
			if ok then
				item.folder_parents = true
				parent = { folder = true }
			end
		end
		if roots[parent_key] or new_keys[parent_key] or (parent and not parent.model) then
			for other in new_keys do
				if other:sub(1, #item.key + 1) == item.key .. "/" then
					item.has_children = true
					break
				end
			end
			table.insert(filtered, item)
		else
			studio_only += 1
		end
	end

	local verdict, verdict_err = request("POST", "/pull", { dry = true, items = strip_instances(filtered) })
	if not verdict then
		set_status("error", "Pull failed", tostring(verdict_err))
		return
	end
	for _, item in filtered do
		local reason = verdict.refused and verdict.refused[item.key]
		if reason then
			if reason:find("Studio-only") then
				studio_only += 1
			else
				item.reason = reason
				table.insert(plan.skip, item)
			end
		elseif verdict.written and verdict.written[item.key] then
			table.insert(item.exists and plan.update or plan.create, item)
		end
	end
	show_pull_review(plan, studio_only)
end

local function apply_pull(plan)
	local todo = {}
	for _, group in { plan.update, plan.create } do
		for _, item in group do
			local inst = find(item.path)
			if inst and inst:IsA("LuaSourceContainer") then
				item.source = inst.Source -- read now, not at review time
				table.insert(todo, item)
			end
		end
	end
	table.sort(todo, function(a, b)
		return #a.path < #b.path
	end)

	local written, refused = 0, 0
	for i = 1, #todo, SOURCE_BATCH do
		local chunk = table.move(todo, i, math.min(i + SOURCE_BATCH - 1, #todo), 1, {})
		local result, err = request("POST", "/pull", { dry = false, items = strip_instances(chunk) })
		if not result then
			set_status("error", "Pull failed", `Wrote {written} file(s) before the server stopped answering.\n{err}`)
			return false
		end
		for _, item in chunk do
			if result.written and result.written[item.key] then
				written += 1
				known_hash[item.key] = checksum(item.source)
			else
				refused += 1
				warn(`[xenon] not written {item.key}: {result.refused and result.refused[item.key] or "?"}`)
			end
		end
	end
	log(`pulled {written} script(s) to disk, {refused} refused, deleted 0`)
	pending = nil
	set_status(
		"ok",
		`Wrote {written} file{written == 1 and "" or "s"}`,
		refused > 0 and `{refused} could not be written, see Output.` or "Your files now match Studio. Check them with git diff."
	)
	show_plan(plan)
	refresh_buttons()
	return true
end

-- auto-accept on: apply now. off: review when asked to. conflicts are never applied either way
local function apply_or_review(plan, needs_review: boolean)
	local count = #plan.create + #plan.update + #plan.remove
	if needs_review and not settings.auto_accept and count > 0 then
		show_review(plan)
	elseif count == 0 or apply(plan) then
		show_in_sync(plan)
	end
end

local function paint_auto()
	auto_button.Text = settings.auto_accept and "Auto  ON" or "Auto  OFF"
	auto_button.BackgroundColor3 = settings.auto_accept and COLOR.green or COLOR.grey
end

local function set_auto(on: boolean)
	settings.auto_accept = on
	save_settings()
	paint_auto()
	-- turning it on while a sync review waits: apply it now (pull reviews still wait, they write files)
	if on and pending and not pending.pull then
		local plan = pending
		pending = nil
		refresh_buttons()
		set_status("busy", "Applying…", "")
		apply_or_review(plan, false)
	end
end

-- connection ----------------------------------

local poll_loop

local function full_sync()
	local snapshot, err = request("GET", "/snapshot")
	if not snapshot then
		server_ok = false
		set_live("lost")
		set_status("error", "Lost the server", `Retrying… is \`xenon serve\` still running?\n{err}`)
		return false
	end
	version = snapshot.version
	session = snapshot.session
	server_ok = true
	set_live("live")
	set_status("busy", "Comparing…", `Checking {#snapshot.entries} files against Studio.`)
	local plan = plan_for(snapshot.entries, false)
	apply_or_review(plan, true) -- connect / resync always asks, unless auto-accept
	return true
end

local function connect()
	set_status("busy", "Connecting…", base_url())
	local info, err = request("GET", "/info")
	if not info then
		set_status("error", "Server not running", `Start it in your game folder:  xenon serve\n(port {settings.port}, change it in Settings)`)
		warn("[xenon] " .. tostring(err))
		return
	end
	local place_ids = info.placeIds or {}
	if #place_ids > 0 and game.PlaceId ~= 0 and not table.find(place_ids, game.PlaceId) then
		set_status("error", "Wrong place", `"{info.name}" only syncs into place {table.concat(place_ids, ", ")}. This is {game.PlaceId}.`)
		return
	end

	connected = true
	server_ok = true
	session = info.session
	project = { name = info.name, folder = info.folder }
	log(`connected to "{info.name}"{info.folder and " (" .. info.folder .. ")" or ""}`)
	loop_id += 1
	refresh_buttons()
	full_sync()
	task.spawn(poll_loop, loop_id) -- runs even if the first sync failed: it reconnects by itself
end

local function disconnect()
	connected = false
	pending = nil
	session = nil
	project = nil
	loop_id += 1
	set_live("off")
	show_page("main")
	clear_list()
	for _, c in { chip_update, chip_new, chip_conflict, chip_kept, chip_remove } do
		c.Visible = false
	end
	set_status("off", "Not connected", "Run `xenon serve` in your game folder, then press Connect.")
	refresh_buttons()
end

-- one request per tick. while a review waits it only pings /info, so the connection check
-- and server-restart detection never pause
function poll_loop(my_id: number)
	while connected and loop_id == my_id do
		task.wait(settings.poll_seconds)
		if not connected or loop_id ~= my_id then
			break
		end

		local result, err = request("GET", pending and "/info" or `/changes?since={version}`)
		if not connected or loop_id ~= my_id then
			break
		end
		if not result then
			if server_ok then
				server_ok = false
				set_live("lost")
				set_status("error", "Lost the server", `Retrying… is \`xenon serve\` still running?\n{err}`)
			end
			continue
		end

		-- back after a drop, a new `xenon serve` run, or too far behind: compare everything again
		local restarted = result.session ~= nil and result.session ~= session
		if restarted then
			local info = request("GET", "/info")
			if not connected or loop_id ~= my_id then
				break
			end
			if info and project and (info.name ~= project.name or (info.folder and project.folder and info.folder ~= project.folder)) then
				local was = project.name
				disconnect()
				set_status("error", "Different project", `The server now runs "{info.name}", not "{was}". Press Connect if you want to sync "{info.name}" into this place.`)
				continue
			end
		end
		if not server_ok or restarted or result.resync then
			if restarted then
				log("server restarted, comparing everything again")
			end
			full_sync()
			continue
		end
		if pending then
			continue
		end

		-- last change per key wins (delete + re-create = update)
		local last = {}
		local order = {}
		for _, change in result.changes or {} do
			if not last[change.entry.key] then
				table.insert(order, change.entry.key)
			end
			last[change.entry.key] = change
		end
		local entries, removed = {}, {}
		for _, key in order do
			local change = last[key]
			table.insert(change.kind == "remove" and removed or entries, change.entry)
		end
		version = result.version

		if #entries + #removed > 0 then
			local plan = plan_for(entries, true)
			plan_removals(plan, removed)
			local count = #plan.create + #plan.update + #plan.remove
			local needs_review = #plan.conflicts > 0 or not settings.auto_apply or count > settings.auto_apply_limit
			if count > 0 or #plan.conflicts > 0 then
				apply_or_review(plan, needs_review)
			end
		end
	end
end

-- settings page --------------------------------

local function build_settings_page()
	for _, child in settings_page:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	for order, item in SETTING_LIST do
		local row = make("Frame", { Size = UDim2.new(1, -6, 0, 52), BackgroundColor3 = COLOR.card, BorderSizePixel = 0, LayoutOrder = order }, settings_page)
		corner(row)
		make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, row)
		text({ Position = UDim2.fromOffset(0, 7), Size = UDim2.new(1, -96, 0, 20), Font = Enum.Font.BuilderSansBold, TextSize = 14, Text = item.label }, row)
		text({ Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -96, 0, 18), TextSize = 12, TextColor3 = COLOR.dim, Text = item.hint, TextTruncate = Enum.TextTruncate.AtEnd }, row)

		if item.kind == "bool" then
			local toggle = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(72, 28),
				BorderSizePixel = 0,
				Font = Enum.Font.BuilderSansBold,
				TextSize = 14,
				TextColor3 = Color3.new(1, 1, 1),
			}, row)
			corner(toggle, 14)
			local function paint()
				toggle.Text = settings[item.key] and "On" or "Off"
				toggle.BackgroundColor3 = settings[item.key] and COLOR.green or COLOR.grey
			end
			paint()
			toggle.MouseButton1Click:Connect(function()
				if item.key == "auto_accept" then
					set_auto(not settings.auto_accept)
				else
					settings[item.key] = not settings[item.key]
					save_settings()
				end
				paint()
			end)
		else
			local box = make("TextBox", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(84, 28),
				BackgroundColor3 = COLOR.background,
				BorderSizePixel = 0,
				Font = Enum.Font.Code,
				TextSize = 14,
				TextColor3 = COLOR.text,
				Text = tostring(settings[item.key]),
				ClearTextOnFocus = false,
			}, row)
			corner(box)
			box.FocusLost:Connect(function()
				local value = tonumber(box.Text)
				if value then
					settings[item.key] = math.clamp(value, item.min, item.max)
					save_settings()
				end
				box.Text = tostring(settings[item.key])
			end)
		end
	end

	local reset = button("Reset to defaults", COLOR.grey, settings_page)
	reset.Size = UDim2.new(1, -6, 0, 34)
	reset.LayoutOrder = #SETTING_LIST + 1
	reset.MouseButton1Click:Connect(function()
		for _, item in SETTING_LIST do
			settings[item.key] = item.default
		end
		save_settings()
		build_settings_page()
	end)
end

local function show_settings(open: boolean)
	show_page(open and "settings" or "main")
	if open then
		build_settings_page()
	end
end

-- toolbar icon: decal id -> its image id (toolbar icons need image ids)
local function load_icon()
	if settings.icon_decal <= 0 then
		return
	end
	local ok, objects = pcall(function()
		return game:GetObjects(`rbxassetid://{settings.icon_decal}`)
	end)
	local decal = ok and objects and objects[1]
	if decal and decal:IsA("Decal") and decal.Texture ~= "" then
		toggle_button.Icon = decal.Texture
	else
		warn(`[xenon] could not load icon decal {settings.icon_decal}`)
	end
end


-- MAIN -------------------------

load_settings()
task.spawn(load_icon)
paint_auto()
auto_button.MouseButton1Click:Connect(function()
	set_auto(not settings.auto_accept)
end)

toggle_button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

settings_button.MouseButton1Click:Connect(function()
	diff_token = nil -- stops a diff that is still drawing
	show_settings(main_page.Visible)
end)

primary_button.MouseButton1Click:Connect(function()
	if pending and pending.pull then
		local plan = pending
		pending = nil
		refresh_buttons()
		set_status("busy", "Writing files…", "")
		apply_pull(plan)
	elseif pending then
		local plan = pending
		pending = nil
		refresh_buttons()
		set_status("busy", "Applying…", "")
		if apply(plan) then
			show_in_sync(plan)
		end
	elseif connected then
		disconnect()
	else
		connect()
	end
end)

secondary_button.MouseButton1Click:Connect(function()
	if not pending then
		if connected then
			start_pull()
		end
		return
	end
	pending = nil
	set_status("ok", "Skipped", "Those changes were not applied. New edits will still come in.")
	clear_list()
	refresh_buttons()
end)

plugin.Unloading:Connect(function()
	connected = false
	unloading = true
end)

disconnect()

-- while not connected, ask the port which project is there so Connect never surprises you
task.spawn(function()
	while not unloading do
		if not connected and widget.Enabled and status_state == "off" then
			local info = request("GET", "/info")
			if not connected and status_state == "off" then
				if info and info.name then
					summary.Text = `Ready: "{info.name}"`
					hint.Text = `{info.folder or "xenon serve"} on port {settings.port}. Press Connect to sync it into this place.`
				else
					summary.Text = "Not connected"
					hint.Text = "Run `xenon serve` in your game folder, then press Connect."
				end
			end
		end
		task.wait(3)
	end
end)
