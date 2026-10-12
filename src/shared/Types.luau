--!strict
-- Types — the shared vocabulary. Declarations only, no state, no requires.
-- Each module also declares the types it uses locally: that keeps every file
-- loadable on its own (see the note in Inventory about loadstring).

-- ---------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------

-- An item KIND, not an instance of one. stackableMetadata is the field that
-- matters: it names which keys must match for two of these to stack. Keys not
-- listed are ignored for stacking — otherwise two potions of equal quality would
-- refuse to merge for differing in when they were looted.
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

-- One stack: a quantity plus the metadata its whole quantity shares.
-- This is what gets serialised, so keep it flat — primitives only.
export type ItemStack = {
	itemId: string,
	quantity: number,
	metadata: ItemMetadata?,
}

-- ---------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------

-- Sparse: nil is an empty slot. Moving a stack is then one assignment instead of
-- a shuffle, and an empty inventory costs nothing to store.
export type ItemSlot = ItemStack?

-- Player, Model, or nil for a throwaway (shop, loot roll, test).
-- Whether it gets persisted is a policy call — DataManager inspects this, the
-- Inventory never asks.
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

-- A claim, not a boolean. That is the whole point: it carries who holds it and
-- when they last said so, which is what makes a dead session recoverable.
export type SessionLock = {
	sessionId: string,
	placeId: number,
	lastHeartbeat: number,
}

return {}
