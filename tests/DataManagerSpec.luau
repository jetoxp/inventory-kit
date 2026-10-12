--!strict
-- DataManagerSpec — the lock protocol, tested against a fake store.

-- Why this file can exist at all: the store is injected, so "another server holds
-- the lock", "the DataStore is down", and "an hour has passed" are objects I can
-- write, not things I have to wait for. Testing this against the real DataStore
-- would be slow, flaky, and would not let me age a lock.

local Config = require("../src/shared/Config")
local ItemDefinition = require("../src/shared/ItemDefinition")
local Items = require("../src/shared/catalog/Items")
local Inventory = require("../src/shared/Inventory")
local DataManager = require("../src/shared/DataManager")
local Test = require("./TestKit")

local T = Test.new("DataManager")

local reloj = 1000 -- controlled time, so a lock can be aged without waiting

--[[
	A fake store with the three methods DataManager is allowed to use.

	`set` is a landmine: the lock must go through `update` (UpdateAsync in Roblox)
	to be atomic, so anything that writes with `set` blows up here instead of
	racing in production.
]]
local function newStore()
	local datos: { [string]: any } = {}
	local api = {
		datos = datos,
		calls = { get = 0, update = 0 },
		failGetsLeft = 0,
		failUpdatesLeft = 0,
	}
	function api:get(key: string)
		self.calls.get += 1
		if self.failGetsLeft > 0 then
			self.failGetsLeft -= 1
			error("simulated DataStore outage")
		end
		return datos[key]
	end
	function api:update(key: string, fn: (any) -> any)
		self.calls.update += 1
		if self.failUpdatesLeft > 0 then
			self.failUpdatesLeft -= 1
			error("simulated DataStore outage")
		end
		datos[key] = fn(datos[key])
		return datos[key]
	end
	return api
end

local function reiniciar(store)
	-- DataManager keeps its sessions at module level (it is a service, not a
	-- class), so a test that forgets this inherits the previous test's players.
	Inventory.init({ itemDefinition = ItemDefinition, config = Config, catalog = Items })
	DataManager.forgetAll()
	DataManager.init({
		inventory = Inventory,
		config = Config,
		store = store,
		now = function()
			return reloj
		end,
		sleep = function() end, -- no real waiting: the retry backoff must not cost 4s
		sessionId = "sesion-mia",
		placeId = 12345,
	})
	return store
end

local function claveDe(userId: number)
	return string.format("inv_v%d_%d", Config.SCHEMA_VERSION, userId)
end

-- ============================================================
-- First load
-- ============================================================

T("a brand new player loads empty, and the lock is claimed", function()
	local store = reiniciar(newStore())
	local inv, motivo = DataManager.loadFor(7)
	assert(inv ~= nil, "a new player must get an inventory, not nil: " .. tostring(motivo))
	assert(motivo == nil, "no reason on a clean first load")
	assert(inv:getUsedSlots() == 0, "and it is empty")

	local guardado = store.datos[claveDe(7)]
	assert(type(guardado) == "table", "the record must be written immediately")
	assert(guardado.lock.sessionId == "sesion-mia", "holding our session id")
	assert(guardado.lock.at == reloj, "stamped with our clock")
	assert(store.calls.update >= 1, "claimed through update(), the atomic path")
end)

T("loading the same player twice returns the same inventory", function()
	reiniciar(newStore())
	local a = DataManager.loadFor(8)
	local b = DataManager.loadFor(8)
	assert(a == b, "the second load must not build a second inventory")
	assert(DataManager.trackedCount() == 1, "and exactly one session is tracked")
end)

T("two players never share a record", function()
	-- This is the test that was missing. keyFor() ignored its userId argument, so
	-- every player wrote to ONE key — and this suite did not notice, because each
	-- case injects its own store and nothing ever collided. selene spotted it as an
	-- unused parameter. Two players on ONE store is the shape that proves it.
	local store = reiniciar(newStore())
	local uno = DataManager.loadFor(101)
	local dos = DataManager.loadFor(102)
	uno:add("POTION_HEALTH", 3, { quality = "common" })
	DataManager.save(101)
	DataManager.save(102)
	assert(uno ~= dos, "each player gets their own inventory object")
	assert(store.datos[claveDe(101)] ~= nil, "player 101 has a record")
	assert(store.datos[claveDe(102)] ~= nil, "player 102 has a record")
	assert(store.datos[claveDe(101)] ~= store.datos[claveDe(102)], "and they are different records")
	assert(dos:count("POTION_HEALTH") == 0, "one player's items must not appear in the other's")
end)

-- ============================================================
-- The lock
-- ============================================================

T("a FRESH lock held by another server refuses the load", function()
	-- That server is alive and playing this account. Kicking is the caller's job.
	local store = newStore()
	store.datos[claveDe(9)] = {
		schemaVersion = Config.SCHEMA_VERSION,
		data = { schemaVersion = Config.SCHEMA_VERSION, maxSlots = 5, slots = {} },
		lock = { sessionId = "sesion-ajena", placeId = 999, at = reloj - 5 },
	}
	reiniciar(store)
	local inv, motivo = DataManager.loadFor(9)
	assert(inv == nil, "must not hand out a second copy of a live session")
	assert(motivo == "session_locked", "expected session_locked, got " .. tostring(motivo))
	assert(
		store.datos[claveDe(9)].lock.sessionId == "sesion-ajena",
		"and must not touch the foreign lock"
	)
end)

T("a STALE lock is taken over", function()
	-- The other server died without releasing. Without this, the account would be
	-- locked out forever.
	local store = newStore()
	store.datos[claveDe(10)] = {
		schemaVersion = Config.SCHEMA_VERSION,
		data = {
			schemaVersion = Config.SCHEMA_VERSION,
			maxSlots = 5,
			slots = {
				{ itemId = "POTION_HEALTH", quantity = 3, metadata = { quality = "common" } },
			},
		},
		lock = {
			sessionId = "sesion-muerta",
			placeId = 999,
			at = reloj - (Config.LOCK_STALE_AFTER + 1),
		},
	}
	reiniciar(store)
	local inv, motivo = DataManager.loadFor(10)
	assert(inv ~= nil, "a stale lock must not block: " .. tostring(motivo))
	assert(inv:count("POTION_HEALTH") == 3, "and the saved data must survive the takeover")
	assert(store.datos[claveDe(10)].lock.sessionId == "sesion-mia", "the claim changed hands")
end)

T("my OWN lock never blocks me", function()
	local store = newStore()
	store.datos[claveDe(11)] = {
		schemaVersion = Config.SCHEMA_VERSION,
		data = { schemaVersion = Config.SCHEMA_VERSION, maxSlots = 5, slots = {} },
		lock = { sessionId = "sesion-mia", placeId = 12345, at = reloj - 2 },
	}
	reiniciar(store)
	local inv, motivo = DataManager.loadFor(11)
	assert(
		inv ~= nil and motivo == nil,
		"re-loading my own record is fine, got " .. tostring(motivo)
	)
end)

-- ============================================================
-- Saving
-- ============================================================

T("a clean inventory is not written; a dirty one is", function()
	local store = reiniciar(newStore())
	local inv = DataManager.loadFor(12)
	local antes = store.calls.update

	local ok = DataManager.save(12)
	assert(ok == true, "saving nothing is a success")
	assert(store.calls.update == antes, "but it must not cost a request")

	inv:add("POTION_HEALTH", 3, { quality = "common" })
	assert(inv:isDirty(), "the add must leave it dirty")
	DataManager.save(12)
	assert(store.calls.update == antes + 1, "now it writes")
	assert(not inv:isDirty(), "and it is clean afterwards")
	assert(store.datos[claveDe(12)].data.slots[1].quantity == 3, "the data landed in the record")
end)

T("saving an untracked player is refused, not crashed", function()
	reiniciar(newStore())
	local ok, motivo = DataManager.save(999)
	assert(
		ok == false and motivo == "not_tracked",
		"expected not_tracked, got " .. tostring(motivo)
	)
end)

T("release saves and DROPS the lock, keeping the data", function()
	local store = reiniciar(newStore())
	local inv = DataManager.loadFor(13)
	inv:add("SWORD_IRON", 1, { durability = 77 })
	DataManager.release(13)

	local guardado = store.datos[claveDe(13)]
	assert(guardado.lock == nil, "the claim must be released")
	assert(guardado.data.slots[1].itemId == "SWORD_IRON", "but the data stays")
	assert(guardado.data.slots[1].metadata.durability == 77, "down to the metadata")
	assert(DataManager.isTracked(13) == false, "and the session is forgotten")
end)

T("release KEEPS the lock when the final write fails", function()
	-- The important one. Dropping the claim after a failed save lets the player
	-- load an older copy elsewhere and lose the session's work.
	local store = reiniciar(newStore())
	local inv = DataManager.loadFor(14)
	inv:add("POTION_HEALTH", 5, { quality = "rare" })

	store.failUpdatesLeft = Config.DATASTORE_RETRIES -- every attempt fails
	local ok, motivo = DataManager.release(14)
	assert(ok == false, "the release must report the failure")
	assert(motivo ~= nil, "with a reason")
	assert(store.datos[claveDe(14)].lock ~= nil, "and the lock must still be held")
	assert(store.datos[claveDe(14)].lock.sessionId == "sesion-mia", "by us")
end)

T("a full save/load round trip survives the store", function()
	local store = reiniciar(newStore())
	local inv = DataManager.loadFor(15)
	inv:add("POTION_HEALTH", 7, { quality = "common" })
	inv:add("SWORD_IRON", 1, { durability = 30 })
	DataManager.release(15)

	-- A different server picks it up: stale-lock path, same data.
	reloj += Config.LOCK_STALE_AFTER + 1
	reiniciar(store)
	local otra, motivo = DataManager.loadFor(15)
	assert(otra ~= nil, "the second load must work: " .. tostring(motivo))
	assert(otra:count("POTION_HEALTH") == 7, "with the potions intact")
	assert(otra:count("SWORD_IRON") == 1, "and the sword")
end)

-- ============================================================
-- The store failing
-- ============================================================

T("a transient outage is retried and then succeeds", function()
	local store = reiniciar(newStore())
	store.failGetsLeft = Config.DATASTORE_RETRIES - 1 -- only the last attempt works
	local inv, motivo = DataManager.loadFor(16)
	assert(inv ~= nil, "the retry must save it: " .. tostring(motivo))
	assert(
		store.calls.get == Config.DATASTORE_RETRIES,
		"it used every attempt, got " .. store.calls.get
	)
end)

T("a failing read does NOT start a fresh inventory over the top", function()
	-- The catastrophic version of this bug: the read fails, we assume "new
	-- player", and the first save writes an empty inventory over a real one.
	local store = reiniciar(newStore())
	store.failGetsLeft = 99
	local inv, motivo = DataManager.loadFor(17)
	assert(inv == nil, "a failed read must not produce an inventory")
	assert(motivo == "store_unavailable", "expected store_unavailable, got " .. tostring(motivo))
	assert(DataManager.isTracked(17) == false, "and nothing is tracked")
	assert(store.datos[claveDe(17)] == nil, "and nothing was written over the player's data")
end)

T("a corrupt record loads as a fresh inventory, with a reason", function()
	local store = newStore()
	store.datos[claveDe(18)] = "esto no es un registro"
	reiniciar(store)
	local inv, motivo = DataManager.loadFor(18)
	assert(inv ~= nil, "the player still gets an inventory")
	assert(inv:getUsedSlots() == 0, "an empty one")
	assert(motivo == nil, "the load itself is fine — the repair is logged, not fatal")
end)

-- ============================================================
-- Housekeeping
-- ============================================================

T("tick pushes dirty inventories and throttles the heartbeat", function()
	local store = reiniciar(newStore())
	local inv = DataManager.loadFor(19)
	inv:add("POTION_HEALTH", 2, { quality = "common" })

	local antes = store.calls.update
	DataManager.tick()
	assert(store.calls.update > antes, "the dirty inventory must be pushed")
	assert(store.datos[claveDe(19)].data.slots[1].quantity == 2, "and the data is in the record")

	-- Not dirty, and the heartbeat is fresh: a tick must cost nothing.
	local tras = store.calls.update
	DataManager.tick()
	assert(store.calls.update == tras, "a clean tick must not spend a request")

	-- Age past the heartbeat window and it must refresh the claim.
	reloj += Config.LOCK_HEARTBEAT + 1
	DataManager.tick()
	assert(store.calls.update == tras + 1, "an aged claim must be refreshed")
	assert(store.datos[claveDe(19)].lock.at == reloj, "with the new timestamp")
end)

return T.report()
