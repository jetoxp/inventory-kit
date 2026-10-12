--!strict
--[[
	ItemDefinition.luau — what an item IS, and when two of them stack.

	WHY THIS EXISTS
	Two different jobs:

	  1. Answer questions about an item kind: does it exist, is it stackable,
	     how many fit in a slot.
	  2. Decide whether two concrete items are THE SAME STACK — which is not
	     the same question, and is where naive inventories go wrong.

	THE RULE
	Stacking compares only the metadata keys named in `stackableMetadata`.
	Keys outside that list are ignored on purpose: otherwise two potions of
	identical quality would refuse to merge just because they were looted a
	second apart. `stackable = false` never merges, whatever the metadata.

	WHY THE CATALOG IS INJECTED, NOT REQUIRED
	`init()` receives the catalog. A consumer plugs in their own item list
	without editing a line of kit code — that is what "reusable" means. And a
	module that requires nothing can be executed outside Roblox, so the
	stacking rules are covered by automated tests instead of by hope.
	Querying before init() raises loudly rather than returning a plausible
	false. `init` is defined AFTER `validate` because it calls it: in Luau a
	`local function` only sees what was declared above it.

	WHAT THIS MODULE DOES NOT DO
	It reads the catalog. It never mutates it and holds no player data.
]]

export type ItemDef = {
	id: string,
	displayName: string,
	stackable: boolean,
	stackableMetadata: { string },
	maxStack: number,
}

export type ItemMetadata = { [string]: any }

local ItemDefinition = {}

-- Injected catalog, keyed by item id. nil until init() runs.
local catalog: { [string]: ItemDef }? = nil

--[[
	Emits a message that the author should read but that must not stop anything.

	`warn` is a Roblox global; it does not exist outside Roblox, and this kit is
	meant to be runnable in a plain Luau interpreter so its rules can be tested.
	Calling `warn` directly would work in Studio and blow up under test.
]]
local function log(msg: string): ()
	if warn then
		warn(msg)
	else
		print(msg)
	end
end

-- Fails loudly: a silent nil would surface later as "my items do not stack"
-- and cost an afternoon of hunting.
local function requireCatalog(): { [string]: ItemDef }
	local c = catalog
	if not c then
		error("[ItemDefinition] init() was never called. Inject the catalog first.", 3)
	end
	return c
end

--[[
	Checks the injected catalog and returns findings SPLIT BY SEVERITY.

	Errors are faults: data that cannot be trusted (a bad maxStack, a declared
	id that does not match its key, a missing displayName).
	Warnings are legal but suspicious: something that may well be intentional
	and should be confirmed rather than blocked.

	Keeping them apart matters: a single mixed list forces the reader to ignore
	the whole output, because one deliberate choice would hide a real fault.
]]
function ItemDefinition.validate(): ({ string }, { string })
	local errores: { string } = {}
	local avisos: { string } = {}
	local c = catalog
	if not c then
		table.insert(errores, "catalog is nil")
		return errores, avisos
	end

	for id, def in pairs(c) do
		if type(id) ~= "string" or id == "" then
			table.insert(errores, "an entry has an empty id")
			continue
		end
		if def.id ~= id then
			table.insert(errores, string.format("'%s' declares id '%s'", id, tostring(def.id)))
		end
		if type(def.displayName) ~= "string" or def.displayName == "" then
			table.insert(errores, string.format("'%s' has no displayName", id))
		end
		if type(def.stackable) ~= "boolean" then
			table.insert(errores, string.format("'%s' has a non-boolean stackable", id))
		end
		if type(def.maxStack) ~= "number" or def.maxStack < 1 then
			table.insert(
				errores,
				string.format("'%s' has maxStack %s (must be >= 1)", id, tostring(def.maxStack))
			)
		end
		if type(def.stackableMetadata) ~= "table" then
			table.insert(errores, string.format("'%s' has no stackableMetadata list", id))
		elseif def.stackable and #def.stackableMetadata == 0 then
			-- Legal: a plain material really does merge with itself. Worth
			-- saying out loud so it is a decision and not an oversight.
			table.insert(
				avisos,
				string.format(
					"'%s' is stackable but compares no metadata (it will merge all instances)",
					id
				)
			)
		end
	end

	return errores, avisos
end

--[[
	Wires up the catalog. Returns (errors, warnings) so the caller decides what
	to do about errors; warnings are printed here because they are informational
	and stopping a boot over one would be wrong.
]]
function ItemDefinition.init(source: { [string]: ItemDef }): ({ string }, { string })
	catalog = source
	local errores, avisos = ItemDefinition.validate()
	for _, aviso in ipairs(avisos) do
		log("[ItemDefinition] " .. aviso)
	end
	return errores, avisos
end

-- True once init() has been called.
function ItemDefinition.isReady(): boolean
	return catalog ~= nil
end

-- The definition for an id, or nil when the id is unknown.
function ItemDefinition.get(id: string): ItemDef?
	return requireCatalog()[id]
end

-- Whether an id is a real item. Callers use this before trusting anything
-- that arrived over a remote.
function ItemDefinition.exists(id: string): boolean
	return requireCatalog()[id] ~= nil
end

--[[
	The heart of the kit.

	Both sides must reference the SAME id (stacking across kinds is never
	valid), the definition must be stackable, and every key named in
	stackableMetadata must be present and equal on both sides.

	Values compare with ==, so metadata values should be primitives — numbers,
	strings, booleans. Two tables with identical contents are NOT equal in
	Luau and would silently never stack.
]]
function ItemDefinition.canStack(
	itemIdA: string,
	metadataA: ItemMetadata?,
	itemIdB: string,
	metadataB: ItemMetadata?
): boolean
	if itemIdA ~= itemIdB then
		return false
	end

	local def = ItemDefinition.get(itemIdA)
	if not def or not def.stackable then
		return false
	end

	local a = metadataA or {}
	local b = metadataB or {}

	for _, key in ipairs(def.stackableMetadata) do
		if a[key] ~= b[key] then
			return false
		end
	end

	return true
end

--[[
	A canonical string identifying a stack: the item id plus only the metadata
	the definition says matters, with keys SORTED so that writing the same
	metadata in a different order cannot produce a different key.

	Inventory uses this as a lookup key, so finding an existing stack is one
	table lookup instead of a scan. Returns nil for unknown ids, which callers
	treat as "reject this item".
]]
function ItemDefinition.stackKey(itemId: string, metadata: ItemMetadata?): string?
	local def = ItemDefinition.get(itemId)
	if not def then
		return nil
	end

	if not def.stackable then
		-- Non-stackable items never share a slot, so the key only has to be
		-- unique per id; the Inventory keeps them apart by slot, not by key.
		return itemId .. "|unique"
	end

	local meta = metadata or {}
	local keys = table.clone(def.stackableMetadata)
	table.sort(keys) -- stable order, or {a,b} and {b,a} would differ

	local partes = {}
	for _, key in ipairs(keys) do
		table.insert(partes, string.format("%s=%s", key, tostring(meta[key])))
	end

	return string.format("%s|%s", itemId, table.concat(partes, "&"))
end

return ItemDefinition
