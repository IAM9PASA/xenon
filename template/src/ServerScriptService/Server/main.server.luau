-- server entry: ServerScriptService.Server.main

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local greet = require(ReplicatedStorage.Shared.greet)

Players.PlayerAdded:Connect(function(player)
	print("[server] " .. greet.message(player.Name))
end)
