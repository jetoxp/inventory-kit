--!strict
-- Config — every tunable number of the kit lives here so nothing else hardcodes a limit.
-- Values are tagged [DECIDED] / [PROVISIONAL] / [TODO] so the owner can review my
-- assumptions in one pass instead of auditing every number.

local Config = {}

-- ============================================================
-- SCHEMA
-- ============================================================

-- schemaVersion of the save payload. Ships on day one even though nothing is saved
-- yet, because retrofitting it is the expensive part — old saves keep existing
-- after the shape changes. Bump ONLY when the payload's shape changes, never for a value tweak.
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

-- Session lock, both halves. HEARTBEAT is how often the owner refreshes its claim;
-- STALE is how long a lock may go unrefreshed before another server assumes the
-- holder died. Keep STALE comfortably above HEARTBEAT or healthy sessions get stolen.
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

-- Per player, per action. "Never trust the client" includes its rate: a client
-- spamming a remote 500x/s is not a bug, it is an attack, and it burns server CPU.
Config.REMOTE_COOLDOWNS = {
	move = 0.05,
	equip = 0.25,
	drop = 0.25,
	use = 0.20,
}

-- ============================================================
-- Text a PLAYER reads
-- ============================================================

-- The only strings a consumer's players ever see, kept here rather than baked into
-- the code. A Spanish game should not ship English kicks, and a library has no
-- business deciding the language. English defaults: translate them freely.
Config.MESSAGES = {
	-- The account is already held by another live server.
	sessionLocked = "Your inventory is open on another server. Please rejoin in a moment.",
	-- The load failed for any other reason (an outage, a timeout).
	loadFailed = "We could not load your inventory. Please rejoin.",
}

-- How many items a single request may move at once. Anything larger is
-- rejected outright rather than clamped.
-- [PROVISIONAL]
Config.MAX_ITEMS_PER_REQUEST = 16

return Config
