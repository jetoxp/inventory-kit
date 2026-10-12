-- Bootstrap — the only place that wires the kit together and talks to players.

-- Order matters and is not cosmetic:
--   1. the catalogue goes into ItemDefinition
--   2. ItemDefinition + Config go into Inventory
--   3. Inventory + Config + the store go into DataManager
-- Each layer holds the previous one, so wiring them out of order fails loudly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local kit = ReplicatedStorage:WaitForChild("InventoryKit")

local Config = require(kit.Config)
local ItemDefinition = require(kit.ItemDefinition)
local Items = require(kit.catalog.Items)
local Inventory = require(kit.Inventory)
local DataManager = require(kit.DataManager)

local DataStoreAdapter = require(script.Parent.DataStoreAdapter)

local Net = require(kit.Net)
local Validate = require(kit.Validate)
local InventoryService = require(script.Parent.InventoryService)

-- In Studio there is no JobId. Without a distinct id per session every Studio
-- tab looks like "the same server" and the lock never protects anything.
local sessionId = if game.JobId ~= ""
	then game.JobId
	else "studio-" .. tostring(math.floor(os.clock() * 1000))

local store = DataStoreAdapter.new("inventory_v" .. tostring(Config.SCHEMA_VERSION))

local errores =
	Inventory.init({ itemDefinition = ItemDefinition, config = Config, catalog = Items })

-- The door. Everything a client sends arrives here, and nothing gets through
-- without passing Validate and the rate limiter first.
InventoryService.start({
	validate = Validate,
	config = Config,
	dataManager = DataManager,
	net = Net,
})
if #errores > 0 then
	-- The catalogue is broken: whoever is booting wants to know now, not later.
	warn("[Bootstrap] catalogue errors: " .. table.concat(errores, "; "))
end

DataManager.init({
	inventory = Inventory,
	config = Config,
	store = store,
	sessionId = sessionId,
	placeId = game.PlaceId,
	sleep = task.wait,
})

-- Measures the two things a case study would otherwise have to guess at: how long a real
-- DataStore load takes, and how big the payload actually is. os.clock() is an elapsed-time
-- clock in Roblox, so it includes the yield inside the DataStore call.
local function medirCarga(inv: any): (number, number)
	local t0 = os.clock()
	local json = HttpService:JSONEncode(inv:toSave())
	return (os.clock() - t0) * 1000, #json
end

local function alEntrar(player: Player)
	local t0 = os.clock()
	local inv, motivo = DataManager.loadFor(player.UserId)
	local msCarga = (os.clock() - t0) * 1000
	if not inv then
		-- Both failures end with the player out, but say which one: "another
		-- server" is a normal state, an outage is not.
		-- In Studio the place is usually unpublished, and an unpublished place has no
		-- DataStore at all. Kicking there would make the kit impossible to try out, so
		-- in Studio only we let them in without persistence and say so. Never in a live
		-- game: playing on unpersisted data and then saving over it is how items get
		-- duplicated.
		if RunService:IsStudio() and motivo ~= "session_locked" then
			warn(
				string.format(
					"[Bootstrap] %s is joining WITHOUT persistence (%s)",
					player.Name,
					tostring(motivo)
				)
			)
			return
		end

		if motivo == "session_locked" then
			player:Kick(Config.MESSAGES.sessionLocked)
		else
			-- The reason is an internal detail. It goes to the log, not to the player:
			-- "store_unavailable" tells them nothing and tells an attacker something.
			warn(string.format("[Bootstrap] %s: load failed (%s)", player.Name, tostring(motivo)))
			player:Kick(Config.MESSAGES.loadFailed)
		end
		return
	end
	local msSerializar, bytes = medirCarga(inv)
	print(
		string.format(
			"[Bootstrap] %s joined with %d slots used (DataStore load %.0f ms, payload %d bytes, serialise %.2f ms)",
			player.Name,
			inv:getUsedSlots(),
			msCarga,
			bytes,
			msSerializar
		)
	)
	InventoryService.sendState(player)
end

local function alSalir(player: Player)
	local ok, err = pcall(function()
		return DataManager.release(player.UserId)
	end)
	InventoryService.forgetPlayer(player.UserId)
	if not ok then
		warn("[Bootstrap] failed to release " .. player.Name .. ": " .. tostring(err))
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
			warn("[Bootstrap] tick failed: " .. tostring(err))
		end
	end
end)
