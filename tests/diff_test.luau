-- run: lune run tests/diff_test.luau   (from tools/xenon)
-- checks the line diff the plugin's review page uses

local diff = require("../src/diff")

local failures = 0
local function check(label, ok)
	if ok then
		print("  ok  " .. label)
	else
		failures += 1
		print("  FAIL " .. label)
	end
end

-- rebuilding both sides from the edits must give back the inputs
local function rebuild(edits)
	local old, new = {}, {}
	for _, edit in edits do
		if edit.kind ~= "add" then
			table.insert(old, edit.text)
		end
		if edit.kind ~= "del" then
			table.insert(new, edit.text)
		end
	end
	return table.concat(old, "\n"), table.concat(new, "\n")
end

local function kinds(edits)
	local out = {}
	for _, edit in edits do
		table.insert(out, edit.kind:sub(1, 1))
	end
	return table.concat(out)
end

local e = diff.lines("a\nb\nc", "a\nb\nc")
check("identical -> all same", kinds(e) == "sss")

e = diff.lines("a\nb\nc", "a\nx\nc")
check("one line changed", kinds(e) == "sdas")
check("line numbers", e[2].old == 2 and e[3].new == 2 and e[4].old == 3 and e[4].new == 3)

e = diff.lines("", "a\nb")
check("new file -> all added", kinds(e) == "aa")

e = diff.lines("a\r\nb\r\n", "a\nb")
check("crlf + trailing newline ignored", kinds(e) == "ss")

local old = "local a = 1\nlocal b = 2\nprint(a)\nprint(b)\nreturn a"
local new = "local a = 1\nlocal c = 3\nprint(a)\nprint(c)\nprint(b)\nreturn a + c"
e = diff.lines(old, new)
local o, n = rebuild(e)
check("rebuild old", o == old)
check("rebuild new", n == new)
local added, removed = diff.count(e)
check("counts", added == 3 and removed == 2)

-- myers on a scrambled middle
local A, B = {}, {}
for i = 1, 200 do
	table.insert(A, "line " .. i)
	table.insert(B, i % 7 == 0 and ("changed " .. i) or ("line " .. i))
end
table.insert(B, 50, "inserted")
e = diff.lines(table.concat(A, "\n"), table.concat(B, "\n"))
o, n = rebuild(e)
check("big rebuild", o == table.concat(A, "\n") and n == table.concat(B, "\n"))
added, removed = diff.count(e)
check("big minimal", added == 29 and removed == 28)

-- fold
local folded = diff.fold(diff.lines(table.concat(A, "\n"), table.concat(A, "\n"):gsub("line 100", "x")), 3)
check("fold keeps 3 around", kinds(folded) == "fsssdasssf" and folded[1].count == 96 and folded[#folded].count == 97)

print(failures == 0 and "all diff tests passed" or `{failures} diff test(s) failed`)
if failures > 0 then
	error("diff tests failed")
end
