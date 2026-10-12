--!strict
--[[
	run.luau — runs every suite in the kit.

	Usage (no Studio, no dependencies):
	    luau tests/run.luau

	Exits with a summary. A non-zero count of failed suites is what a CI job
	would watch; here it is what stops a broken change from being called done.
]]

local todas = {}

local function cargar(nombre, ruta)
	local ok, resultado = pcall(function()
		return require(ruta)
	end)
	if not ok then
		print(string.format("  COULD NOT LOAD %s: %s", nombre, tostring(resultado)))
		table.insert(todas, false)
		return
	end
	table.insert(todas, resultado == true)
end

cargar("ItemDefinition", "./ItemDefinitionSpec")
cargar("Inventory", "./InventorySpec")
cargar("DataManager", "./DataManagerSpec")

local bien = 0
for _, ok in ipairs(todas) do
	if ok then
		bien += 1
	end
end

print()
print(string.format("===== TOTAL: %d of %d suites green =====", bien, #todas))
if #todas == 0 then
	print("WARNING: no suites were loaded. That is NOT a pass.")
end
