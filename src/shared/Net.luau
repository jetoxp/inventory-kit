-- Net — the only file that knows RemoteEvents exist.

-- Two remotes, not six. Every client request travels as { action = "...", ... }
-- through one uplink, which is exactly why Validate has a table of per-action
-- schemas and dispatches on the action name: one door, many shapes.
--
-- The downlink carries the SERVER'S VIEW of an inventory and nothing else. The
-- client never computes state, it renders what it is told — the difference
-- between a UI that can be wrong and a UI that cannot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

local CARPETA = "InventoryKitNet"
local UPLINK = "IntentFromClient"
local DOWNLINK = "StateToClient"

local function carpeta(): Instance
	local existente = ReplicatedStorage:FindFirstChild(CARPETA)
	if existente then
		return existente
	end
	local nueva = Instance.new("Folder")
	nueva.Name = CARPETA
	nueva.Parent = ReplicatedStorage
	return nueva
end

-- Server side. Creates the remotes if they are not there and returns them.
function Net.server(): (RemoteEvent, RemoteEvent)
	assert(RunService:IsServer(), "Net.server() is server-only")
	local c = carpeta()

	local uplink = c:FindFirstChild(UPLINK) or Instance.new("RemoteEvent")
	uplink.Name = UPLINK
	uplink.Parent = c

	local downlink = c:FindFirstChild(DOWNLINK) or Instance.new("RemoteEvent")
	downlink.Name = DOWNLINK
	downlink.Parent = c

	return uplink, downlink
end

-- Client side. Waits for the server to have made them.
function Net.client(): (RemoteEvent, RemoteEvent)
	assert(RunService:IsClient(), "Net.client() is client-only")
	local c = ReplicatedStorage:WaitForChild(CARPETA, 30)
	assert(c, "the server never created " .. CARPETA)
	return c:WaitForChild(UPLINK) :: RemoteEvent, c:WaitForChild(DOWNLINK) :: RemoteEvent
end

Net.CARPETA = CARPETA

return Net
