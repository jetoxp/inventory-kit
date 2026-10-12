-- InventoryClient — renders nothing yet; it just holds the server's truth.

-- Phase 5 puts the UI on top of this. The contract is already the important part:
-- the client asks, and waits, and never decides. Everything it displays arrives
-- from the server, and a client that has not received anything yet displays
-- nothing rather than guessing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("InventoryKit")
local Net = require(Kit.Net)

local uplink, downlink = Net.client()

-- Last known truth. Left nil until the server says something, on purpose: an
-- empty table would read as "no items" and a UI would happily render that lie.
local estado: { [string]: any }? = nil

downlink.OnClientEvent:Connect(function(nuevo: { [string]: any })
	local revisionAntes = if estado then estado.revision else -1
	estado = nuevo
	print(
		string.format(
			"[InventoryClient] state rev %d -> %d, %d slots, %d in use",
			revisionAntes,
			nuevo.revision,
			nuevo.maxSlots,
			#nuevo.slots
		)
	)
end)

-- Ask once on join. After that the server pushes whenever it changes anything,
-- so there is nothing to poll.
uplink:FireServer({ action = "requestState" })
