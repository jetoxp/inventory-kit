--!strict
--[[
	Types.luau — the vocabulary shared by every module in the kit.

	WHY THIS EXISTS
	The kit is meant to be dropped into other projects, so its shapes have to
	be written down somewhere importable. Without this, every module invents
	its own idea of what an "item" is and they stop fitting together.

	WHAT THIS MODULE DOES NOT DO
	It declares shapes only. No state, no logic, no requires.

	NOTE ON `return {}`
	A ModuleScript must return exactly one value. Returning nothing raises at
	require time; returning nil is treated the same way by the engine. An empty
	table is the legal way to say "this module is types only".
]]

-- ---------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------

--[[
	The immutable description of an item kind — "iron sword", not "this
	particular iron sword".

	stackableMetadata is the interesting field: it lists WHICH metadata keys
	must match for two items to stack. Metadata outside this list is ignored
	for stacking purposes, which is what lets two potions of the same quality
	stack even though their roll timestamps differ.
]]
export type ItemDefinition = {
	id: string,
	displayName: string,
	stackable: boolean,
	stackableMetadata: { string },
	maxStack: number,
}

-- Free-form per-item values: durability, quality, rolledAt, enchantments.
-- Values are compared with == for stacking, so keep them primitives —
-- numbers, strings, booleans. Nested tables compare by identity and will
-- silently never match.
export type ItemMetadata = { [string]: any }

--[[
	One stack inside an inventory. A stack is a quantity PLUS the metadata its
	whole quantity shares.

	This is the shape that gets serialised to DataStores, so it is
	deliberately flat and primitive-only.
]]
export type ItemStack = {
	itemId: string,
	quantity: number,
	metadata: ItemMetadata?,
}

-- ---------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------

--[[
	Slots are sparse: a nil hole is an empty slot. Slot numbers are 1-based to
	match Luau's tables, so slot 1 is the player's first slot.

	Why sparse and not a dense list of Optionals: moving a stack between slots
	becomes an assignment instead of a shuffle, and an empty inventory costs
	nothing to store.
]]
export type ItemSlot = ItemStack?

--[[
	Who an inventory belongs to. Deliberately open: a Player, a container
	Model, or nil for a transient inventory (a shop, a loot roll, a test).

	DataManager decides what to persist by inspecting this — it never asks the
	Inventory whether it is persistant, which keeps the class free of policy.
]]
export type InventoryOwner = Player | Model | nil

-- The result of any mutating operation, so callers never have to guess
-- whether something worked or why it did not.
export type InventoryResult = {
	ok: boolean,
	reason: string?,
	moved: number?,
}

-- ---------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------

-- The payload written to a DataStore. schemaVersion is read first on load.
export type SavePayload = {
	schemaVersion: number,
	maxSlots: number,
	slots: { ItemSlot },
	savedAt: number,
}

--[[
	The session lock record.

	It is a claim, not a boolean, and that distinction is the whole point: a
	claim carries who holds it and when they last said so, which is what makes
	it recoverable.
]]
export type SessionLock = {
	sessionId: string,
	placeId: number,
	lastHeartbeat: number,
}

return {}
