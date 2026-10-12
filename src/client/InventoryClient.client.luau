-- InventoryClient — owns the server's truth and hands it to the UI.

-- The whole loop, and note who decides what: a click sends an INTENT, the server
-- applies or refuses it, and whatever comes back is what gets rendered. The client
-- never mutates its own copy, so the UI cannot show a state the server does not have.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Kit = ReplicatedStorage:WaitForChild("InventoryKit")

local Config = require(Kit.Config)
local Net = require(Kit.Net)
local ViewModel = require(script.Parent.ViewModel)
local InventoryUI = require(script.Parent.InventoryUI)
local MESSAGES = Config.MESSAGES

local uplink, downlink = Net.client()

-- nil until the server says something, on purpose: an empty table would render as
-- "you have nothing" and the player would believe it.
local estado: { [string]: any }? = nil

local ui = InventoryUI.new(player:WaitForChild("PlayerGui"), MESSAGES, function(index: number)
	-- Clicking the equipped slot unequips it; clicking any other equips. One control,
	-- two meanings, decided from the last state the SERVER sent.
	if estado ~= nil and estado.equipped == index then
		uplink:FireServer({ action = "unequip" })
	else
		uplink:FireServer({ action = "equip", slot = index })
	end
end, function(index: number)
	uplink:FireServer({ action = "drop", slot = index, quantity = 1 })
end)

local function pintar()
	ui.render(ViewModel.build(estado, MESSAGES))
end

downlink.OnClientEvent:Connect(function(nueva: { [string]: any })
	estado = nueva
	pintar()
end)

pintar() -- nothing yet: this renders the "not ready" state and hides the panel
uplink:FireServer({ action = "requestState" })
