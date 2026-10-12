--!strict
--[[
	ItemDefinitionSpec.luau — the stacking rules, proved without Studio.

	WHY THIS EXISTS
	The stacking rule is the part of this kit most likely to be wrong in a way
	nobody notices until a player complains that their potions will not merge.
	It is pure logic, so it runs here, in a second, on every change.

	The catalogue under test is the REAL one, loaded straight from disk. A test
	against a fixture would pass while the shipped catalogue was broken.
]]

local ItemDefinition = require("../src/shared/ItemDefinition")
local Items = require("../src/shared/catalog/Items")
local Test = require("./TestKit")

local T = Test.new("ItemDefinition")

-- init() returns the validation findings; a sound catalogue returns none.
local errores, avisos = ItemDefinition.init(Items)

T("init() accepts the shipped catalogue with no ERRORS", function()
	assert(#errores == 0, "the shipped catalogue has errors: " .. table.concat(errores, "; "))
	assert(ItemDefinition.isReady(), "isReady() must be true after init()")
end)

T("init() warns about the item that merges freely, without calling it an error", function()
	-- SCRAP_METAL compares no metadata on purpose. The validator must point it
	-- out as a warning so the author can confirm it was a choice, and must NOT
	-- treat it as a fault that stops the server.
	assert(#avisos >= 1, "expected at least one warning, got none")
	local menciona = false
	for _, aviso in ipairs(avisos) do
		if string.find(aviso, "SCRAP_METAL", 1, true) then
			menciona = true
		end
	end
	assert(menciona, "the warning should name SCRAP_METAL")
end)

T("a known id resolves, an unknown one does not", function()
	assert(ItemDefinition.exists("POTION_HEALTH"), "POTION_HEALTH is in the catalogue")
	assert(not ItemDefinition.exists("SWORD_OF_NOTHING"), "an invented id must not resolve")
	assert(ItemDefinition.get("SWORD_OF_NOTHING") == nil, "get() returns nil for unknown ids")
end)

T("potions of the SAME quality stack", function()
	local ok = ItemDefinition.canStack(
		"POTION_HEALTH",
		{ quality = "common" },
		"POTION_HEALTH",
		{ quality = "common" }
	)
	assert(ok, "same id and same quality must stack")
end)

T("potions of DIFFERENT quality do not stack", function()
	local ok = ItemDefinition.canStack(
		"POTION_HEALTH",
		{ quality = "common" },
		"POTION_HEALTH",
		{ quality = "rare" }
	)
	assert(not ok, "quality is compared, so differing quality must split the stack")
end)

T("potions looted at different times DO stack (rolledAt is not compared)", function()
	-- This is the case a naive implementation gets wrong: it compares the whole
	-- metadata table and therefore never merges anything.
	local ok = ItemDefinition.canStack(
		"POTION_HEALTH",
		{ quality = "common", rolledAt = 1000 },
		"POTION_HEALTH",
		{ quality = "common", rolledAt = 9999 }
	)
	assert(ok, "rolledAt is not in stackableMetadata, so it must be ignored")
end)

T("potions where one side is missing quality do not stack", function()
	local ok = ItemDefinition.canStack("POTION_HEALTH", { quality = "common" }, "POTION_HEALTH", {})
	assert(not ok, "a missing compared key differs from a present one")
end)

T("swords never stack, whatever their durability", function()
	local ok = ItemDefinition.canStack(
		"SWORD_IRON",
		{ durability = 90 },
		"SWORD_IRON",
		{ durability = 90 }
	)
	assert(not ok, "stackable=false must win over identical metadata")
end)

T("different item kinds never stack", function()
	local ok = ItemDefinition.canStack("POTION_HEALTH", { quality = "common" }, "SCRAP_METAL", {})
	assert(not ok, "stacking is within one item id only")
end)

T("unknown items never stack, they are rejected", function()
	assert(not ItemDefinition.canStack("NOPE", nil, "NOPE", nil), "an unknown id cannot stack")
end)

T("stackKey is stable regardless of the order keys were written", function()
	-- Without the internal sort, {quality=a, tier=b} and {tier=b, quality=a}
	-- would produce different keys and the same item could occupy two slots.
	local k1 = ItemDefinition.stackKey("POTION_HEALTH", { quality = "common", tier = "b" })
	local k2 = ItemDefinition.stackKey("POTION_HEALTH", { tier = "b", quality = "common" })
	assert(
		k1 == k2,
		"key order must not change the stack key: " .. tostring(k1) .. " vs " .. tostring(k2)
	)
end)

T("scrap merges even with no metadata at all", function()
	local k = ItemDefinition.stackKey("SCRAP_METAL", nil)
	assert(k ~= nil, "a stackable item with no compared metadata still has a key")
	local ok = ItemDefinition.canStack("SCRAP_METAL", nil, "SCRAP_METAL", {})
	assert(ok, "nothing is compared, so pieces of scrap always merge")
end)

T("validate() catches a broken catalogue", function()
	-- A deliberately malformed catalogue: every one of these is a typo a real
	-- developer makes, and each should be reported rather than crash.
	local ItemDefinition2 = require("../src/shared/ItemDefinition")
	local malo = {
		NO_NAME = { id = "NO_NAME", stackable = true, stackableMetadata = { "a" }, maxStack = 5 },
		BAD_MAX = {
			id = "BAD_MAX",
			displayName = "x",
			stackable = true,
			stackableMetadata = { "a" },
			maxStack = 0,
		},
		MISMATCHED_ID = {
			id = "OTRA_COSA",
			displayName = "x",
			stackable = false,
			stackableMetadata = {},
			maxStack = 1,
		},
		MERGES_EVERYTHING = {
			id = "MERGES_EVERYTHING",
			displayName = "x",
			stackable = true,
			stackableMetadata = {},
			maxStack = 5,
		},
	}
	local malosErrores, malosAvisos = ItemDefinition2.init(malo)
	-- Three of the four faults break the data and must be errors.
	assert(#malosErrores >= 3, "expected at least 3 errors, got " .. tostring(#malosErrores))
	-- The fourth is legal-but-suspicious and must be a warning, not an error.
	assert(#malosAvisos >= 1, "expected at least 1 warning, got " .. tostring(#malosAvisos))
	for _, h in ipairs(malosErrores) do
		print("        error:   " .. h)
	end
	for _, a in ipairs(malosAvisos) do
		print("        warning: " .. a)
	end
	-- Restore the real catalogue so ordering between tests cannot matter.
	ItemDefinition.init(Items)
end)

return T.report()
