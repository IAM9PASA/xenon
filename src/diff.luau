-- line diff (myers, same idea as git). pure luau: runs in lune (tests) and in the studio plugin.
--   diff.lines(old_text, new_text) -> { { kind = "same" | "add" | "del", text, old, new } }
--   diff.fold(edits, context)      -> same list, long unchanged runs replaced by { kind = "fold", count }
--   diff.count(edits)              -> added, removed

local diff = {}

-- above this many edits myers gets slow and memory heavy: show it as "everything replaced"
local MAX_EDITS = 1000

local function split(text: string): { string }
	text = text:gsub("\r\n", "\n")
	if text == "" then
		return {}
	end
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines) -- trailing newline is not an extra line
	end
	return lines
end

local function goes_down(v, k: number, d: number): boolean
	return k == -d or (k ~= d and (v[k - 1] or -1) < (v[k + 1] or -1))
end

-- shortest edit script between a and b, or nil when it needs more than MAX_EDITS
local function myers(a: { string }, b: { string })
	local n, m = #a, #b
	local v = { [1] = 0 }
	local trace = {}

	for d = 0, math.min(n + m, MAX_EDITS) do
		trace[d + 1] = table.clone(v)
		for k = -d, d, 2 do
			local x = goes_down(v, k, d) and v[k + 1] or v[k - 1] + 1
			local y = x - k
			while x < n and y < m and a[x + 1] == b[y + 1] do
				x += 1
				y += 1
			end
			v[k] = x
			if x >= n and y >= m then
				-- walk back through the trace
				local out = {}
				local cx, cy = n, m
				for back = d, 0, -1 do
					local tv = trace[back + 1]
					local ck = cx - cy
					local pk = goes_down(tv, ck, back) and ck + 1 or ck - 1
					local px = tv[pk]
					local py = px - pk
					while cx > px and cy > py do
						table.insert(out, { kind = "same", text = a[cx], old = cx, new = cy })
						cx -= 1
						cy -= 1
					end
					if back > 0 then
						if cx == px then
							table.insert(out, { kind = "add", text = b[cy], new = cy })
						else
							table.insert(out, { kind = "del", text = a[cx], old = cx })
						end
					end
					cx, cy = px, py
				end
				-- reverse
				local edits = table.create(#out)
				for i = #out, 1, -1 do
					table.insert(edits, out[i])
				end
				return edits
			end
		end
	end
	return nil
end

function diff.lines(old_text: string, new_text: string)
	local a, b = split(old_text), split(new_text)

	-- common start / end first: keeps myers small for the usual "few lines changed" case
	local head = 0
	while head < #a and head < #b and a[head + 1] == b[head + 1] do
		head += 1
	end
	local tail = 0
	while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do
		tail += 1
	end

	local mid_a = table.move(a, head + 1, #a - tail, 1, {})
	local mid_b = table.move(b, head + 1, #b - tail, 1, {})
	local middle = myers(mid_a, mid_b)
	if not middle then
		middle = {}
		for i, line in mid_a do
			table.insert(middle, { kind = "del", text = line, old = i })
		end
		for i, line in mid_b do
			table.insert(middle, { kind = "add", text = line, new = i })
		end
	end

	local edits = {}
	for i = 1, head do
		table.insert(edits, { kind = "same", text = a[i], old = i, new = i })
	end
	for _, edit in middle do
		-- shift middle line numbers back to file line numbers
		table.insert(edits, {
			kind = edit.kind,
			text = edit.text,
			old = edit.old and edit.old + head,
			new = edit.new and edit.new + head,
		})
	end
	for i = tail - 1, 0, -1 do
		table.insert(edits, { kind = "same", text = a[#a - i], old = #a - i, new = #b - i })
	end
	return edits
end

-- keeps `context` unchanged lines around each change, folds the rest
function diff.fold(edits, context: number?)
	local keep = context or 3
	local near = {}
	for i, edit in edits do
		if edit.kind ~= "same" then
			for j = math.max(1, i - keep), math.min(#edits, i + keep) do
				near[j] = true
			end
		end
	end

	local out = {}
	local folded = 0
	for i, edit in edits do
		if near[i] then
			if folded > 0 then
				table.insert(out, { kind = "fold", count = folded })
				folded = 0
			end
			table.insert(out, edit)
		else
			folded += 1
		end
	end
	if folded > 0 then
		table.insert(out, { kind = "fold", count = folded })
	end
	return out
end

function diff.count(edits): (number, number)
	local added, removed = 0, 0
	for _, edit in edits do
		if edit.kind == "add" then
			added += 1
		elseif edit.kind == "del" then
			removed += 1
		end
	end
	return added, removed
end

return diff
