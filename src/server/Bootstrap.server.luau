-- Bootstrap — the only place that wires the kit together and talks to players.

-- Order matters and is not cosmetic:
--   1. the catalogue goes into ItemDefinition
--   2. ItemDefinition + Config go into Inventory
--   3. Inventory + Config + the store go into DataManager
-- Each layer holds the previous one, so wiring them out of order fails loudly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local kit = ReplicatedStorage:WaitForChild("InventoryKit")

local Config = require(kit.Config)
local ItemDefinition = require(kit.ItemDefinition)
local Items = require(kit.catalog.Items)
local Inventory = require(kit.Inventory)
local DataManager = require(kit.DataManager)

local DataStoreAdapter = require(script.Parent.DataStoreAdapter)

-- In Studio there is no JobId. Without a distinct id per session every Studio
-- tab looks like "the same server" and the lock never protects anything.
local sessionId = if game.JobId ~= ""
	then game.JobId
	else "studio-" .. tostring(math.floor(os.clock() * 1000))

local store = DataStoreAdapter.new("inventory_v" .. tostring(Config.SCHEMA_VERSION))

local errores =
	Inventory.init({ itemDefinition = ItemDefinition, config = Config, catalog = Items })
if #errores > 0 then
	-- The catalogue is broken: whoever is booting wants to know now, not later.
	warn("[Bootstrap] errores en el catalogo: " .. table.concat(errores, "; "))
end

DataManager.init({
	inventory = Inventory,
	config = Config,
	store = store,
	sessionId = sessionId,
	placeId = game.PlaceId,
	sleep = task.wait,
})

local function alEntrar(player: Player)
	local inv, motivo = DataManager.loadFor(player.UserId)
	if not inv then
		-- Both failures end with the player out, but say which one: "another
		-- server" is a normal state, an outage is not.
		if motivo == "session_locked" then
			player:Kick("Tu inventario está abierto en otro servidor.")
		else
			player:Kick(
				"No pude cargar tu inventario (" .. tostring(motivo) .. "). Vuelve a entrar."
			)
		end
		return
	end
	-- Fase 4 will replicate this to the client. Nothing to send yet.
	print(
		string.format("[Bootstrap] %s entra con %d slots usados", player.Name, inv:getUsedSlots())
	)
end

local function alSalir(player: Player)
	local ok, err = pcall(function()
		return DataManager.release(player.UserId)
	end)
	if not ok then
		warn("[Bootstrap] fallo al soltar a " .. player.Name .. ": " .. tostring(err))
	end
end

Players.PlayerAdded:Connect(function(player)
	-- In a thread: a DataStore call can take a second, and blocking PlayerAdded
	-- delays everyone else in the server.
	task.spawn(alEntrar, player)
end)

-- Studio starts with players already in; PlayerAdded will not fire for them.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(alEntrar, player)
end

Players.PlayerRemoving:Connect(alSalir)

game:BindToClose(function()
	-- Roblox gives about 30s. Releasing in parallel is what actually fits: one
	-- release can retry three times with a backoff, and doing them in sequence
	-- runs out of budget long before it runs out of players.
	if RunService:IsStudio() then
		return
	end
	local pendientes = 0
	for _, player in ipairs(Players:GetPlayers()) do
		pendientes += 1
		task.spawn(function()
			pcall(function()
				DataManager.release(player.UserId)
			end)
			pendientes -= 1
		end)
	end
	local limite = os.clock() + 20
	while pendientes > 0 and os.clock() < limite do
		task.wait(0.1)
	end
end)

-- Housekeeping. tick() saves whatever is dirty and refreshes the claims, so a
-- long session does not look abandoned. `pcall` because one bad tick must not
-- kill the loop and silently stop saving everything.
task.spawn(function()
	while true do
		task.wait(5)
		local ok, err = pcall(function()
			DataManager.tick()
		end)
		if not ok then
			warn("[Bootstrap] tick falló: " .. tostring(err))
		end
	end
end)
