--!strict
-- ValidateSpec — the wall between a client and the server's state.

-- This suite is the one that matters most: everything else in the kit, if wrong,
-- loses an item. A hole here hands them out. The cases below are the shapes an
-- actual attacker sends, not hypotheticals.

local Config = require("../src/shared/Config")
local Validate = require("../src/shared/Validate")
local Test = require("./TestKit")

local T = Test.new("Validate")

local MAX_SLOTS = 20

-- ============================================================
-- Well-formed requests
-- ============================================================

T("every declared action accepts a correct payload", function()
	local buenos = {
		{ action = "move", from = 1, to = 3 },
		{ action = "equip", slot = 2 },
		{ action = "unequip" },
		{ action = "drop", slot = 1, quantity = 5 },
		{ action = "requestState" },
	}
	for _, payload in ipairs(buenos) do
		local ok, motivo = Validate.request(payload, MAX_SLOTS)
		assert(ok, string.format("%s should pass, got %s", payload.action, tostring(motivo)))
	end
end)

T("the highest legal slot is accepted and the next one is not", function()
	assert(
		Validate.request({ action = "equip", slot = MAX_SLOTS }, MAX_SLOTS),
		"slot == maxSlots is legal"
	)
	local ok, motivo = Validate.request({ action = "equip", slot = MAX_SLOTS + 1 }, MAX_SLOTS)
	assert(not ok, "one past the end must be refused")
	assert(motivo == "equip: bad slot", "with a reason naming the field, got " .. tostring(motivo))
end)

T("the range check follows the inventory's actual size", function()
	-- maxSlots is per-inventory, so slot 5 is fine for a 20-slot bag and not for a
	-- 3-slot chest. Hardcoding it here would be wrong for containers.
	assert(Validate.request({ action = "equip", slot = 5 }, 20), "fine in a 20-slot inventory")
	assert(not Validate.request({ action = "equip", slot = 5 }, 3), "refused in a 3-slot one")
end)

-- ============================================================
-- What an attacker sends
-- ============================================================

T("a payload that is not a table is refused", function()
	for _, malo in ipairs({ nil, 42, "equip", true }) do
		local ok, motivo = Validate.request(malo, MAX_SLOTS)
		assert(not ok, "must refuse " .. tostring(malo))
		assert(motivo == "payload_not_a_table", "got " .. tostring(motivo))
	end
end)

T("a missing or non-string action is refused", function()
	assert(select(2, Validate.request({}, MAX_SLOTS)) == "missing_action", "no action at all")
	assert(
		select(2, Validate.request({ action = 7 }, MAX_SLOTS)) == "missing_action",
		"action must be a string"
	)
end)

T("an action that does not exist is refused", function()
	local ok, motivo = Validate.request({ action = "giveMeEverything" }, MAX_SLOTS)
	assert(not ok, "an invented action must not match anything")
	assert(motivo == "unknown_action:giveMeEverything", "got " .. tostring(motivo))
end)

T("a declared field that is missing is refused", function()
	local ok, motivo = Validate.request({ action = "move", from = 1 }, MAX_SLOTS)
	assert(not ok, "move without `to` is incomplete")
	assert(motivo == "move: missing to", "got " .. tostring(motivo))
end)

T("a NaN or an infinity slot is refused", function()
	-- Both are type "number" and both would sail past a naive type check.
	local nan = 0 / 0
	local inf = math.huge
	assert(not Validate.request({ action = "equip", slot = nan }, MAX_SLOTS), "NaN is not a slot")
	assert(
		not Validate.request({ action = "equip", slot = inf }, MAX_SLOTS),
		"infinity is not a slot"
	)
	assert(
		not Validate.request({ action = "equip", slot = -inf }, MAX_SLOTS),
		"-infinity is not a slot"
	)
end)

T("a fractional, zero or negative slot is refused", function()
	assert(not Validate.request({ action = "equip", slot = 2.5 }, MAX_SLOTS), "2.5 is not a slot")
	assert(not Validate.request({ action = "equip", slot = 0 }, MAX_SLOTS), "slots are 1-based")
	assert(
		not Validate.request({ action = "equip", slot = -1 }, MAX_SLOTS),
		"negative is not a slot"
	)
end)

T("a slot sent as a STRING is refused", function()
	-- The classic: "3" == 3 is false in Lua, but a careless validator using tonumber
	-- would accept it, and then arithmetic on it produces "10" instead of 11.
	local ok = Validate.request({ action = "equip", slot = "3" }, MAX_SLOTS)
	assert(not ok, "a numeric string is not a number")
end)

T("a request carrying an EXTRA field is refused", function()
	-- The whole point of closing the door: the client sends intent, and nothing
	-- else rides along with it.
	local ok, motivo = Validate.request({ action = "equip", slot = 1, giveMe = "todo" }, MAX_SLOTS)
	assert(not ok, "an unexpected field must be rejected, not ignored")
	assert(motivo == "equip: unexpected field giveMe", "got " .. tostring(motivo))
end)

T("a drop with an absurd quantity is refused", function()
	assert(Validate.request({ action = "drop", slot = 1, quantity = 5 }, MAX_SLOTS), "5 is fine")
	assert(
		not Validate.request({ action = "drop", slot = 1, quantity = 0 }, MAX_SLOTS),
		"zero is not a drop"
	)
	assert(
		not Validate.request({ action = "drop", slot = 1, quantity = 2.5 }, MAX_SLOTS),
		"2.5 items do not exist"
	)
	assert(
		not Validate.request({ action = "drop", slot = 1, quantity = 100000 }, MAX_SLOTS),
		"not a sane quantity"
	)
end)

T("an action with no fields tolerates only an empty payload", function()
	assert(Validate.request({ action = "unequip" }, MAX_SLOTS), "unequip needs nothing")
	assert(
		not Validate.request({ action = "unequip", slot = 1 }, MAX_SLOTS),
		"and must not accept a stray slot"
	)
end)

-- ============================================================
-- Rate limiting
-- ============================================================

T("the first call passes and an immediate repeat does not", function()
	local limiter = Validate.newRateLimiter(Config.REMOTE_COOLDOWNS)
	assert(limiter:allow(1, "move", 100), "the first move is fine")
	local ok, espera = limiter:allow(1, "move", 100)
	assert(not ok, "the second one, in the same instant, is not")
	assert(espera > 0, "and it reports how long to wait, got " .. tostring(espera))
end)

T("the cooldown expires", function()
	local limiter = Validate.newRateLimiter({ move = 0.5 })
	assert(limiter:allow(1, "move", 100))
	assert(not limiter:allow(1, "move", 100.3), "still inside the window")
	assert(limiter:allow(1, "move", 100.5), "exactly at the edge must pass")
end)

T("each action has its own budget", function()
	-- Spamming moves must not block an equip: they are different actions and the
	-- player is allowed to do both.
	local limiter = Validate.newRateLimiter({ move = 1, equip = 1 })
	assert(limiter:allow(1, "move", 100))
	assert(limiter:allow(1, "equip", 100), "a second action in the same tick is fine")
	assert(not limiter:allow(1, "move", 100), "but the first action is still on cooldown")
end)

T("players do not share a budget", function()
	local limiter = Validate.newRateLimiter({ move = 1 })
	assert(limiter:allow(1, "move", 100), "player 1")
	assert(
		limiter:allow(2, "move", 100),
		"player 2, same instant, must not inherit player 1's cooldown"
	)
	assert(limiter:allow(3, "move", 100), "nor player 3")
end)

T("an action with no configured cooldown is never blocked", function()
	local limiter = Validate.newRateLimiter({ move = 1 })
	for _ = 1, 50 do
		assert(limiter:allow(1, "requestState", 100), "unconfigured actions stay open")
	end
end)

T("forget() releases a player's budget", function()
	-- Without this the table grows one entry per player per action for the whole
	-- life of the server, which is a leak, not a cooldown.
	local limiter = Validate.newRateLimiter({ move = 1 })
	limiter:allow(1, "move", 100)
	limiter:allow(2, "move", 100)
	assert(limiter:trackedPlayers() == 2, "two players tracked")
	limiter:forget(1)
	assert(limiter:trackedPlayers() == 1, "one released")
	assert(limiter:allow(1, "move", 100), "and a returning player starts clean")
end)

return T.report()
