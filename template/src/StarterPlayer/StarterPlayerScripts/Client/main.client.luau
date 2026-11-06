-- client entry: StarterPlayerScripts.Client.main

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local greet = require(ReplicatedStorage.Shared.greet)

print("[client] " .. greet.message(Players.LocalPlayer.Name))
