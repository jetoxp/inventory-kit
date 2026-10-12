--!strict
-- Bench.luau — measures the numbers the case study quotes, so they can be reproduced.

-- Deliberately NOT part of tests/run.luau: a benchmark prints timings, it does not pass or
-- fail, and mixing the two means a slow machine turns into a red suite.

-- Run it:
--     luau tests/Bench.luau
--
-- Every figure is the average over many repetitions. A single pass measures tens of
-- microseconds, which is below what os.clock() can resolve: the first version of this file
-- reported a full tick as FASTER than an empty one, which is how you know you are reading
-- the clock and not the code.
--
-- What it measures, and what it does not:
--   - real, off-engine numbers for the PURE core (no Roblox involved)
--   - NOT a live-player test. Nothing here proves anything about several real servers or
--     several real clients; it measures what the code costs, which is a different claim.

local Config = require("../src/shared/Config")
local ItemDefinition = require("../src/shared/ItemDefinition")
local Items = require("../src/shared/catalog/Items")
local Inventory = require("../src/shared/Inventory")
local DataManager = require("../src/shared/DataManager")

Inventory.init({ itemDefinition = ItemDefinition, config = Config, catalog = Items })

-- A store that does nothing but hold a table. The DataManager cost that matters on a server
-- is the protocol; the transport is a network call and is not simulated here.
local function fakeStore()
	local datos = {}
	return {
		get = function(_self, key)
			return datos[key]
		end,
		update = function(_self, key, fn)
			datos[key] = fn(datos[key])
			return datos[key]
		end,
	}
end

-- Average milliseconds per call, over `reps` repetitions.
local function bench(reps: number, fn: (number) -> ()): number
	local t0 = os.clock()
	for i = 1, reps do
		fn(i)
	end
	return (os.clock() - t0) * 1000 / reps
end

local function say(label: string, valor: string): ()
	print(string.format("  %-56s %s", label, valor))
end

-- ============================================================
-- 1. The ceiling: 200 slots, every one of them full
-- ============================================================

print("\n=== 200 slots, all full (Config.ABS_MAX_SLOTS) ===")

local CAPACIDAD = Config.ABS_MAX_SLOTS
local lleno = Inventory.new(nil, CAPACIDAD)
local t_llenar = bench(200, function()
	-- A fresh inventory each time: 200 non-stackable items is the worst case for the array.
	local inv = Inventory.new(nil, CAPACIDAD)
	for i = 1, CAPACIDAD do
		inv:add("SWORD_IRON", 1, { durability = i })
	end
end)
say("fill 200 slots, one sword each", string.format("%.2f ms", t_llenar))

for i = 1, CAPACIDAD do
	lleno:add("SWORD_IRON", 1, { durability = i })
end
say("slots used", lleno:getUsedSlots() .. " / " .. CAPACIDAD)

local payload = lleno:toSave()
say(
	"slots in the payload",
	tostring(#payload.slots) .. " x " .. tostring(Config.SCHEMA_VERSION) .. " schema"
)
-- No byte size here on purpose: a Lua table has no serialised size, and Luau's
-- string.format("%s", t) refuses a table outright (it does NOT fall back to tostring, unlike
-- Lua 5.1). The real wire size is measured in Studio with JSONEncode, where it is a fact.

say(
	"toSave()",
	string.format(
		"%.3f ms",
		bench(1000, function()
			lleno:toSave()
		end)
	)
)

say(
	"fromSave()",
	string.format(
		"%.3f ms",
		bench(1000, function()
			Inventory.fromSave(payload, nil)
		end)
	)
)

local t_miss = bench(500, function()
	lleno:count("POTION_HEALTH") -- a miss, so it scans all 200 slots
end)
say("count() of an item that is absent (full scan)", string.format("%.4f ms", t_miss))

-- ============================================================
-- 2. Many sessions at once, through the real DataManager protocol
-- ============================================================

print("\n=== 50 concurrent sessions, through DataManager ===")

local N = 50
local reloj = 1000

local store2 = fakeStore()
DataManager.init({
	inventory = Inventory,
	config = Config,
	store = store2,
	now = function()
		return reloj
	end,
	sleep = function() end,
	sessionId = "bench",
	placeId = 1,
})

local t_loads = bench(20, function()
	DataManager.forgetAll()
	for i = 1, N do
		local inv = DataManager.loadFor(i)
		inv:add("POTION_HEALTH", 3, { quality = "common" })
	end
end)
say(string.format("load %d players (read + claim, each)", N), string.format("%.2f ms", t_loads))
say("  per player", string.format("%.4f ms", t_loads / N))

DataManager.forgetAll()
for i = 1, N do
	DataManager.loadFor(i)
end

local t_clean = bench(200, function()
	DataManager.tick()
end)
say("one tick: nobody dirty, heartbeat fresh", string.format("%.4f ms", t_clean))

reloj += Config.LOCK_HEARTBEAT + 1
local t_refresh = bench(200, function()
	reloj += Config.LOCK_HEARTBEAT + 1
	for i = 1, N do
		DataManager.get(i):add("SCRAP_METAL", 1)
	end
	DataManager.tick()
end)
say(
	string.format("one tick: all %d dirty + heartbeat expired", N),
	string.format("%.2f ms", t_refresh)
)
say("  per player", string.format("%.4f ms", t_refresh / N))

print("\n  Reminder: the store here is a table, not a DataStore. One real GetAsync/UpdateAsync")
print("  is ~10-100 ms of network, orders of magnitude above everything measured above.")
print("  These are the PROTOCOL's numbers: what the server pays on top of the request.\n")
