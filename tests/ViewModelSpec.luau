--!strict
-- ViewModelSpec — what each slot should SHOW, decided without a screen.

-- The renderer is Roblox GUI code and only runs in Studio. The decision of what a
-- slot displays is where the bugs are, so it lives in a pure function and is tested
-- here. Every case below is a state the server could plausibly send, including ones
-- it should never send — a UI that crashes on a malformed state is a UI that hides
-- the very bug you are trying to look at.

local ViewModel = require("../src/client/ViewModel")
local Test = require("./TestKit")

local T = Test.new("ViewModel")

-- Deliberately NOT Config's strings: if the view model read Config instead of taking
-- these as parameters, the tests would still pass and the injection would be a lie.
local MSG = {
	uiTitle = "TT",
	uiEmpty = "EE",
	uiEquipped = "QQ",
	uiDrop = "DD",
	uiHint = "HH",
}

local function estado(slots, equipped, maxSlots)
	return { revision = 7, maxSlots = maxSlots or #slots, slots = slots, equipped = equipped }
end

T("a filled slot shows the item id and the quantity", function()
	local v = ViewModel.build(estado({ { itemId = "POTION_HEALTH", quantity = 5 } }, nil), MSG)
	assert(v.ready, "a real state must be ready")
	assert(v.maxSlots == 1, "one slot")
	assert(v.slots[1].empty == false, "and it is not empty")
	assert(
		v.slots[1].label == "POTION_HEALTH",
		"the label is the id, got " .. tostring(v.slots[1].label)
	)
	assert(v.slots[1].quantity == 5, "the quantity comes through")
	assert(v.used == 1, "one slot in use")
end)

T("an empty slot shows the configured empty label", function()
	local v = ViewModel.build(estado({ nil, { itemId = "SCRAP_METAL", quantity = 2 } }, nil), MSG)
	assert(v.slots[1].empty, "slot 1 has nothing")
	assert(
		v.slots[1].label == "EE",
		"the label is the one this test passed in, got " .. tostring(v.slots[1].label)
	)
	assert(v.slots[1].quantity == 0, "and no quantity")
	assert(v.slots[2].empty == false, "slot 2 has scrap")
	assert(v.used == 1, "one of the two is in use")
end)

T("only the equipped slot is marked equipped", function()
	local v = ViewModel.build(
		estado(
			{ { itemId = "SWORD_IRON", quantity = 1 }, { itemId = "SCRAP_METAL", quantity = 3 } },
			1
		),
		MSG
	)
	assert(v.slots[1].equipped == true, "slot 1 is equipped")
	assert(v.slots[2].equipped == false, "slot 2 is not")
end)

T("an equipped index outside the inventory marks nothing", function()
	-- Cheaper than trusting the server: a stale index must not throw, and must not
	-- silently mark whichever slot happens to share the number.
	local v = ViewModel.build(estado({ { itemId = "SWORD_IRON", quantity = 1 } }, 99), MSG)
	assert(v.slots[1].equipped == false, "nothing should be marked")
end)

T("no state at all reads as NOT ready, not as an empty inventory", function()
	-- The important one. Rendering 20 empty slots before the server has said anything
	-- tells the player their items are gone.
	for _, nada in ipairs({ nil, 42, "texto" }) do
		local v = ViewModel.build(nada, MSG)
		assert(v.ready == false, "must not be ready, got " .. tostring(v.ready))
		assert(#v.slots == 0, "and must not invent slots")
		assert(v.revision == -1, "with a sentinel revision")
		assert(v.title == "TT", "the chrome still renders")
	end
end)

T("a stack that is not a proper table renders as empty", function()
	for _, basura in ipairs({ 42, "POTION_HEALTH", {}, { quantity = 5 }, { itemId = 7 } }) do
		local v = ViewModel.build(estado({ basura }), MSG)
		assert(v.slots[1].empty, "must be treated as empty: " .. tostring(basura))
		assert(v.used == 0, "and must not count as used")
	end
end)

T("a missing or nonsense quantity still shows at least 1", function()
	-- A slot that visibly holds an item must never read "0" or "nil": that is the
	-- display lying about the state, which is the one thing this design forbids.
	for _, cantidad in ipairs({ nil, 0, -3, "cinco" }) do
		local v =
			ViewModel.build(estado({ { itemId = "POTION_HEALTH", quantity = cantidad } }), MSG)
		assert(v.slots[1].quantity == 1, "expected 1 for quantity=" .. tostring(cantidad))
	end
end)

T("a malformed maxSlots yields no slots instead of crashing", function()
	for _, malo in ipairs({ 0, -5, 2.5, "20", nil }) do
		local v = ViewModel.build({ revision = 1, maxSlots = malo, slots = {} }, MSG)
		assert(v.ready, "the state itself is still a state")
		assert(#v.slots == 0, "expected no slots for maxSlots=" .. tostring(malo))
	end
end)

T("extra fields the client does not know are ignored", function()
	local v = ViewModel.build({
		revision = 3,
		maxSlots = 1,
		slots = { { itemId = "SCRAP_METAL", quantity = 1 } },
		equipped = nil,
		algoNuevo = "que un servidor mas nuevo manda",
	}, MSG)
	assert(v.ready, "it still renders")
	assert(v.maxSlots == 1, "forward compatibility: unknown fields are not fatal")
end)

T("a display name is used when one is supplied, and the id otherwise", function()
	-- The client passes the catalogue's displayName so a player reads "Health Potion".
	-- Without it the raw id is the fallback, which is what keeps this file standalone.
	local conNombres = ViewModel.build(
		estado({ { itemId = "POTION_HEALTH", quantity = 1 } }),
		MSG,
		{ POTION_HEALTH = "Health Potion" }
	)
	assert(
		conNombres.slots[1].label == "Health Potion",
		"got " .. tostring(conNombres.slots[1].label)
	)

	local sinNombres = ViewModel.build(estado({ { itemId = "POTION_HEALTH", quantity = 1 } }), MSG)
	assert(
		sinNombres.slots[1].label == "POTION_HEALTH",
		"no names table means the id, got " .. tostring(sinNombres.slots[1].label)
	)

	local desconocido = ViewModel.build(
		estado({ { itemId = "ITEM_SIN_NOMBRE", quantity = 1 } }),
		MSG,
		{ POTION_HEALTH = "Health Potion" }
	)
	assert(
		desconocido.slots[1].label == "ITEM_SIN_NOMBRE",
		"an id missing from the table falls back to itself"
	)
end)

T("the strings come from the arguments, not from Config", function()
	local v = ViewModel.build(estado({ { itemId = "SCRAP_METAL", quantity = 1 } }, 1), {
		uiTitle = "T2",
		uiEmpty = "E2",
		uiEquipped = "Q2",
		uiDrop = "D2",
		uiHint = "H2",
	})
	assert(
		v.title == "T2" and v.hint == "H2" and v.droppable == "D2" and v.equippedLabel == "Q2",
		"every string must be passed through"
	)
end)

return T.report()
