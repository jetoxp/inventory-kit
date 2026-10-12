--!strict
--[[
	Items.luau — the item catalogue. DATA, not logic.

	WHY THIS EXISTS
	Adding an item should never mean editing a system. Everything the kit needs
	to know about an item lives in this table, so a consumer adds a sword by
	adding a row.

	HOW TO READ A ROW
	  stackable            false -> every instance gets its own slot, always.
	  stackableMetadata    WHICH metadata keys must match to share a stack.
	                       Keys NOT listed here are ignored for stacking.

	THE THREE SAMPLES BELOW EXIST TO EXERCISE THE RULES, not to be a game:
	  - Potions stack by quality only, so two potions of the same quality merge
	    even though they were rolled at different times.
	  - Swords never stack, because durability makes each one unique.
	  - Scrap stacks freely, because nothing about it matters.

	[TODO] Item icons are deliberately absent. A real catalogue wants an
	asset id per item and the kit does not decide that for you.
]]

local Items = {}

Items.POTION_HEALTH = {
	id = "POTION_HEALTH",
	displayName = "Health Potion",
	stackable = true,
	-- Same quality merges. `rolledAt` is NOT here, so it is ignored, which is
	-- exactly why two potions from different loot rolls can share a slot.
	stackableMetadata = { "quality" },
	maxStack = 10,
}

Items.SWORD_IRON = {
	id = "SWORD_IRON",
	displayName = "Iron Sword",
	-- Each sword carries its own durability, so merging two would silently
	-- destroy one of them. Never stackable, and the metadata list is empty
	-- because the `stackable` flag already decided it.
	stackable = false,
	stackableMetadata = {},
	maxStack = 1,
}

Items.SCRAP_METAL = {
	id = "SCRAP_METAL",
	displayName = "Scrap Metal",
	stackable = true,
	-- Nothing about one piece of scrap distinguishes it from another.
	-- An empty list on a stackable item means "merge freely" — validate()
	-- warns about this so it is a choice and not an accident.
	stackableMetadata = {},
	maxStack = 99,
}

return Items
