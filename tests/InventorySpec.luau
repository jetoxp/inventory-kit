--!strict
--[[
	InventorySpec.luau — the container rules, proved without Studio.

	WHY THIS EXISTS
	This class is where items can be duplicated, lost or silently destroyed.
	Every case below is a bug that ships in real games:

	  - a copy that is not a copy, so two stacks share one metadata table
	  - a partial removal that reports success, and the next one duplicates
	  - a load that trusts the disc and hands a player an item that is gone
	  - an equipped slot that stops following its stack when you reorder

	The dependencies are the REAL Config and the REAL catalogue. A test against
	fixtures would pass while the shipped kit was broken.
]]

local Config = require("../src/shared/Config")
local ItemDefinition = require("../src/shared/ItemDefinition")
local Items = require("../src/shared/catalog/Items")
local Inventory = require("../src/shared/Inventory")
local Test = require("./TestKit")

local T = Test.new("Inventory")

local errores = Inventory.init({
	itemDefinition = ItemDefinition,
	config = Config,
	catalog = Items,
})

T("init() wires the dependencies and reports no catalogue errors", function()
	assert(#errores == 0, "the catalogue has errors: " .. table.concat(errores, "; "))
end)

-- ============================================================
-- Construction
-- ============================================================

T("a new inventory takes the configured default size", function()
	local inv = Inventory.new(nil)
	assert(inv.maxSlots == Config.DEFAULT_MAX_SLOTS, "expected " .. Config.DEFAULT_MAX_SLOTS)
	assert(inv:getUsedSlots() == 0, "a new inventory starts empty")
	assert(inv:isDirty() == false, "nothing to save until something changes")
end)

T("a new inventory takes a custom size, and rejects an impossible one", function()
	assert(Inventory.new(nil, 5).maxSlots == 5, "explicit size must be honoured")
	local ok = pcall(function()
		return Inventory.new(nil, 0)
	end)
	assert(not ok, "zero slots must raise")
	local ok2 = pcall(function()
		return Inventory.new(nil, Config.ABS_MAX_SLOTS + 1)
	end)
	assert(not ok2, "beyond the hard ceiling must raise")
end)

T("the owner is generic: a Model works exactly like a Player or nil", function()
	-- The whole reason this class is not called PlayerInventory.
	local cofre = Inventory.new({})
	assert(cofre:getOwner() ~= nil, "a container owner is kept")
	assert(Inventory.new(nil):getOwner() == nil, "nil is a valid owner for a throwaway")
end)

-- ============================================================
-- Adding and stacking
-- ============================================================

T("adding a stackable item puts it in the first slot", function()
	local inv = Inventory.new()
	local puestos, motivo = inv:add("POTION_HEALTH", 3, { quality = "common" })
	assert(puestos == 3 and motivo == nil, "3 potions should go in cleanly")
	assert(inv.slots[1].quantity == 3, "slot 1 holds 3")
	assert(inv:getUsedSlots() == 1, "one slot used")
end)

T("two adds of the same quality MERGE into one slot", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	inv:add("POTION_HEALTH", 2, { quality = "common" })
	assert(inv:getUsedSlots() == 1, "same quality must share a slot")
	assert(inv:count("POTION_HEALTH", { quality = "common" }) == 5, "3 + 2 = 5")
end)

T(
	"two adds with different rolledAt land in ONE slot — through add(), not just canStack",
	function()
		-- The headline feature of the whole kit, and until now it was only proven at the
		-- predicate level. canStack() agreeing is not the same claim as add() behaving:
		-- the inventory has to actually consult it on the way in.
		local inv = Inventory.new()
		inv:add("POTION_HEALTH", 2, { quality = "common", rolledAt = 1000 })
		inv:add("POTION_HEALTH", 2, { quality = "common", rolledAt = 9999 })
		assert(inv:getUsedSlots() == 1, "same quality must share a slot whatever the roll time")
		assert(
			inv.slots[1].quantity == 4,
			"and the quantities must combine, got " .. tostring(inv.slots[1].quantity)
		)
		-- The stored metadata is the FIRST add's: the second merged into an existing stack.
		assert(inv.slots[1].metadata.rolledAt == 1000, "the existing stack keeps its own metadata")
	end
)

T("different quality does NOT merge", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	inv:add("POTION_HEALTH", 3, { quality = "rare" })
	assert(inv:getUsedSlots() == 2, "quality is compared, so these are two stacks")
end)

T("adding 25 potions spills across slots because maxStack is 10", function()
	local inv = Inventory.new()
	local puestos, motivo = inv:add("POTION_HEALTH", 25, { quality = "common" })
	assert(puestos == 25 and motivo == nil, "all 25 should fit")
	assert(inv:getUsedSlots() == 3, "10 + 10 + 5 needs three slots")
	assert(inv.slots[1].quantity == 10, "the first stack fills to the cap")
	assert(inv.slots[3].quantity == 5, "the remainder goes in the third")
end)

T("a different item type NEVER merges into an existing stack", function()
	-- The bug this test exists for: add() passed the incoming id to canStack() twice, so
	-- the id guard never fired and scrap folded itself into a potion stack, inflating the
	-- potion count and losing the scrap. Every prior test used ONE item id per inventory,
	-- which is exactly why none of them could see it.
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	local puestos, motivo = inv:add("SCRAP_METAL", 1)

	assert(puestos == 1 and motivo == nil, "the scrap must be accepted")
	assert(inv:getUsedSlots() == 2, "and it must get its own slot, got " .. inv:getUsedSlots())
	assert(inv.slots[1].itemId == "POTION_HEALTH", "slot 1 is still the potion")
	assert(
		inv.slots[1].quantity == 1,
		"and still holds exactly ONE potion, got " .. tostring(inv.slots[1].quantity)
	)
	assert(inv.slots[2].itemId == "SCRAP_METAL", "slot 2 holds the scrap")
	assert(inv:count("POTION_HEALTH") == 1, "the potion count must not move")
	assert(inv:count("SCRAP_METAL") == 1, "and the scrap must not vanish")
end)

T("every pair of distinct catalogue items refuses to merge", function()
	-- Exhaustive over the shipped catalogue rather than one hand-picked pair: the bug was
	-- a general failure of the id guard, so the test should be general too.
	local ids = { "POTION_HEALTH", "SWORD_IRON", "SCRAP_METAL" }
	for _, a in ipairs(ids) do
		for _, b in ipairs(ids) do
			if a ~= b then
				local inv = Inventory.new()
				inv:add(a, 1, { quality = "common", durability = 1 })
				inv:add(b, 1, { quality = "common", durability = 1 })
				assert(inv:getUsedSlots() == 2, string.format("%s + %s must be two slots", a, b))
				assert(
					inv:count(a) == 1 and inv:count(b) == 1,
					string.format("%s and %s must both survive", a, b)
				)
			end
		end
	end
end)

T("swords NEVER merge, even with identical durability", function()
	local inv = Inventory.new()
	inv:add("SWORD_IRON", 1, { durability = 90 })
	inv:add("SWORD_IRON", 1, { durability = 90 })
	assert(inv:getUsedSlots() == 2, "stackable=false wins over identical metadata")
end)

T("a full inventory takes what fits and says so", function()
	local inv = Inventory.new(nil, 2)
	local puestos, motivo = inv:add("POTION_HEALTH", 25, { quality = "common" })
	-- Two slots hold 10 each; the other five have nowhere to go.
	assert(puestos == 20, "expected 20 banked, got " .. tostring(puestos))
	assert(motivo == "inventory_full", "the reason must say why")
	assert(inv:count("POTION_HEALTH", { quality = "common" }) == 20, "the partial add is kept")
end)

T("a full inventory reports zero when nothing at all fits", function()
	local inv = Inventory.new(nil, 1)
	inv:add("SWORD_IRON", 1, { durability = 10 })
	local puestos, motivo = inv:add("POTION_HEALTH", 1, { quality = "common" })
	assert(puestos == 0 and motivo == "inventory_full", "a sword occupies the only slot")
end)

T("nonsense quantities are rejected, not clamped", function()
	local inv = Inventory.new()
	assert(select(2, inv:add("POTION_HEALTH", -5)) == "invalid_quantity", "-5 must be rejected")
	assert(select(2, inv:add("POTION_HEALTH", 1.5)) == "invalid_quantity", "1.5 must be rejected")
	assert(select(2, inv:add("POTION_HEALTH", 0)) == "invalid_quantity", "0 must be rejected")
	assert(inv:getUsedSlots() == 0, "nothing may have been stored")
end)

T("an unknown item id is rejected with a reason", function()
	local inv = Inventory.new()
	local puestos, motivo = inv:add("ESPADA_QUE_NO_EXISTE", 1)
	assert(puestos == 0 and motivo == "unknown_item", "the catalogue decides what exists")
end)

T("the metadata is COPIED on the way in", function()
	-- Without the copy the caller keeps a reference, can mutate a stack's
	-- identity from outside, and the stack key it is indexed under goes stale.
	local inv = Inventory.new()
	local mio = { quality = "common" }
	inv:add("POTION_HEALTH", 3, mio)
	mio.quality = "legendary"
	assert(inv.slots[1].metadata.quality == "common", "the stored stack kept its own value")
end)

T("getSlots() hands out copies, not the live state", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	local copia = inv:getSlots()
	copia[1].quantity = 999
	copia[1].metadata.quality = "hacked"
	assert(inv.slots[1].quantity == 3, "mutating the copy must not touch the inventory")
	assert(inv.slots[1].metadata.quality == "common", "nor the metadata")
end)

-- ============================================================
-- Removing
-- ============================================================

T("removing takes the quantity and empties the slot when it hits zero", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 5, { quality = "common" })
	local quitados, motivo = inv:remove("POTION_HEALTH", 5, { quality = "common" })
	assert(quitados == 5 and motivo == nil, "all five should leave")
	assert(inv:getUsedSlots() == 0, "the emptied slot must be released")
end)

T("removing MORE than is held is atomic: it removes nothing", function()
	-- This is the bug that duplicates items: half a removal plus a success
	-- report, and the caller believes a number that was never true.
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	local quitados, motivo = inv:remove("POTION_HEALTH", 10, { quality = "common" })
	assert(quitados == 0, "expected nothing removed, got " .. tostring(quitados))
	assert(motivo == "not_enough", "the reason must say why")
	assert(inv:count("POTION_HEALTH") == 3, "the stack must be untouched")
end)

T("removing across several stacks drains them in slot order", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 25, { quality = "common" })
	inv:remove("POTION_HEALTH", 15, { quality = "common" })
	-- 25 lives in slots of 10 / 10 / 5. Taking 15 empties the first and leaves
	-- 5 in each of the others: two slots, and the count is what matters.
	assert(inv:count("POTION_HEALTH") == 10, "25 - 15 = 10")
	assert(inv:getUsedSlots() == 2, "the fully drained slot is released, the partial one stays")
	assert(inv.slots[1] == nil, "the emptied slot must actually be nil")
end)

T("removing with metadata only touches matching stacks", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 5, { quality = "common" })
	inv:add("POTION_HEALTH", 5, { quality = "rare" })
	inv:remove("POTION_HEALTH", 5, { quality = "rare" })
	assert(inv:count("POTION_HEALTH", { quality = "common" }) == 5, "the common stack is intact")
	assert(inv:count("POTION_HEALTH", { quality = "rare" }) == 0, "the rare stack is gone")
end)

T("removing with no metadata takes from any stack of that item", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 4, { quality = "common" })
	inv:add("POTION_HEALTH", 4, { quality = "rare" })
	inv:remove("POTION_HEALTH", 6)
	assert(inv:count("POTION_HEALTH") == 2, "6 of 8 removed, whatever the quality")
end)

T("a NON-stackable item can be selected and removed by its metadata", function()
	-- This is the bug the suite caught: `canStack` is always false for a
	-- non-stackable item, so using it to SELECT made swords unremovable — you
	-- could put one in and never take it out.
	local inv = Inventory.new()
	inv:add("SWORD_IRON", 1, { durability = 50 })
	inv:add("SWORD_IRON", 1, { durability = 90 })

	local i = inv:findStack("SWORD_IRON", { durability = 90 })
	assert(i == 2, "the durability-90 sword is in slot 2, got " .. tostring(i))
	assert(inv:count("SWORD_IRON", { durability = 90 }) == 1, "exactly one sword matches")

	local quitados = inv:remove("SWORD_IRON", 1, { durability = 90 })
	assert(quitados == 1, "the sword must come out")
	assert(inv:count("SWORD_IRON") == 1, "the other sword stays")
	assert(inv.slots[2] == nil and inv.slots[1] ~= nil, "the right slot was emptied")

	-- And a selection that matches nothing must not touch anything.
	local antes = inv:count("SWORD_IRON")
	inv:remove("SWORD_IRON", 1, { durability = 12345 })
	assert(inv:count("SWORD_IRON") == antes, "a non-matching selection removes nothing")
end)

-- ============================================================
-- Reading
-- ============================================================

T("findStack locates a matching stack and returns nil otherwise", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	local i, stack = inv:findStack("POTION_HEALTH", { quality = "common" })
	assert(i == 1 and stack.quantity == 3, "the matching stack is in slot 1")
	local j = inv:findStack("POTION_HEALTH", { quality = "rare" })
	assert(j == nil, "a non-matching quality must not match")
end)

T("the size counters agree with each other", function()
	local inv = Inventory.new(nil, 4)
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	assert(inv:getUsedSlots() == 1 and inv:getFreeSlots() == 3, "1 used, 3 free")
	assert(inv:isFull() == false, "not full yet")
	inv:add("SWORD_IRON", 1, { durability = 1 })
	inv:add("SWORD_IRON", 1, { durability = 2 })
	inv:add("SWORD_IRON", 1, { durability = 3 })
	assert(inv:isFull() == true, "four items in four slots must read as full")
end)

-- ============================================================
-- Moving
-- ============================================================

T("moving onto an occupied slot swaps them", function()
	local inv = Inventory.new()
	inv:add("POTION_HEALTH", 3, { quality = "common" })
	inv:add("SWORD_IRON", 1, { durability = 50 })
	assert(inv.slots[1].itemId == "POTION_HEALTH", "potion is in slot 1 first")
	local ok = inv:moveSlot(1, 2)
	assert(ok == true, "the move should succeed")
	assert(inv.slots[1].itemId == "SWORD_IRON", "the sword took slot 1")
	assert(inv.slots[2].itemId == "POTION_HEALTH", "the potion took slot 2")
end)

T("moving an empty slot fails, and out of range is refused", function()
	local inv = Inventory.new(nil, 3)
	assert(select(2, inv:moveSlot(1, 2)) == "empty_source", "nothing to move")
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	assert(select(2, inv:moveSlot(1, 99)) == "out_of_range", "slot 99 does not exist")
end)

-- ============================================================
-- Resizing
-- ============================================================

T("shrinking that would cut off the EQUIPPED slot is refused", function()
	-- This test failed before the add() id-guard was fixed, and for an instructive reason:
	-- the bug folded all three items into two slots, so shrinking to 2 "worked". It was
	-- passing on broken behaviour. The real contract is a refusal.
	local inv = Inventory.new(nil, 5)
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	inv:add("SWORD_IRON", 1, { durability = 5 })
	inv:add("SCRAP_METAL", 1)
	assert(inv:getUsedSlots() == 3, "three items, three slots")
	inv:equip(3)
	assert(inv:getEquipped() == 3, "equipped in slot 3")

	local ok, motivo = inv:setMaxSlots(2)
	assert(ok == false and motivo == "slots_occupied", "cutting off slot 3 must be refused")
	assert(inv.maxSlots == 5, "and a refused resize changes nothing")
	assert(inv:getEquipped() == 3, "with the equipment still in place")

	assert(inv:setMaxSlots(3) == true, "shrinking to exactly the last used slot is fine")
	assert(inv:getEquipped() == 3, "and the equipped slot survives")
end)

T("growing always works; shrinking refuses when it would cut items off", function()
	local inv = Inventory.new(nil, 3)
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	inv:add("SWORD_IRON", 1, { durability = 5 })
	assert(inv:setMaxSlots(6) == true, "growing is always fine")
	local ok, motivo = inv:setMaxSlots(1)
	assert(
		ok == false and motivo == "slots_occupied",
		"slot 2 is in use, so shrinking to 1 must fail"
	)
	assert(inv.maxSlots == 6, "a refused resize must change nothing")
	assert(inv:setMaxSlots(2) == true, "shrinking to 2 is fine, both slots are used")
	assert(inv:setMaxSlots(Config.ABS_MAX_SLOTS + 1) == false, "above the ceiling must fail")
end)

-- ============================================================
-- Equipping
-- ============================================================

T("equipping records the slot, and it follows the stack when moved", function()
	local inv = Inventory.new()
	inv:add("SWORD_IRON", 1, { durability = 50 })
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	assert(inv:equip(1) == true, "equipping a filled slot works")
	local i, stack = inv:getEquipped()
	assert(i == 1 and stack.itemId == "SWORD_IRON", "slot 1 is what is equipped")
	inv:moveSlot(1, 2)
	assert(inv:getEquipped() == 2, "after swapping, the sword is equipped in slot 2")
	assert(inv:equip(5) == false, "an empty slot cannot be equipped")
	assert(select(2, inv:equip(5)) == "empty_slot", "and the reason says so")
end)

T("removing the equipped stack unequips it", function()
	local inv = Inventory.new()
	inv:add("SWORD_IRON", 1, { durability = 50 })
	inv:equip(1)
	inv:remove("SWORD_IRON", 1, { durability = 50 })
	assert(inv:getEquipped() == nil, "the sword is gone, so nothing is equipped")
	assert(inv:getUsedSlots() == 0, "and the slot was released")
end)

-- ============================================================
-- Serialisation
-- ============================================================

T("a save and a load round-trip everything", function()
	local inv = Inventory.new(nil, 8)
	inv:add("POTION_HEALTH", 7, { quality = "rare" })
	inv:add("SWORD_IRON", 1, { durability = 42 })
	inv:equip(2)

	local cargado, motivo = Inventory.fromSave(inv:toSave(), nil)
	assert(motivo == nil, "a clean load must report no reason, got " .. tostring(motivo))
	assert(cargado.maxSlots == 8, "the size survives")
	assert(cargado.slots[1].quantity == 7, "the quantity survives")
	assert(cargado.slots[1].metadata.quality == "rare", "the metadata survives")
	assert(cargado.slots[2].metadata.durability == 42, "including on a different item")
	assert(cargado:getEquipped() == 2, "the equipped slot survives")
	assert(cargado:isDirty() == false, "a loaded inventory matches the disc, so it is not dirty")
end)

T("a corrupt payload yields a fresh inventory, with a reason", function()
	for _, malo in ipairs({ nil, 42, "texto", {}, { schemaVersion = "uno" } }) do
		local inv, motivo = Inventory.fromSave(malo, nil)
		assert(inv ~= nil, "a load must always return an inventory, never nil")
		assert(inv:getUsedSlots() == 0, "a corrupt load must not invent items")
		assert(motivo == "corrupt_payload", "expected corrupt_payload, got " .. tostring(motivo))
	end
end)

T("a save from a FUTURE schema is refused rather than guessed at", function()
	local inv, motivo = Inventory.fromSave({
		schemaVersion = Config.SCHEMA_VERSION + 1,
		maxSlots = 20,
		slots = { { itemId = "POTION_HEALTH", quantity = 3 } },
	}, nil)
	assert(motivo == "future_schema", "expected future_schema, got " .. tostring(motivo))
	assert(inv:getUsedSlots() == 0, "guessing at an unknown shape would lose items")
end)

T("an item that no longer exists in the catalogue is dropped and counted", function()
	local inv, motivo = Inventory.fromSave({
		schemaVersion = Config.SCHEMA_VERSION,
		maxSlots = 20,
		slots = {
			{ itemId = "POTION_HEALTH", quantity = 3, metadata = { quality = "common" } },
			{ itemId = "ITEM_RETIRADO_HACE_ANOS", quantity = 99 },
		},
	}, nil)
	assert(inv:getUsedSlots() == 1, "only the item that still exists survives")
	assert(inv.slots[1].itemId == "POTION_HEALTH", "and it is the right one")
	assert(motivo == "dropped_stacks:1", "expected dropped_stacks:1, got " .. tostring(motivo))
end)

T("a stored size that is not a sane number falls back to the default", function()
	-- fromSave is the last line of defence: it receives data off a disc and it
	-- must never throw, whatever is in there.
	for _, malo in ipairs({ "muchos", 0, -3, 2.5, 999999 }) do
		local inv, _ = Inventory.fromSave({
			schemaVersion = Config.SCHEMA_VERSION,
			maxSlots = malo,
			slots = {
				{ itemId = "POTION_HEALTH", quantity = 2, metadata = { quality = "common" } },
			},
		}, nil)
		assert(
			inv.maxSlots == Config.DEFAULT_MAX_SLOTS,
			"expected the default for maxSlots=" .. tostring(malo)
		)
		assert(inv:getUsedSlots() == 1, "the valid stack should still load")
	end
end)

T("stored metadata that is not a table is ignored, not fatal", function()
	local inv, motivo = Inventory.fromSave({
		schemaVersion = Config.SCHEMA_VERSION,
		maxSlots = 20,
		slots = { { itemId = "POTION_HEALTH", quantity = 2, metadata = "esto no es una tabla" } },
	}, nil)
	assert(inv:getUsedSlots() == 1, "the stack loads, without its nonsense metadata")
	assert(inv.slots[1].metadata == nil, "and the metadata ends up empty")
	assert(motivo == nil, "an unusable metadata field is not worth a reason of its own")
end)

T("a stored equipped index pointing at an empty slot is discarded", function()
	-- Corrupt or stale data: the index says slot 4, slot 4 holds nothing.
	local inv, motivo = Inventory.fromSave({
		schemaVersion = Config.SCHEMA_VERSION,
		maxSlots = 20,
		slots = { { itemId = "POTION_HEALTH", quantity = 2, metadata = { quality = "common" } } },
		equipped = 4,
	}, nil)
	assert(inv:getEquipped() == nil, "an equipped index with nothing under it must not survive")
	assert(
		motivo == "dropped_stacks:1",
		"and it counts as something discarded, got " .. tostring(motivo)
	)
end)

T("a stored quantity above the cap is capped, not dropped", function()
	local inv = Inventory.fromSave({
		schemaVersion = Config.SCHEMA_VERSION,
		maxSlots = 20,
		slots = { { itemId = "SWORD_IRON", quantity = 50 } },
	}, nil)
	assert(inv.slots[1].quantity == 1, "a sword caps at 1, and is kept")
end)

-- ============================================================
-- Observers
-- ============================================================

T("revision bumps on a real change and not on a refused one", function()
	local inv = Inventory.new(nil, 1)
	local antes = inv:getRevision()
	inv:add("POTION_HEALTH", 1, { quality = "common" })
	assert(inv:getRevision() > antes, "a successful change must bump the revision")
	local tras = inv:getRevision()
	inv:remove("POTION_HEALTH", 99, { quality = "common" }) -- more than is held
	assert(inv:getRevision() == tras, "a refused removal must not bump anything")
	inv:add("ITEM_INEXISTENTE", 1) -- rejected outright
	assert(inv:getRevision() == tras, "a rejected add must not bump anything")
	assert(inv:isDirty() == true, "changes leave the inventory dirty")
	inv:markClean()
	assert(inv:isDirty() == false, "markClean clears it")
end)

return T.report()
