-- DataStoreAdapter — the ONLY file in the kit that touches DataStoreService.

-- It exists so DataManager does not have to. Everything that needs Roblox (and
-- therefore cannot be tested in a terminal) is in this one place, behind the
-- three-method interface DataManager actually uses.

-- No SetAsync. The lock is a read-modify-write, and a plain write there is a race
-- that ends with two servers both convinced they own the same player.

local DataStoreService = game:GetService("DataStoreService")

local DataStoreAdapter = {}

function DataStoreAdapter.new(
	nombre: string
): { get: (string) -> any, update: (string, (any) -> any) -> any }
	local store = DataStoreService:GetDataStore(nombre)
	return {
		get = function(key: string)
			return store:GetAsync(key)
		end,
		update = function(key: string, transform: (any) -> any)
			-- UpdateAsync re-reads and retries internally if someone else wrote
			-- first. That is the whole reason the lock is safe.
			return store:UpdateAsync(key, transform)
		end,
	}
end

return DataStoreAdapter
