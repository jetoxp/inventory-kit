# InventoryKit

A modular, server-authoritative inventory system for Roblox. Items with metadata, stacking
that only merges what it should, equipping, and persistence with session locking.

Built as a library a project can drop in: one configuration file, one wiring point, and no
module that requires another. That last property is not a style preference — it is what lets
the core run in a plain Luau interpreter with no Studio, so the rules are covered by an
automated test suite instead of by hope.

## What it is, and what it is not

**Is:** the data model and its rules. Stacking, moving, equipping, saving, loading, and the
server-side validation that keeps a client from inventing items.

**Is not:** a game, a shop, or a finished UI. The renderer that ships here is deliberately
plain — the case study's screenshot is what it looks like — and it exists to prove the loop,
not to be shipped as-is.

## Layout

```
src/shared/     -> ReplicatedStorage.InventoryKit
  Config.luau          every tunable number, plus the text a player reads
  Types.luau           the shared vocabulary
  ItemDefinition.luau  what an item is, and when two of them are the same stack
  Inventory.luau       the container
  DataManager.luau     the lock protocol, retries and autosave (no Roblox inside)
  Validate.luau        per-action payload schemas and the rate limiter
  Net.luau             the two RemoteEvents
  catalog/Items.luau   the item catalogue — data, not code
src/server/     -> ServerScriptService.InventoryServer
  DataStoreAdapter.luau  the ONLY file that touches DataStoreService
  InventoryService.luau  the server's door for client intent
  Bootstrap.server.luau  the wiring
src/client/     -> StarterPlayer.StarterPlayerScripts.InventoryClient
  ViewModel.luau         what each slot should show (pure, tested)
  InventoryUI.luau       the renderer
  InventoryClient.client.luau
```

## Running the tests

No Studio, no dependency manager, nothing to install but the `luau` binary:

```bash
luau tests/run.luau
```

103 tests across 5 suites. The lint and format gates:

```bash
selene src/ tests/      # std = "roblox"
stylua --check src/ tests/
```

## Wiring it up

```lua
local Config = require(kit.Config)
local ItemDefinition = require(kit.ItemDefinition)
local Items = require(kit.catalog.Items)
local Inventory = require(kit.Inventory)

-- The catalogue goes in first: everything else asks it questions.
Inventory.init({ itemDefinition = ItemDefinition, config = Config, catalog = Items })

local inv = Inventory.new(player, 20)
inv:add("POTION_HEALTH", 5, { quality = "common" })
inv:remove("POTION_HEALTH", 2, { quality = "common" })
local n = inv:count("POTION_HEALTH")
```

`Inventory.new(owner, maxSlots)` takes a Player, a Model, or `nil` for a throwaway — a
player's bag and a chest are the same class. Whether it gets saved is `DataManager`'s
decision, not the inventory's.

## Four decisions worth knowing before you read the code

**Stacking compares a declared subset of the metadata.** Each item definition lists which
keys must match. Keys outside that list are ignored — which is why two potions of the same
quality merge even though they were looted a second apart, while two swords with different
durability never do.

**Selection is a different question from stacking, so it is a different function.**
`canStack` asks *"would these merge?"*, and for a non-stackable item that is always false.
Using it to answer *"is this the stack I mean?"* made swords impossible to remove. That is
`matches`.

**The lock is a claim with a timestamp, not a boolean.** A server that dies mid-session
leaves something another server can recover once it goes stale, instead of locking the
account out forever. Data and lock live in one record, written through `UpdateAsync`, so
there is no window where one landed and the other did not.

**The client sends intent, never facts.** Every request passes a per-action schema that
rejects unknown fields, then a per-player, per-action rate limiter, and only then touches
the server's copy. The UI renders what the server pushes.

## Status

Working and tested end to end against a real DataStore: load, claim, heartbeat, save,
release, and the steal-if-stale path.

- `[TODO]` Items have no icon field; the UI shows names.
- `[TODO]` Not measured under real concurrent load (a synthetic 50-session figure is in
  `tests/Bench.luau`, and it is not the same claim).

## Bugs worth knowing about

Two were found by verification rather than by reading, and both are the same shape — a check
that silently stopped checking:

- `keyFor(userId)` ignored its argument, so every player wrote to one DataStore key. The unit
  suite could not see it (each case injected a fresh store, so nothing could collide); the
  linter found it as an *unused parameter*.
- `add()` passed the incoming item id to `canStack()` twice, defeating that function's own
  id guard. Any stackable item merged into the first stackable stack it met — scrap folded
  into a potion stack and inflated its count. The suite could not see it because every case
  used a single item id per inventory. There is now an exhaustive item-vs-item test.

## Licence

MIT — use it, modify it, ship it in a commercial game, keep the copyright notice. Chosen
deliberately over a copyleft licence: a copyleft one would require anyone using this to
publish their whole game, which for Roblox projects means nobody could legally use it at all.
