--!strict
-- ItemDefinition — what an item is, and when two of them are the same stack.
--
-- Two jobs that look like one. exists/stackable/maxStack is one; canStack is the
-- other. matches() further down exists precisely because I ran them together once
-- and made non-stackable items impossible to remove.
--
-- Stacking compares ONLY the keys named in stackableMetadata. Everything else in
-- the metadata is ignored on purpose.
--
-- The catalogue is injected with init(), not required. That is not a style choice:
-- it lets a consumer plug in their own items, and it lets this file run outside
-- Roblox so the rules can be tested. Nothing here requires anything, which is also
-- what makes loadstring(mod.Source) work when Studio serves a stale require.

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

-- warn is a Roblox global and does not exist outside Roblox. Calling it directly
-- works in Studio and dies under test — so route it through here.
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

-- Returns findings split by severity, and the split is the point.
-- Errors = data that cannot be trusted, the caller decides what to do.
-- Warnings = legal but worth confirming (an item that merges with anything might be
-- intentional). One mixed list forces the reader to ignore all of it, because a
-- deliberate choice then hides a real fault behind it.
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

-- Wires the catalogue in. Warnings are printed, errors are returned — stopping a
-- boot over a suspicious-but-legal entry would be wrong.
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

-- The heart of it. Both sides must be the same id, the definition must be
-- stackable, and every key in stackableMetadata must be equal on both sides.
-- Comparison is ==, so keep metadata values primitive: two tables with identical
-- contents are NOT equal in Luau and would silently never stack.
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

-- SELECTION, not stacking. Not a nitpick — this exists because of a bug.
--
-- canStack answers "would these merge?", which is ALWAYS false for a non-stackable
-- item. Use it to answer "is this the stack I want?" and a sword becomes
-- impossible to remove: it goes in and never comes out, reporting not_enough.
--
-- matches ignores stackability entirely. Use it for findStack / count / remove.
function ItemDefinition.matches(
	itemId: string,
	stackMetadata: ItemMetadata?,
	wantedMetadata: ItemMetadata?
): boolean
	if ItemDefinition.get(itemId) == nil then
		return false
	end
	if wantedMetadata == nil then
		return true -- no selection means "any stack of this item"
	end

	local stack = stackMetadata or {}
	for key, value in pairs(wantedMetadata) do
		if stack[key] ~= value then
			return false
		end
	end
	return true
end

-- A stack's identity as a string: the id plus only the metadata that matters,
-- key-sorted so writing the same metadata in a different order cannot produce a
-- different key. Inventory indexes on this, so a lookup is a table hit, not a scan.
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
