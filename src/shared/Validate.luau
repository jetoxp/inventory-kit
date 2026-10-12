-- Validate — everything the server must check before believing a client.

-- Pure functions, no Roblox, on purpose: this is the file where a mistake is a
-- security hole, so it is the file that most needs to be testable. The remotes
-- themselves are thin shells around this.

-- The rule this file exists to enforce: the client sends INTENT, never facts.
-- "move slot 3 to slot 1" is intent and can be validated. "I now have 99 swords"
-- is a fact and must never be accepted from a client.

local Validate = {}

-- One entry per action, listing exactly the fields it accepts and what each must
-- look like. Unknown fields are rejected rather than ignored: a payload with
-- extra keys is either a version mismatch or someone probing, and both deserve a
-- closed door rather than a shrug.
local SCHEMAS = {
	move = { from = "slot", to = "slot" },
	equip = { slot = "slot" },
	unequip = {},
	drop = { slot = "slot", quantity = "positive" },
	requestState = {},
}

-- A slot index that could actually exist. maxSlots is passed in because the
-- inventory's size is per-inventory, not a global.
local function isSlot(value: any, maxSlots: number): boolean
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false -- NaN and infinities are numbers and still must not pass
	end
	if value % 1 ~= 0 then
		return false -- 2.5 is not a slot
	end
	return value >= 1 and value <= maxSlots
end

local function isPositive(value: any): boolean
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge then
		return false
	end
	return value % 1 == 0 and value >= 1
end

--[[
	Validates one client request.

	Returns (ok, reason). The reason is for the SERVER LOG, never for the client:
	telling a probing client which field it got wrong is a free hint, and a
	legitimate client cannot see the message anyway.

	maxSlots comes from the player's own inventory, so the range check is against
	the size they actually have.
]]
function Validate.request(payload: any, maxSlots: number): (boolean, string?)
	if type(payload) ~= "table" then
		return false, "payload_not_a_table"
	end

	local action = payload.action
	if type(action) ~= "string" then
		return false, "missing_action"
	end

	local schema = SCHEMAS[action]
	if schema == nil then
		return false, "unknown_action:" .. action
	end

	-- Every declared field must be present and well-typed.
	for field, kind in pairs(schema) do
		local value = payload[field]
		if value == nil then
			return false, string.format("%s: missing %s", action, field)
		end
		local fine = if kind == "slot" then isSlot(value, maxSlots) else isPositive(value)
		if not fine then
			return false, string.format("%s: bad %s", action, field)
		end
	end

	-- And nothing beyond them. Counting is the cheap way to catch a payload with
	-- extra keys without listing every allowed name again.
	local declarados = 0
	for _ in pairs(schema) do
		declarados += 1
	end
	local recibidos = 0
	for field in pairs(payload) do
		-- `action` is always allowed and is not part of the per-field schema.
		if field ~= "action" and schema[field] == nil then
			return false, string.format("%s: unexpected field %s", action, tostring(field))
		end
		recibidos += 1
	end
	if recibidos > declarados + 1 then
		return false, string.format("%s: too many fields", action)
	end

	-- Dropping more than a stack could hold is a client bug at best.
	if action == "drop" and payload.quantity > 999 then
		return false, "drop: quantity out of any sane range"
	end

	return true, nil
end

--[[
	Per player, per action cooldown.

	`now` is a parameter rather than os.clock() inside so the tests can age a
	bucket without sleeping. Callers pass their own clock; this file never asks
	what time it is.

	forget() matters as much as allow(): without it the table grows by one entry
	per player per action for the lifetime of the server.
]]

function Validate.newRateLimiter(cooldowns: { [string]: number })
	local ultimo: { [number]: { [string]: number } } = {}

	local limiter = {}

	-- Returns (allowed, waitTime). waitTime is what the caller can log to see how
	-- badly someone is spamming.
	function limiter:allow(userId: number, action: string, now: number): (boolean, number)
		local cooldown = cooldowns[action]
		if cooldown == nil then
			return true, 0 -- an action with no configured cooldown is not rate limited
		end

		local porJugador = ultimo[userId]
		if porJugador == nil then
			porJugador = {}
			ultimo[userId] = porJugador
		end

		local previo = porJugador[action]
		if previo ~= nil and now - previo < cooldown then
			return false, cooldown - (now - previo)
		end

		porJugador[action] = now
		return true, 0
	end

	-- Call on PlayerRemoving, or this table leaks one entry per player forever.
	function limiter:forget(userId: number): ()
		ultimo[userId] = nil
	end

	function limiter:trackedPlayers(): number
		local n = 0
		for _ in pairs(ultimo) do
			n += 1
		end
		return n
	end

	return limiter
end

Validate.SCHEMAS = SCHEMAS

return Validate
