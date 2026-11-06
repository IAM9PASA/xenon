-- turns roblox instances (from .rbxm / .rbxmx / .model.json / .txt) into plain json trees the plugin can rebuild.
-- only properties that differ from the class default are sent. refs (welds, PrimaryPart...) become ids inside the tree.
-- value encoding: { "Type", ...numbers/strings } , decoded by the plugin

-- SERVICES -------------------------

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")


-- VARIABLES -------------------------

local db = roblox.getReflectionDatabase()

-- never sent: identity / tree fields, or things the plugin cannot set
local SKIP = {
	Parent = true,
	Name = true,
	ClassName = true,
	Archivable = true,
	UniqueId = true,
	HistoryId = true,
	Capabilities = true,
	Sandboxed = true,
	SourceAssetId = true,
	Tags = true,
	Attributes = true,
	AttributesSerialize = true,
}

local property_cache = {} -- class -> { names }
local default_cache = {} -- class -> default instance or false

local model = {}


-- FUNCTIONS -------------------------

local function properties_of(class_name: string): { string }
	local cached = property_cache[class_name]
	if cached then
		return cached
	end

	local names = {}
	local class = db:GetClass(class_name)
	while class do
		for name, prop in class.Properties do
			local scriptable = prop.Scriptability == "ReadWrite" or prop.Scriptability == "Custom"
			-- asset fields (MeshContent, ColorMapContent...) are often "not scriptable" but the plugin
			-- has its own way to apply them (CreateMeshPartAsync, plugin-level writes)
			local asset_field = prop.Datatype == "Content" or prop.Datatype == "ContentId"
			if (scriptable or asset_field) and not SKIP[name] then
				table.insert(names, name)
			end
		end
		class = class.Superclass and db:GetClass(class.Superclass) or nil
	end
	table.sort(names)
	property_cache[class_name] = names
	return names
end

local function default_of(class_name: string)
	local cached = default_cache[class_name]
	if cached == nil then
		local ok, inst = pcall(roblox.Instance.new, class_name)
		cached = ok and inst or false
		default_cache[class_name] = cached
	end
	return cached or nil
end

local function read(inst, name)
	local ok, value = pcall(function()
		return inst[name]
	end)
	if ok then
		return value
	end
	return nil
end

-- "Content(Uri=rbxassetid://1)" -> "rbxassetid://1", "Content(None)" -> nil
local function content_uri(value): string?
	local ok, uri = pcall(function()
		return value.Uri
	end)
	if ok and type(uri) == "string" and uri ~= "" then
		return uri
	end
	return tostring(value):match("Uri=([^%)]+)")
end

local function encode(value)
	local kind = typeof(value)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return { kind, value }
	elseif kind == "Vector3" then
		return { kind, value.X, value.Y, value.Z }
	elseif kind == "Vector2" then
		return { kind, value.X, value.Y }
	elseif kind == "Color3" then
		return { kind, value.R, value.G, value.B }
	elseif kind == "UDim" then
		return { kind, value.Scale, value.Offset }
	elseif kind == "UDim2" then
		return { kind, value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
	elseif kind == "CFrame" then
		return { kind, value:GetComponents() }
	elseif kind == "NumberRange" then
		return { kind, value.Min, value.Max }
	elseif kind == "Rect" then
		return { kind, value.Min.X, value.Min.Y, value.Max.X, value.Max.Y }
	elseif kind == "BrickColor" then
		return { kind, value.Number }
	elseif kind == "EnumItem" then
		local enum_name, item = tostring(value):match("^Enum%.([^%.]+)%.(.+)$")
		return enum_name and { kind, enum_name, item } or nil
	elseif kind == "NumberSequence" then
		local points = {}
		for _, p in value.Keypoints do
			table.insert(points, { p.Time, p.Value, p.Envelope })
		end
		return { kind, points }
	elseif kind == "ColorSequence" then
		local points = {}
		for _, p in value.Keypoints do
			table.insert(points, { p.Time, p.Value.R, p.Value.G, p.Value.B })
		end
		return { kind, points }
	elseif kind == "Font" then
		local weight = tostring(value.Weight):match("([^%.]+)$")
		local style = tostring(value.Style):match("([^%.]+)$")
		return { kind, value.Family, weight, style }
	elseif kind == "Content" then
		local uri = content_uri(value)
		return uri and { kind, uri } or nil
	end
	return nil
end

-- same value as the class default -> not worth sending
local function equals_default(default, name, value)
	if not default then
		return false
	end
	local base = read(default, name)
	if base == nil then
		return false
	end
	local ok, same = pcall(function()
		return base == value
	end)
	return ok and same
end

-- seen = { { inst, id } } in visit order; ids are handed out here because lune wrappers are not stable table keys
local function serialize_node(inst, seen, refs)
	local id = #seen + 1
	table.insert(seen, { inst, id })
	local node = {
		id = id,
		class = inst.ClassName,
		name = inst.Name,
		props = {},
		attrs = {},
		tags = {},
		children = {},
	}

	local default = default_of(inst.ClassName)
	for _, name in properties_of(inst.ClassName) do
		local value = read(inst, name)
		if value ~= nil then
			if typeof(value) == "Instance" then
				table.insert(refs, { node = node, name = name, target = value })
			elseif not equals_default(default, name, value) then
				local encoded = encode(value)
				if encoded then
					node.props[name] = encoded
				end
			end
		end
	end

	local ok_attrs, attrs = pcall(function()
		return inst:GetAttributes()
	end)
	if ok_attrs then
		for key, value in attrs do
			node.attrs[key] = encode(value)
		end
	end
	local ok_tags, tags = pcall(function()
		return inst:GetTags()
	end)
	if ok_tags then
		node.tags = tags
	end

	for _, child in inst:GetChildren() do
		table.insert(node.children, serialize_node(child, seen, refs))
	end
	return node
end

-- roots -> one tree. one root is renamed to `name`; several roots go inside a Folder called `name`
function model.from_instances(roots, name: string)
	local root = roots[1]
	if #roots ~= 1 then
		root = roblox.Instance.new("Folder")
		for _, r in roots do
			r.Parent = root
		end
	end
	root.Name = name

	local seen, refs = {}, {}
	local tree = serialize_node(root, seen, refs)
	-- refs pointing outside the tree are dropped
	for _, ref in refs do
		for _, pair in seen do
			if pair[1] == ref.target then
				ref.node.props[ref.name] = { "Ref", pair[2] }
				break
			end
		end
	end
	return tree, #seen
end

function model.from_rbxm(contents: string, name: string)
	return model.from_instances(roblox.deserializeModel(contents), name)
end

-- rojo .model.json: { ClassName, Name?, Properties = {}, Attributes?, Children = {} }
-- properties: primitives as is, or explicit typed { Vector3 = {1,2,3} } style
function model.from_model_json(contents: string, name: string)
	local data = serde.decode("json", contents)
	local count = 0
	local function convert(item, item_name)
		count += 1
		local node = { id = count, class = item.ClassName or "Folder", name = item_name or item.Name or item.ClassName, props = {}, attrs = {}, tags = {}, children = {} }
		for key, value in item.Properties or {} do
			if type(value) == "table" then
				local kind, raw = next(value)
				if type(raw) == "table" then
					node.props[key] = { kind, table.unpack(raw) }
				else
					node.props[key] = { kind, raw }
				end
			else
				node.props[key] = { typeof(value), value }
			end
		end
		for key, value in item.Attributes or {} do
			node.attrs[key] = { typeof(value), value }
		end
		for _, child in item.Children or {} do
			table.insert(node.children, convert(child))
		end
		return node
	end
	return convert(data, name), count
end

function model.from_text(contents: string, name: string)
	return { id = 1, class = "StringValue", name = name, props = { Value = { "string", contents } }, attrs = {}, tags = {}, children = {} }, 1
end

-- .json / .toml data file -> luau source that returns the same table
function model.data_module(contents: string, format: string): string
	local data = serde.decode(format, contents)

	local function literal(value, indent)
		local kind = type(value)
		if kind == "string" then
			return string.format("%q", value)
		elseif kind == "number" or kind == "boolean" then
			return tostring(value)
		elseif kind ~= "table" then
			return "nil"
		end
		local pad = string.rep("\t", indent + 1)
		local lines = {}
		if #value > 0 then
			for _, item in value do
				table.insert(lines, pad .. literal(item, indent + 1) .. ",")
			end
		else
			local keys = {}
			for key in value do
				table.insert(keys, key)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, key in keys do
				local key_text = type(key) == "string" and key:match("^[%a_][%w_]*$") and key or `[{literal(key, 0)}]`
				table.insert(lines, `{pad}{key_text} = {literal(value[key], indent + 1)},`)
			end
		end
		if #lines == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("\t", indent) .. "}"
	end

	return "-- generated by xenon from a data file\nreturn " .. literal(data, 0) .. "\n"
end

return model
