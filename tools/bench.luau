-- run: lune run tools/bench.luau [packages]   (from the xenon folder)
-- times the server's rescan (what `xenon serve` does every second) on a generated project:
-- wally-style packages (nested default.project.json + src/init.luau + modules) plus a plain src tree.
-- prints the cost of one warm rescan (nothing changed) and how many fs calls it makes.

local fs = require("@lune/fs")
local process = require("@lune/process")

local mapping = require("../src/mapping")

local PACKAGES = tonumber(process.args[1]) or 200
local ROOT = "tools/_bench_fixture"
if fs.isDir(ROOT) then
	fs.removeDir(ROOT)
end

local function write(path, text)
	local dir = path:match("^(.*)/")
	if dir then
		fs.writeDir(ROOT .. "/" .. dir)
	end
	fs.writeFile(ROOT .. "/" .. path, text)
end

-- ~8 scripts per package, like the playground (1600 scripts at 200 packages)
for i = 1, PACKAGES do
	local pkg = `Packages/_Index/scope_pkg{i}@1.0.0/pkg{i}`
	write(`Packages/Pkg{i}.lua`, `return require(script.Parent._Index["scope_pkg{i}@1.0.0"]["pkg{i}"])`)
	write(pkg .. "/default.project.json", '{"name":"pkg","tree":{"$path":"src"}}')
	write(pkg .. "/wally.toml", '[package]\nname = "scope/pkg"')
	write(pkg .. "/src/init.luau", "return {}")
	for m = 1, 4 do
		write(pkg .. `/src/module{m}.luau`, string.rep("local x = 1\n", 40))
	end
	write(pkg .. "/src/util/init.luau", "return {}")
	write(pkg .. "/src/util/helper.luau", "return {}")
end
for i = 1, 50 do
	write(`src/server/system{i}.server.luau`, "print('hi')")
	write(`src/shared/lib{i}.luau`, "return {}")
end
write("default.project.json", [[{"name":"bench","tree":{"$className":"DataModel",
	"ReplicatedStorage":{"$path":"src/shared","Packages":{"$path":"Packages"}},
	"ServerScriptService":{"$path":"src/server"}}}]])

-- count fs calls: mapping reads mapping.fs.* at call time (lune's own fs table is read-only)
local counts = {}
local mfs = mapping.fs
for _, name in { "isFile", "isDir", "readDir", "readFile", "metadata" } do
	local original = mfs[name]
	mfs[name] = function(...)
		counts[name] = (counts[name] or 0) + 1
		return original(...)
	end
end

local project = mapping.load_project(ROOT .. "/default.project.json")
local cache = {}

local start = os.clock()
local entries = mapping.snapshot(project, cache)
local cold = os.clock() - start

local scripts = 0
for _, entry in entries do
	if not entry.folder then
		scripts += 1
	end
end

table.clear(counts)
local RUNS = 20
start = os.clock()
for _ = 1, RUNS do
	mapping.snapshot(project, cache)
end
local warm = (os.clock() - start) / RUNS

local total, parts = 0, {}
for name, n in counts do
	total += n
	table.insert(parts, `{name} {n // RUNS}`)
end
table.sort(parts)

fs.removeDir(ROOT)
print(`bench: {scripts} scripts, {#entries} entries`)
print(`bench: first scan {math.floor(cold * 1000)} ms, warm rescan {math.floor(warm * 10000) / 10} ms`)
print(`bench: fs calls per rescan {total // RUNS} ({table.concat(parts, ", ")})`)
