-- shared module: require it from server and client
-- ReplicatedStorage.Shared.greet

local greet = {}

function greet.message(name: string): string
	return `hello {name}, welcome to {{name}}`
end

return greet
