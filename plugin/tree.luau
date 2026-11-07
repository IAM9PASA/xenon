-- studio side of a sync, without any ui: find / create instances, plan what changes, apply scripts, remove.
-- the plugin builds it with studio's services; tests/tree_test.luau builds it on a lune DataModel.
--
--   local tree = require(script.tree)({
--       root = game,                         -- DataModel (GetService + FindFirstChild)
--       Instance = Instance,                 -- Instance.new
--       checksum = checksum,                 -- same hash as the server
--       write_source = function(inst, source) end,
--       yield = task.wait,                   -- optional, called every 150 entries while planning
--   })
--
-- rules (see docs/AI.md):
--   a plain Folder where disk now has a script is swapped for that script (name, children, attributes,
--   tags kept). wally writes src/*.luau before init.luau, so a package root is often a Folder first.
--   a script where disk now has a Folder goes back to a Folder only if studio still has what xenon wrote
--   (or it is inside a wally _Index). removed folders go only when they are empty.

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

return function(deps)
	local root = deps.root
	local checksum = deps.checksum
	local yield = deps.yield or function() end

	local tree = {}

	function tree.service(name: string)
		local ok, found = pcall(root.GetService, root, name)
		return ok and found or root:FindFirstChild(name)
	end

	function tree.find(path: { string })
		local node = tree.service(path[1])
		for i = 2, #path do
			if not node then
				return nil
			end
			node = node:FindFirstChild(path[i])
		end
		return node
	end

	-- new instance of `class` in place of `inst`: same name, parent, attributes, tags and children
	function tree.swap(inst, class: string)
		local ok, fresh = pcall(deps.Instance.new, class)
		if not ok then
			return inst
		end
		fresh.Name = inst.Name
		for name, value in inst:GetAttributes() do
			fresh:SetAttribute(name, value)
		end
		pcall(function()
			for _, tag in inst:GetTags() do
				fresh:AddTag(tag)
			end
		end)
		for _, child in inst:GetChildren() do
			child.Parent = fresh
		end
		fresh.Parent = inst.Parent
		inst.Parent = nil -- not destroyed: ctrl+z inside the recording brings it back
		return fresh
	end

	-- creates missing ancestors as Folders, the last one as `class`. an existing plain Folder at the end
	-- becomes the script when `class` is a script class. nothing else is removed or replaced
	function tree.ensure(path: { string }, class: string)
		local node = tree.service(path[1])
		for i = 2, #path do
			local child = node:FindFirstChild(path[i])
			local last = i == #path
			if not child then
				local ok, created = pcall(deps.Instance.new, last and class or "Folder")
				child = ok and created or deps.Instance.new("Folder")
				child.Name = path[i]
				child.Parent = node
			elseif last and SCRIPT_CLASSES[class] and child.ClassName == "Folder" then
				child = tree.swap(child, class)
			end
			node = child
		end
		return node
	end

	local function wally_owned(key: string): boolean
		return key:find("/_Index/", 1, true) ~= nil
	end

	-- a script xenon may turn back into a container: unchanged since xenon wrote it, or wally's
	local function may_demote(inst, entry, known_hash): boolean
		if wally_owned(entry.key) then
			return true
		end
		local last = known_hash[entry.key]
		return last ~= nil and checksum(inst.Source) == last
	end

	-- entries from the server -> { create, update, conflicts, skip, models_changed, remove }
	function tree.plan(entries, live: boolean, known_hash, options)
		options = options or {}
		local plan = { create = {}, update = {}, conflicts = {}, skip = {}, models_changed = {}, remove = {} }
		for i, entry in entries do
			if entry.model and options.sync_models == false then
				continue
			end
			local inst = tree.find(entry.path)
			if not inst then
				table.insert(plan.create, entry)
			elseif entry.model then
				-- models are only created, never replaced: report disk changes to models xenon made
				local stamp = inst:GetAttribute("xenon_hash")
				if stamp and stamp ~= entry.hash then
					table.insert(plan.models_changed, entry.key)
				end
			elseif entry.folder then
				-- init file removed on disk: script -> container, only if nothing in studio is lost
				if inst:IsA("LuaSourceContainer") then
					if may_demote(inst, entry, known_hash) then
						table.insert(plan.update, entry)
					else
						table.insert(plan.skip, entry.key)
					end
				end
			elseif inst.ClassName == "Folder" then
				table.insert(plan.update, entry) -- init file appeared on disk: Folder -> script
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
				yield()
			end
		end
		return plan
	end

	-- files / folders deleted on disk during a live session. scripts only if studio still has exactly
	-- what disk had, folders only if they are still that container (emptiness is checked when removing)
	function tree.plan_removals(plan, removed, options)
		options = options or {}
		if options.sync_deletes == false then
			return
		end
		for _, entry in removed do
			if entry.model then
				continue
			end
			local inst = tree.find(entry.path)
			if not inst or inst.ClassName ~= entry.class then
				continue
			end
			if entry.folder then
				if not inst:IsA("LuaSourceContainer") then
					table.insert(plan.remove, entry)
				end
			elseif inst:IsA("LuaSourceContainer") then
				if checksum(inst.Source) == entry.hash then
					table.insert(plan.remove, entry)
				else
					table.insert(plan.conflicts, entry) -- edited in studio, keep it
				end
			end
		end
	end

	-- deepest first, so a package folder goes after everything inside it. returns how many went
	function tree.remove(entries, known_hash): (number, { string })
		local sorted = table.clone(entries)
		table.sort(sorted, function(a, b)
			return #a.path > #b.path
		end)
		local removed, kept = 0, {}
		for _, entry in sorted do
			local inst = tree.find(entry.path)
			-- check again right before: same class, unchanged script, nothing left inside
			local ok = inst ~= nil and inst.ClassName == entry.class and #inst:GetChildren() == 0
			if ok and not entry.folder then
				ok = inst:IsA("LuaSourceContainer") and checksum(inst.Source) == entry.hash
			end
			if ok then
				inst.Parent = nil -- inside the recording, so ctrl+z puts it back
				known_hash[entry.key] = nil
				removed += 1
			elseif inst then
				table.insert(kept, entry.key)
			end
		end
		return removed, kept
	end

	-- creates / updates in parent-before-child order. sources: key -> source (scripts).
	-- on_model(entry) builds models (the plugin decodes their trees)
	function tree.write(entries, sources, known_hash, on_model)
		local sorted = table.clone(entries)
		table.sort(sorted, function(a, b)
			if #a.path ~= #b.path then
				return #a.path < #b.path
			end
			return a.key < b.key
		end)
		for _, entry in sorted do
			if entry.model then
				if on_model then
					on_model(entry)
				end
				continue
			end

			if entry.folder then
				local inst = tree.find(entry.path)
				if inst and inst:IsA("LuaSourceContainer") then
					tree.swap(inst, entry.class)
					known_hash[entry.key] = nil
				elseif not inst then
					tree.ensure(entry.path, entry.class)
				end
				continue
			end

			local inst = tree.ensure(entry.path, entry.class)
			if not inst:IsA("LuaSourceContainer") or inst.ClassName ~= entry.class then
				continue
			end
			local source = sources[entry.key]
			if type(source) == "string" then
				deps.write_source(inst, source)
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

	return tree
end
