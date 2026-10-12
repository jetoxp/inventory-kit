-- ViewModel — turns the server's state into exactly what a slot should display.

-- Pure on purpose. The renderer is Roblox GUI code and cannot be tested off-engine;
-- the decision of what each slot SHOWS can, and that is the part that gets things
-- wrong (an empty slot reading as an item, a quantity on a non-stackable, the
-- equipped flag pointing at the wrong slot). So the decision lives here and the
-- renderer just paints what it is handed.

-- It takes the message table as a parameter instead of requiring Config, so a test
-- can pass its own strings and this file needs nothing at all.

local ViewModel = {}

export type SlotView = {
	index: number,
	empty: boolean,
	itemId: string?,
	quantity: number,
	label: string,
	equipped: boolean,
}

--[[
	build(state, messages) -> { slots, used, maxSlots, revision, title, hint }

	`state` is what the server sent: { revision, maxSlots, slots, equipped }. Every
	field is treated as untrusted, because "the server sent it" is a statement about
	the sender, not about the data — a bug on the server must not crash the UI, and a
	future server sending an extra field must not break an older client.
]]
function ViewModel.build(state: any, messages: { [string]: string }): { [string]: any }
	local slots = {}

	-- An absent state is not an empty inventory: it is "no idea yet", and the caller
	-- renders nothing rather than inventing 20 empty slots.
	if type(state) ~= "table" then
		return {
			ready = false,
			slots = {},
			used = 0,
			maxSlots = 0,
			revision = -1,
			title = messages.uiTitle,
			hint = messages.uiHint,
		}
	end

	local maxSlots = state.maxSlots
	if type(maxSlots) ~= "number" or maxSlots < 1 or maxSlots % 1 ~= 0 then
		maxSlots = 0
	end

	local equipped = if type(state.equipped) == "number" then state.equipped else nil
	local usados = 0

	for i = 1, maxSlots do
		local stack = nil
		if type(state.slots) == "table" then
			stack = state.slots[i]
		end

		-- A stack is only shown if it is actually a stack. A number, a string or a
		-- table missing its itemId is treated as an empty slot rather than rendered
		-- as garbage.
		local valido = type(stack) == "table" and type(stack.itemId) == "string"

		if valido then
			usados += 1
			local cantidad = stack.quantity
			if type(cantidad) ~= "number" or cantidad < 1 then
				cantidad = 1 -- never display "0" or "nil": a slot with items shows at least 1
			end
			table.insert(slots, {
				index = i,
				empty = false,
				itemId = stack.itemId,
				quantity = cantidad,
				-- The id, not a display name: the catalogue is the server's business
				-- and the client is not shipped it. An icon would go here later.
				label = stack.itemId,
				equipped = equipped == i,
			})
		else
			table.insert(slots, {
				index = i,
				empty = true,
				itemId = nil,
				quantity = 0,
				label = messages.uiEmpty,
				equipped = false,
			})
		end
	end

	return {
		ready = true,
		slots = slots,
		used = usados,
		maxSlots = maxSlots,
		revision = if type(state.revision) == "number" then state.revision else -1,
		title = messages.uiTitle,
		hint = messages.uiHint,
		droppable = messages.uiDrop,
		equippedLabel = messages.uiEquipped,
	}
end

return ViewModel
