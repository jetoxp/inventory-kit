--!strict
-- Inventory — a container of stacks. Works for a player, a chest, or nothing.
--
-- No Roblox in here: no DataStore, no remotes, no UI, not even a Player check.
-- That is what lets the whole class run in a plain Luau interpreter and be tested.
--
-- owner is Player | Model | nil. Whether it gets saved is DataManager's problem —
-- this class never asks.
--
-- Slots are sparse (nil = empty) so moving a stack is one assignment.
--
-- Order matters in this file: helpers are declared before their first caller, and
-- the metatable is attached before the constructor can run. A `local function` binds
-- at its declaration line, so a helper used above its definition is nil at runtime.
-- Been bitten by that one already.

export type ItemStack = {
	itemId: string,
	quantity: number,
	metadata: { [string]: any }?,
}

export type ItemSlot = ItemStack?

-- Player, Model, or nil for a transient inventory.
export type Owner = any

export type Dependencies = {
	itemDefinition: any,
	config: any,
	catalog: any,
}

local Inventory = {}
Inventory.__index = Inventory

-- Injected at init(). Held as locals so the hot paths do not index a table.
local ItemDefinition: any = nil
local Config: any = nil

-- ============================================================
-- Wiring
-- ============================================================

-- Called once by the bootstrap, before any inventory exists. Returns the
-- catalogue errors so whoever is booting sees them, not a player later on.
function Inventory.init(deps: Dependencies): { string }
	assert(deps, "Inventory.init requires a dependencies table")
	assert(deps.itemDefinition, "Inventory.init requires `itemDefinition`")
	assert(deps.config, "Inventory.init requires `config`")
	assert(deps.catalog, "Inventory.init requires `catalog`")

	ItemDefinition = deps.itemDefinition
	Config = deps.config
	ItemDefinition.init(deps.catalog)

	local errores, _avisos = ItemDefinition.validate()
	return errores or {}
end

-- Guards every public entry point. A silent nil here would surface as "my
-- items vanish" much later.
local function assertReady(): ()
	if not ItemDefinition or not Config then
		error("[Inventory] init() was never called. Inject the dependencies first.", 3)
	end
end

-- ============================================================
-- Internal helpers (declared before anything that calls them)
-- ============================================================

-- The lowest empty slot number, or nil when the inventory is full.
local function firstFreeSlot(self): number?
	for i = 1, self.maxSlots do
		if self.slots[i] == nil then
			return i
		end
	end
	return nil
end

-- Highest slot number currently holding something. nil when empty.
local function highestUsedSlot(self): number?
	local mayor = nil
	for i in pairs(self.slots) do
		if mayor == nil or i > mayor then
			mayor = i
		end
	end
	return mayor
end

-- Marks the state as changed since the last save and tells observers to
-- re-read. Bumping a counter is the cheapest correct answer to "what changed?"
local function touch(self): ()
	self.dirty = true
	self.revision += 1
end

-- Copy on the way out. A shared metadata table between two stacks means changing
-- one silently alters the other's stack key.
local function copyStack(stack: ItemSlot): ItemSlot
	if not stack then
		return nil
	end
	local meta = nil
	if stack.metadata then
		meta = table.clone(stack.metadata)
	end
	return { itemId = stack.itemId, quantity = stack.quantity, metadata = meta }
end

-- ============================================================
-- Constructor
-- ============================================================

-- maxSlots falls back to Config.DEFAULT_MAX_SLOTS and is validated HERE, not in
-- setMaxSlots, so an inventory can never exist at an impossible size.
function Inventory.new(owner: Owner?, maxSlots: number?): any
	assertReady()

	local tamano = maxSlots or Config.DEFAULT_MAX_SLOTS
	assert(type(tamano) == "number" and tamano >= 1, "maxSlots must be a positive number")
	assert(
		tamano <= Config.ABS_MAX_SLOTS,
		string.format("maxSlots cannot exceed %d", Config.ABS_MAX_SLOTS)
	)

	local self = setmetatable({}, Inventory)
	self.owner = owner
	self.maxSlots = tamano
	self.slots = {} -- sparse: nil is an empty slot
	self.equipped = nil -- slot index of the equipped stack, if any
	self.dirty = false -- nothing to save until something changes
	self.revision = 0 -- bumped on every mutation, for observers
	return self
end

-- ============================================================
-- Reading
-- ============================================================

-- First slot whose stack would merge with this item, or nil.
--
-- "Would merge" is asked of ItemDefinition, never guessed here — this class does
-- not decide what makes two items the same, it asks. Note it uses matches(), not
-- canStack(): a non-stackable item still has to be findable.
function Inventory:findStack(itemId: string, metadata: { [string]: any }?): (number?, ItemSlot)
	for i = 1, self.maxSlots do
		local stack = self.slots[i]
		if
			stack
			and stack.itemId == itemId
			and ItemDefinition.matches(itemId, stack.metadata, metadata)
		then
			return i, stack
		end
	end
	return nil, nil
end

-- How many of this item are held, counting every stack that matches.
function Inventory:count(itemId: string, metadata: { [string]: any }?): number
	local total = 0
	for i = 1, self.maxSlots do
		local stack = self.slots[i]
		if stack and stack.itemId == itemId then
			if ItemDefinition.matches(itemId, stack.metadata, metadata) then
				total += stack.quantity
			end
		end
	end
	return total
end

function Inventory:getSlot(index: number): ItemSlot
	return copyStack(self.slots[index])
end

-- A defensive copy of the whole slot array. Callers cannot mutate our state.
function Inventory:getSlots(): { ItemSlot }
	local copia = {}
	for i = 1, self.maxSlots do
		copia[i] = copyStack(self.slots[i])
	end
	return copia
end

function Inventory:getUsedSlots(): number
	local n = 0
	for i = 1, self.maxSlots do
		if self.slots[i] then
			n += 1
		end
	end
	return n
end

function Inventory:getFreeSlots(): number
	return self.maxSlots - self:getUsedSlots()
end

function Inventory:isFull(): boolean
	return firstFreeSlot(self) == nil
end

-- ============================================================
-- Adding
-- ============================================================

-- add -> (added, reason)
--
-- Top up existing stacks first, then open new slots. If it fills up midway, stop
-- and report what DID fit: this is the one operation that is deliberately NOT
-- atomic. 30 scrap into 2 free slots should bank 20, not fail and leave nothing.
--
-- Returns the true number added, and a reason on a shortfall.
function Inventory:add(
	itemId: string,
	quantity: number?,
	metadata: { [string]: any }?
): (number, string?)
	assertReady()
	if quantity == nil then
		quantity = 1
	end

	-- Reject nonsense rather than clamping it: a caller sending -5 or 1.5 has a
	-- bug, and silently "fixing" it hides it.
	if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
		return 0, "invalid_quantity"
	end
	if not ItemDefinition.exists(itemId) then
		return 0, "unknown_item"
	end

	local def = ItemDefinition.get(itemId)
	local restante = quantity
	local metadatos = metadata and table.clone(metadata) or nil

	-- Pass 1: top up stacks that would merge.
	if def.stackable then
		for i = 1, self.maxSlots do
			if restante <= 0 then
				break
			end
			local stack = self.slots[i]
			-- stack.itemId, NOT itemId. canStack() compares two ids and returns false when
			-- they differ, so passing the incoming id twice defeated its own guard: every
			-- stackable item merged into the first stackable stack it met. A piece of scrap
			-- (which compares no metadata, so it matches everything) silently folded into a
			-- potion stack and inflated its count. Only an item-vs-item test catches this;
			-- 96 tests using one item id per inventory never could.
			if
				stack and ItemDefinition.canStack(stack.itemId, stack.metadata, itemId, metadatos)
			then
				local hueco = def.maxStack - stack.quantity
				if hueco > 0 then
					local movidos = math.min(hueco, restante)
					stack.quantity += movidos
					restante -= movidos
				end
			end
		end
	end

	-- Pass 2: spill what is left into empty slots.
	while restante > 0 do
		local libre = firstFreeSlot(self)
		if not libre then
			local puestos = quantity - restante
			if puestos > 0 then
				touch(self)
			end
			return puestos, "inventory_full"
		end
		local movidos = math.min(def.maxStack, restante)
		self.slots[libre] = { itemId = itemId, quantity = movidos, metadata = metadatos }
		restante -= movidos
	end

	touch(self)
	return quantity, nil
end

-- ============================================================
-- Removing
-- ============================================================

-- remove -> (removed, reason)
--
-- ATOMIC, and the exact opposite call from add(): either the whole quantity leaves
-- or nothing does. A partial removal that reports success is how duplication bugs
-- are born — the caller believes 10 left and 3 remain.
--
-- metadata removes only from stacks that match it; nil takes from any stack, in
-- slot order.
function Inventory:remove(
	itemId: string,
	quantity: number?,
	metadata: { [string]: any }?
): (number, string?)
	assertReady()
	if quantity == nil then
		quantity = 1
	end
	if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
		return 0, "invalid_quantity"
	end

	-- Count first: removing half then discovering it is not enough is exactly
	-- the failure this function is written to avoid.
	local disponible = self:count(itemId, metadata)
	if disponible < quantity then
		return 0, "not_enough"
	end

	local restante = quantity
	for i = 1, self.maxSlots do
		if restante <= 0 then
			break
		end
		local stack = self.slots[i]
		if stack and stack.itemId == itemId then
			local coincide = ItemDefinition.matches(itemId, stack.metadata, metadata)
			if coincide then
				local quitados = math.min(stack.quantity, restante)
				stack.quantity -= quitados
				restante -= quitados
				if stack.quantity <= 0 then
					self.slots[i] = nil
					if self.equipped == i then
						self.equipped = nil
					end
				end
			end
		end
	end

	touch(self)
	return quantity, nil
end

-- ============================================================
-- Moving
-- ============================================================

-- Swaps when the destination is occupied — dragging onto an occupied slot should
-- reorder, not fail.
function Inventory:moveSlot(from: number, to: number): (boolean, string?)
	assertReady()
	if type(from) ~= "number" or type(to) ~= "number" then
		return false, "invalid_slot"
	end
	if from < 1 or to < 1 or from > self.maxSlots or to > self.maxSlots then
		return false, "out_of_range"
	end
	if from == to then
		return true, nil
	end
	if self.slots[from] == nil then
		return false, "empty_source"
	end

	self.slots[from], self.slots[to] = self.slots[to], self.slots[from]

	-- The equipped slot follows the stack, or the player would unequip by
	-- dragging an item one slot to the right.
	if self.equipped == from then
		self.equipped = to
	elseif self.equipped == to then
		self.equipped = from
	end

	touch(self)
	return true, nil
end

-- ============================================================
-- Resizing
-- ============================================================

-- Growing is always fine. Shrinking only if it does not cut items off: refusing
-- is better than silently destroying someone's things, and the caller can move them
-- first.
function Inventory:setMaxSlots(n: number): (boolean, string?)
	assertReady()
	if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
		return false, "invalid_size"
	end
	if n > Config.ABS_MAX_SLOTS then
		return false, "too_large"
	end

	local masAlto = highestUsedSlot(self)
	if masAlto and n < masAlto then
		return false, "slots_occupied"
	end

	self.maxSlots = n
	-- Belt and braces, and honestly unreachable: the refusal above means every occupied
	-- slot fits in n, and `equipped` can only ever point at an occupied slot (equip()
	-- requires one, remove() clears the index when a stack empties). Kept because the
	-- invariant is worth stating even when the code path that breaks it cannot happen —
	-- but if you are reading this to understand the resize rules, the refusal is the rule.
	if self.equipped and self.equipped > n then
		self.equipped = nil
	end
	touch(self)
	return true, nil
end

-- ============================================================
-- Equipping
-- ============================================================

-- Only records the decision. Building the Roblox Tool and putting it in the
-- character is the server layer's job — keeping that boundary is what lets this
-- file be tested in a terminal.
function Inventory:equip(index: number): (boolean, string?)
	assertReady()
	if type(index) ~= "number" or self.slots[index] == nil then
		return false, "empty_slot"
	end
	self.equipped = index
	touch(self)
	return true, nil
end

function Inventory:unequip(): (boolean, string?)
	assertReady()
	if self.equipped == nil then
		return false, "nothing_equipped"
	end
	self.equipped = nil
	touch(self)
	return true, nil
end

function Inventory:getEquipped(): (number?, ItemSlot)
	return self.equipped, copyStack(self.slots[self.equipped])
end

-- ============================================================
-- Lifecycle
-- ============================================================

-- Wipes every slot. Used when a save is corrupt and we start over, never as a
-- quiet way to "reset" a player without telling them.
function Inventory:clear(): ()
	assertReady()
	self.slots = {}
	self.equipped = nil
	touch(self)
end

function Inventory:isDirty(): boolean
	return self.dirty
end

function Inventory:markClean(): ()
	self.dirty = false
end

function Inventory:getOwner(): Owner?
	return self.owner
end

function Inventory:getRevision(): number
	return self.revision
end

-- ============================================================
-- Serialisation
-- ============================================================

-- schemaVersion first, so a future loader reads the version before anything it
-- might not understand.
function Inventory:toSave(): { [string]: any }
	assertReady()
	return {
		schemaVersion = Config.SCHEMA_VERSION,
		maxSlots = self.maxSlots,
		slots = self:getSlots(),
		equipped = self.equipped,
		savedAt = os.time(),
	}
end

-- fromSave -> (inventory, reason). NEVER trust the disc.
--
--   not a table           -> fresh inventory, "corrupt_payload"
--   a FUTURE schemaVersion -> refuse, "future_schema". Guessing at a shape you do
--                            not know loses items.
--   older version         -> migrate (v1 is the first, nothing to do yet)
--   unknown item id       -> drop that stack, count it in "dropped_stacks:N".
--                            The catalogue is the truth: an item that no longer
--                            exists cannot be held.
--
-- reason is nil on a clean load, so a caller can spot a repair without inspecting
-- the result. This function must never throw — it is fed data off a disc.
function Inventory.fromSave(payload: any, owner: Owner?): (any, string?)
	assertReady()

	if type(payload) ~= "table" then
		return Inventory.new(owner), "corrupt_payload"
	end

	local version = payload.schemaVersion
	if type(version) ~= "number" then
		return Inventory.new(owner), "corrupt_payload"
	end
	if version > Config.SCHEMA_VERSION then
		return Inventory.new(owner), "future_schema"
	end
	if version < Config.SCHEMA_VERSION then
		-- Hook for migrations. v1 is the first, so there is nothing yet.
		payload = payload
	end

	-- A stored size is data too, and data lies. Anything that is not a sane
	-- number falls back to the configured default rather than raising: this
	-- function is the last line of defence and must not throw.
	local tamano = payload.maxSlots
	if
		type(tamano) ~= "number"
		or tamano < 1
		or tamano % 1 ~= 0
		or tamano > Config.ABS_MAX_SLOTS
	then
		tamano = nil
	end

	local inv = Inventory.new(owner, tamano)
	local descartados = 0

	local slots = payload.slots
	if type(slots) == "table" then
		for i = 1, inv.maxSlots do
			local stack = slots[i]
			if type(stack) == "table" and type(stack.itemId) == "string" then
				local cantidad = stack.quantity
				local valido = type(cantidad) == "number" and cantidad > 0 and cantidad % 1 == 0
				if valido and ItemDefinition.exists(stack.itemId) then
					local def = ItemDefinition.get(stack.itemId)
					if cantidad > def.maxStack then
						cantidad = def.maxStack -- a stored stack over the cap is capped, not dropped
					end
					-- Guarded: table.clone on a non-table raises, and raising
					-- here would take the whole load down with it.
					local meta = nil
					if type(stack.metadata) == "table" then
						meta = table.clone(stack.metadata)
					end
					inv.slots[i] = {
						itemId = stack.itemId,
						quantity = cantidad,
						metadata = meta,
					}
				else
					descartados += 1
				end
			elseif stack ~= nil then
				descartados += 1
			end
		end
	end

	if type(payload.equipped) == "number" and inv.slots[payload.equipped] then
		inv.equipped = payload.equipped
	elseif payload.equipped ~= nil then
		descartados += 1
	end

	-- A freshly loaded inventory is not dirty: it matches the disc.
	inv.dirty = false
	inv.revision = 0

	if descartados > 0 then
		return inv, string.format("dropped_stacks:%d", descartados)
	end
	return inv, nil
end

return Inventory
