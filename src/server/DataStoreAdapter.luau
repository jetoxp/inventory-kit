-- DataStoreAdapter — the ONLY file in the kit that touches DataStoreService.

-- It exists so DataManager does not have to. Everything that needs Roblox (and
-- therefore cannot be tested in a terminal) is in this one place, behind the
-- two-method interface DataManager actually uses.

-- No SetAsync. The lock is a read-modify-write, and a plain write there is a race
-- that ends with two servers both convinced they own the same player.

-- GetDataStore is LAZY, and that is not a micro-optimisation. It does not fail on
-- first use, it fails on the call itself — and it throws in an unpublished place.
-- Calling it at construction killed the whole bootstrap before it could wire
-- anything, so a Studio session got nothing at all instead of a warning. Deferred
-- like this, the throw happens inside DataManager's retry, which pcalls it and
-- reports "store_unavailable" like any other outage.

local DataStoreService = game:GetService("DataStoreService")

local DataStoreAdapter = {}

function DataStoreAdapter.new(
	nombre: string
): { get: (string) -> any, update: (string, (any) -> any) -> any }
	local store = nil

	local function obtenerStore()
		if not store then
			store = DataStoreService:GetDataStore(nombre)
		end
		return store
	end

	-- NOTE the leading `_self`. DataManager calls these with a colon, like the
	-- fake store in the tests does, so the receiver is the first argument. Declared
	-- without it, `key` took the table and the caller's key string landed where
	-- UpdateAsync expects a FUNCTION — "Unable to cast string to Function". No lint
	-- catches this and nothing outside Roblox can run it; only a playtest did.
	return {
		get = function(_self, key: string)
			return obtenerStore():GetAsync(key)
		end,
		update = function(_self, key: string, transform: (any) -> any)
			-- UpdateAsync re-reads and retries internally if someone else wrote
			-- first. That is the whole reason the lock is safe.
			return obtenerStore():UpdateAsync(key, transform)
		end,
	}
end

return DataStoreAdapter
