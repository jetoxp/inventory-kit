-- InventoryService — the server's door for client intent.

-- The order below is the whole security model, and it is not negotiable:
--   1. does this player even have a loaded inventory?
--   2. is the payload well formed?         (Validate)
--   3. are they doing this too fast?       (the rate limiter)
--   4. NOW apply it, to the server's copy
--   5. send back the truth, whether or not anything changed
--
-- Step 5 always runs. The client's view is a projection of the server's state, so
-- the server decides when it is stale — never the client, and never "only when
-- something changed", which would leave a desynced client desynced forever.

local InventoryService = {}

local Validate: any = nil
local Config: any = nil
local DataManager: any = nil
local uplink: RemoteEvent? = nil
local downlink: RemoteEvent? = nil
local limiter: any = nil

-- The snapshot the client is allowed to see. Copies, not references: getSlots()
-- already hands out defensive copies.
local function armarEstado(inv: any): { [string]: any }
	local equipado = inv:getEquipped()
	return {
		revision = inv:getRevision(),
		maxSlots = inv.maxSlots,
		slots = inv:getSlots(),
		equipped = equipado,
	}
end

local function enviarEstado(player: Player): ()
	local inv = DataManager.get(player.UserId)
	if not inv or not downlink then
		return
	end
	downlink:FireClient(player, armarEstado(inv))
end

-- Maps a validated intent onto the server's inventory. Everything here runs on
-- the server's own data; `payload` has already passed Validate.
local function aplicar(inv: any, payload: { [string]: any }): (boolean, string?)
	if payload.action == "move" then
		return inv:moveSlot(payload.from, payload.to)
	elseif payload.action == "equip" then
		return inv:equip(payload.slot)
	elseif payload.action == "unequip" then
		return inv:unequip()
	elseif payload.action == "requestState" then
		return true, nil
	elseif payload.action == "drop" then
		-- Dropping is by slot, because that is what the player clicked. The stack
		-- is read first and used as the selection, so the right one is removed
		-- even when several stacks of the same item share a slot set.
		local stack = inv:getSlot(payload.slot)
		if not stack then
			return false, "empty_slot"
		end
		local quitados, motivo = inv:remove(stack.itemId, payload.quantity, stack.metadata)
		if quitados == 0 then
			return false, motivo
		end
		return true, nil
	end
	return false, "unhandled_action"
end

function InventoryService.start(deps: { [string]: any }): ()
	Validate = deps.validate
	Config = deps.config
	DataManager = deps.dataManager

	uplink, downlink = deps.net.server()
	limiter = Validate.newRateLimiter(Config.REMOTE_COOLDOWNS)

	uplink.OnServerEvent:Connect(function(player: Player, payload: any)
		local inv = DataManager.get(player.UserId)
		if not inv then
			return -- not loaded yet (or kicked soon): silence, not an error
		end

		local ok, motivo = Validate.request(payload, inv.maxSlots)
		if not ok then
			-- The reason is for US. Telling a probing client which field it got
			-- wrong is a free hint, and a real client cannot read this anyway.
			warn(
				string.format(
					"[InventoryService] %s sent an invalid payload: %s",
					player.Name,
					tostring(motivo)
				)
			)
			return
		end

		local permitido = limiter:allow(player.UserId, payload.action, os.clock())
		if not permitido then
			return
		end

		local aplicado, fallo = aplicar(inv, payload)
		if not aplicado then
			warn(
				string.format(
					"[InventoryService] %s: %s refused (%s)",
					player.Name,
					payload.action,
					tostring(fallo)
				)
			)
		end

		enviarEstado(player)
	end)
end

-- Called by the bootstrap when a player leaves, so the limiter does not grow one
-- entry per player per action for the life of the server.
function InventoryService.forgetPlayer(userId: number): ()
	if limiter then
		limiter:forget(userId)
	end
end

function InventoryService.sendState(player: Player): ()
	enviarEstado(player)
end

return InventoryService
