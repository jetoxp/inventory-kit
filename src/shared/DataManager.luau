--!strict
-- DataManager — when to save, how to retry, and who owns a player's data.

-- No DataStoreService in here. The store arrives injected as an object with
-- get/set/update, so this whole file runs in a plain Luau interpreter and the
-- lock protocol gets tested instead of hoped at. The Roblox bridge is a separate
-- 40-line file in src/server.

-- One key per player, holding BOTH the data and the lock, on purpose:
--   { schemaVersion, data = <inventory save>, lock = {sessionId, placeId, at} }
-- One atomic write covers both. Two keys would leave a window where the data
-- landed and the lock did not (or the reverse), and that window is a dupe.

-- The lock is a CLAIM with a timestamp, not a boolean, so a server that dies
-- without releasing leaves something recoverable: once it goes stale another
-- server takes it over. A plain flag would wedge the player forever.

-- Anything the outside world provides (time, sleeping) is injected too. Tests
-- need to age a lock and cannot wait 60 real seconds for it.

-- get + update only. No `set`: a plain write of the lock is a race, and the
-- narrowest interface is the one nobody can misuse.
export type Store = {
	get: (key: string) -> any,
	update: (key: string, transform: (any) -> any) -> any,
}

export type Deps = {
	inventory: any,
	config: any,
	store: Store,
	now: (() -> number)?,
	sleep: ((number) -> ())?,
	sessionId: string,
	placeId: number,
}

local DataManager = {}

local Inventory: any = nil
local Config: any = nil
local Store: Store? = nil
local now: () -> number = os.time
local sleep: (number) -> () = function(_seconds: number) end

local sessionId: string = ""
local placeId: number = 0

-- Players we are currently responsible for. Keyed by user id, NOT by the Player
-- object: the object is gone by the time PlayerRemoving finishes, and we still
-- need to find the record to release the lock.
local sessions: { [number]: any } = {}

-- The key MUST carry the userId. It did not, and every player shared one record.
-- selene caught it (unused parameter in a key builder); the test suite could not,
-- because each case injects its own fresh store, so nothing ever collided.
local KEY = "inv_v%d_%d"

local function log(msg: string): ()
	if warn then
		warn("[DataManager] " .. msg)
	else
		print("[DataManager] " .. msg)
	end
end

local function keyFor(userId: number): string
	return string.format(KEY, Config.SCHEMA_VERSION, userId)
end

--[[
	Every store call goes through here.

	The brief says pcall everywhere and it is not paranoia: DataStore calls fail
	for reasons that have nothing to do with your code (throttling, a Roblox
	outage, a bad request). The caller gets a bool instead of a traceback.

	Backoff is linear, which is plenty at this scale. Do NOT retry forever: three
	attempts and then tell the caller, so it can tell the player.
]]

-- (se completa en la parte 2)

local function withRetry(fn: () -> any): (boolean, any)
	local ultimo = nil
	for intento = 1, Config.DATASTORE_RETRIES do
		local ok, resultado = pcall(fn)
		if ok then
			return true, resultado
		end
		ultimo = resultado
		if intento < Config.DATASTORE_RETRIES then
			sleep(Config.DATASTORE_RETRY_DELAY)
		end
	end
	return false, ultimo
end

-- Atomic read-modify-write through the store's update, which in Roblox is
-- UpdateAsync: it re-reads and retries internally if someone else wrote first.
-- Writing the lock with a plain set would be a race, and a race here is two
-- servers both believing they own the player.

local function writeRecord(userId: number, data: any, keepLock: boolean): (boolean, string?)
	local ok, err = withRetry(function()
		return Store:update(keyFor(userId), function(_actual)
			return {
				schemaVersion = Config.SCHEMA_VERSION,
				data = data,
				-- At the account level keepLock is always true except on release.
				-- data is never nil here, so a released record keeps the last save.
				lock = if keepLock
					then { sessionId = sessionId, placeId = placeId, at = now() }
					else nil,
			}
		end)
	end)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

-- ============================================================
-- Wiring
-- ============================================================

function DataManager.init(deps: Deps): ()
	assert(deps, "DataManager.init requires a dependencies table")
	assert(deps.inventory, "DataManager.init requires `inventory`")
	assert(deps.config, "DataManager.init requires `config`")
	assert(deps.store, "DataManager.init requires `store`")
	assert(type(deps.sessionId) == "string" and deps.sessionId ~= "", "a sessionId is required")
	assert(type(deps.placeId) == "number", "a placeId is required")

	Inventory = deps.inventory
	Config = deps.config
	Store = deps.store
	sessionId = deps.sessionId
	placeId = deps.placeId
	if deps.now then
		now = deps.now
	end
	if deps.sleep then
		sleep = deps.sleep
	end
end

-- ============================================================
-- Reading
-- ============================================================

-- Returns (rawValue, reason). `reason` means THE STORE FAILED, and only that.
--
-- A garbage record is deliberately NOT reported here. It used to be, and the
-- effect was that a corrupt entry blocked the player forever instead of costing
-- them one inventory. "The store did not answer" and "the store answered with
-- nonsense" need opposite responses: block the first, rebuild the second.
local function readRecord(userId: number): (any, string?)
	local ok, resultado = withRetry(function()
		return Store:get(keyFor(userId))
	end)
	if not ok then
		return nil, "store_unavailable"
	end
	return resultado, nil
end

--[[
	loadFor -> (inventory, reason)

	The lock protocol, in order:
	  1. Read the record. A failure here is store_unavailable, not a fresh start —
	     starting a fresh inventory over a failed read is how a player loses
	     everything during a Roblox outage.
	  2. If someone ELSE holds the lock and it is still fresh, give up with
	     "session_locked". They are playing somewhere else; the caller kicks them.
	  3. If the lock is stale, take it over. That is the whole reason the lock
	     carries a timestamp: a server that died mid-session must not wedge the
	     account forever.
	  4. Claim it IMMEDIATELY before returning, or two servers loading at the same
	     moment both walk away thinking they own the player.
]]

function DataManager.loadFor(userId: number): (any, string?)
	assert(Inventory and Store, "DataManager.init was never called")

	local ya = sessions[userId]
	if ya then
		return ya.inventory, nil -- idempotent: loading twice must not build two
	end

	local crudo, razon = readRecord(userId)
	if razon then
		return nil, razon
	end

	-- Non-table record: the player gets a fresh inventory, which fromSave already
	-- knows how to build from garbage. The bad entry is logged, not fatal. The
	-- claim write below replaces it, so the corruption clears itself.
	local record = if type(crudo) == "table" then crudo else nil
	if crudo ~= nil and record == nil then
		log(
			string.format(
				"user %d: corrupt record on the disc (%s), starting fresh",
				userId,
				typeof(crudo)
			)
		)
	end

	local lock = if record then record.lock else nil
	local heldByOther = type(lock) == "table" and lock.sessionId ~= sessionId
	if heldByOther then
		local edad = now() - (tonumber(lock.at) or 0)
		if edad < Config.LOCK_STALE_AFTER then
			return nil, "session_locked"
		end
		-- Stale: the previous owner is gone. Say so — a silent steal makes a data
		-- problem invisible later.
		log(
			string.format(
				"lock from %s on user %d is stale (%ds), taking it over",
				tostring(lock.sessionId),
				userId,
				edad
			)
		)
	end

	-- No record at all is the normal first login, not a repair. Saying "corrupt"
	-- there trains the reader to ignore the message that matters.
	local inventory, motivo
	if record == nil then
		inventory = Inventory.new(userId)
	else
		inventory, motivo = Inventory.fromSave(record.data, userId)
		if motivo then
			log(string.format("user %d: loaded with '%s'", userId, motivo))
		end
	end

	sessions[userId] = { inventory = inventory, lastHeartbeat = now() }

	local ok, err = writeRecord(userId, inventory:toSave(), true)
	if not ok then
		sessions[userId] = nil
		return nil, "claim_failed:" .. tostring(err)
	end

	return inventory, nil
end

function DataManager.get(userId: number): any
	local sesion = sessions[userId]
	return sesion and sesion.inventory or nil
end

function DataManager.isTracked(userId: number): boolean
	return sessions[userId] ~= nil
end

function DataManager.trackedCount(): number
	local n = 0
	for _ in pairs(sessions) do
		n += 1
	end
	return n
end

-- ============================================================
-- Writing
-- ============================================================

function DataManager.save(userId: number): (boolean, string?)
	local sesion = sessions[userId]
	if not sesion then
		return false, "not_tracked"
	end
	if not sesion.inventory:isDirty() then
		return true, nil -- nothing changed; do not spend a request on it
	end

	local ok, err = writeRecord(userId, sesion.inventory:toSave(), true)
	if ok then
		sesion.inventory:markClean()
		sesion.lastHeartbeat = now()
	end
	return ok, err
end

--[[
	Call this on PlayerRemoving. It always writes, even when clean, because this
	write is what DROPS the lock.

	If the write fails, the LOCK STAYS. Releasing the claim after a failed save
	would let the player load an older copy on another server and lose the whole
	session — keeping it means the next load finds a stale lock and a saved state
	that is at worst a few minutes old.
]]

function DataManager.release(userId: number): (boolean, string?)
	local sesion = sessions[userId]
	if not sesion then
		return false, "not_tracked"
	end

	local ok, err = writeRecord(userId, sesion.inventory:toSave(), false)
	sessions[userId] = nil
	if not ok then
		log(
			string.format(
				"user %d: could not save on leave, keeping the lock: %s",
				userId,
				tostring(err)
			)
		)
		return false, err
	end
	return true, nil
end

--[[
	One tick of the housekeeping loop. The bootstrap calls this on a timer; keeping
	the loop outside means this file has no idea what a scheduler is.

	Two jobs: push dirty inventories, and refresh the claim so it does not go
	stale while the player is happily playing. The heartbeat is throttled by
	LOCK_HEARTBEAT — writing the lock on every tick would be a request per second.
]]

function DataManager.tick(): ()
	local t = now()
	for userId, sesion in pairs(sessions) do
		if sesion.inventory:isDirty() then
			DataManager.save(userId)
		end
		if t - sesion.lastHeartbeat >= Config.LOCK_HEARTBEAT then
			local ok = writeRecord(userId, sesion.inventory:toSave(), true)
			if ok then
				sesion.lastHeartbeat = t
			end
		end
	end
end

-- Only for tests and a full shutdown: forget everything without writing.
function DataManager.forgetAll(): ()
	sessions = {}
end

return DataManager
