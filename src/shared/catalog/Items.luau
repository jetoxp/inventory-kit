--!strict
-- The catalogue. DATA, not logic — adding an item must never mean editing a system.
--
--   stackable          false -> every instance gets its own slot, always.
--   stackableMetadata  WHICH keys must match to share a stack. Keys not listed
--                      here are ignored for stacking.
--
-- The three below exist to exercise the rules, not to be a game: potions stack by
-- quality only (so two looted a second apart still merge), swords never stack
-- (durability makes each one unique), scrap stacks freely (nothing about it matters).
--
-- [TODO] no icons. A real catalogue wants an asset id per item; the kit does not
-- decide that for you.

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
