--!strict
--[[
	Config.luau — the kit's tuning knobs, in one place.

	WHY THIS EXISTS
	Every number a consumer of this kit might want to change lives here so it
	can be changed once and picked up everywhere. Nothing else in the kit
	hardcodes a limit.

	HOW VALUES ARE TAGGED
	  [DECIDED]      Chosen by the project owner. Do not change without asking.
	  [PROVISIONAL]  Set to get moving; expected to change.
	  [TODO]         NOT decided yet. Do not invent a value: ask.

	WHAT THIS MODULE DOES NOT DO
	It holds no state and requires nothing. Reading it is always safe.
]]

local Config = {}

-- ============================================================
-- SCHEMA
-- ============================================================

--[[
	Version of the save payload written to DataStores.

	[DECIDED] It ships on day one even though nothing is saved yet, because
	retrofitting it is the expensive part. When a future phase adds a field
	(an `equipped` slot, a durability counter), old saves still exist and must
	still load. DataManager reads this number to decide which migration to run.

	Bump it ONLY when the shape of the payload changes, never for a value tweak.
]]
Config.SCHEMA_VERSION = 1

-- ============================================================
-- INVENTORY
-- ============================================================

-- Slots a new inventory gets when the caller does not pass a size.
-- [DECIDED] 20, as agreed.
Config.DEFAULT_MAX_SLOTS = 20

-- Hard ceiling for setMaxSlots(), so a caller cannot ask for a million slots
-- and take the server down with a single call.
-- [PROVISIONAL] A guard rail, not a design decision.
Config.ABS_MAX_SLOTS = 200

-- ============================================================
-- PERSISTENCE
-- ============================================================

-- Seconds between autosaves of a dirty inventory.
-- [DECIDED] 60, as specified in the brief.
Config.AUTOSAVE_INTERVAL = 60

--[[
	Session locking, both halves.

	LOCK_HEARTBEAT: how often the owning server refreshes its claim while the
	player is in. Without a heartbeat a lock is just a flag, and a server crash
	leaves the data locked forever.

	LOCK_STALE_AFTER: how long a lock may go unrefreshed before another server
	is allowed to assume the owner died and steal it. Must be comfortably
	greater than LOCK_HEARTBEAT, or healthy sessions get stolen from.
	[PROVISIONAL] Tuned so a dead session is reclaimed in about a minute.
]]
Config.LOCK_HEARTBEAT = 15
Config.LOCK_STALE_AFTER = 60

-- Retry policy for every DataStore call. The brief requires pcall everywhere;
-- this is how many times we bother trying before giving up and telling the
-- player their progress may not have saved.
-- [PROVISIONAL]
Config.DATASTORE_RETRIES = 3
Config.DATASTORE_RETRY_DELAY = 2

-- ============================================================
-- SECURITY
-- ============================================================

--[[
	Minimum seconds between accepted remote requests, per player, per action.

	[DECIDED IN PRINCIPLE, VALUE PROVISIONAL] "Never trust the client" also
	means never trusting its rate. A client that spams a remote 500 times a
	second is not a bug, it is an attack, and it costs the server real CPU.
]]
Config.REMOTE_COOLDOWNS = {
	move = 0.05,
	equip = 0.25,
	drop = 0.25,
	use = 0.20,
}

-- How many items a single request may move at once. Anything larger is
-- rejected outright rather than clamped.
-- [PROVISIONAL]
Config.MAX_ITEMS_PER_REQUEST = 16

return Config
