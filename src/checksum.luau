-- same checksum on the server (lune) and in the studio plugin: length + rolling hash, crlf normalized

return function(source: string): string
	source = (source:gsub("\r\n", "\n"))

	local hash = 0
	for i = 1, #source do
		hash = (hash * 31 + string.byte(source, i)) % 1000000007
	end
	return `{#source} {hash}`
end
