# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A client-side Roblox Luau script ("Iamrich") for automated EXP farming, combat movement, player following, party/server hopping, teleports and alerts. It runs either through an executor (`loadstring` + `HttpGet`) or inside Roblox Studio as ModuleScripts. There is no build system, package manager, linter config or test suite. The only way to verify a change is to run it in Studio or an executor. Output goes through `print`/`warn` with `[ModuleName]` prefixes.

## Layout

- `Iamrich.lua` (~9.2k lines) is the entry point and holds most of the logic: startup checks, the mob cache, the `configurations` table, all GUI construction, config persistence, the farm loop, auto-skill, the live UI timer and player alerts/ESP. Sections are marked with `--====` banner comments (`CONFIG`, `GUI`, `FIND TARGET`, `FARM LOOP`, `AUTO FARM / AUTO SKILL`, `PLAYER LIST + FULL-SCREEN ALERTS`, …). Grep for the banners to find your way around.
- The other `*.lua` files are feature modules, one per file: `CombatSystem`, `LocalRoutePlanner`, `WaypointNavigation`, `FollowSystem`, `SafeBoosterResetSystem`, `FPSBoostSystem`, `PartySystem`, `TeleportSystem`.

## Module loading (important when editing modules)

`Iamrich.lua` (around lines 533–690) loads modules in one of two ways:
- **Studio** (`configurations.IsStudio`): `require(script:WaitForChild("<Name>.lua"))`. The ModuleScripts must be children of the main script and keep the `.lua` suffix in their names.
- **Executor**: `game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/<Name>.lua?v=<version>")` followed by `loadstring`. The modules are fetched from GitHub `main`, so changes to a module take effect for executor users only after they are pushed.

When you bump a module's version:
1. Update `local VERSION = "x.y.z"` and the startup `print` line at the top of the module.
2. Update the matching `?v=x.y.z` cache-buster in the URL in `Iamrich.lua`.
3. Bump `Iamrich.lua`'s own `VERSION` (line 1) when the main script changes.

`PartySystem` is a special case: in executor mode, `Iamrich.lua` patches the downloaded source with `source:gsub(...)` before `loadstring` (server-row layout, Info button, a "current server" row). Those patterns match exact text in `PartySystem.lua`. If you edit those lines in `PartySystem.lua`, the patches stop matching without any error. Either keep the targeted text the same, or move the patch into `PartySystem.lua` and remove the `gsub`.

## Module contract

Each module returns a table with `Initialize(configuration, dependencies)`. `LocalRoutePlanner` is the exception: it is stateless and exports `FindRoute(root, goal, raycastParams, options)`.
- `configuration` is the shared `configurations` table from `Iamrich.lua`. Modules read settings from it, call shared helpers such as `configuration.NotifyUser(title, msg, duration)`, and in some cases add functions to it. For example, `CombatSystem` attaches its functions to `configurations.CombatSystem`.
- `dependencies` passes in services and helpers explicitly (`Players`, `MobsFolder`, `RoutePlanner`, `ClaimMovement`/`ReleaseMovement`, `ReplicatedStorage`, …). Prefer adding a dependency here over calling `game:GetService` inside a module.
- Optional modules (LocalRoutePlanner, SafeBoosterReset, Party, Teleport) are loaded and initialized inside `pcall`. When one fails, the script degrades instead of aborting: it falls back to legacy detours or uses a stub `SetEnabled`. Keep any new optional module behind the same pcall + `assert(type(module.Initialize) == "function")` guard.

## Cross-cutting conventions

- **Movement ownership**: only one controller drives `Humanoid:MoveTo` at a time. `ClaimMovement(owner, humanoid, root)` and `ReleaseMovement(...)` (top of `Iamrich.lua`) track a single `MovementOwner`, which is `"Combat"`, `"Waypoint"` or `"Follow"`. New movement code must claim before moving and release when done. Movement deliberately uses raycasts + `MoveTo` + jump recovery, **not** `PathfindingService`.
- **Executor API guards**: always check executor-only functions before calling them (`type(writefile) == "function"`, `readfile`, `makefolder`, `isfolder`, `getgenv`) and skip them in Studio.
- **Game dependencies**: startup aborts if `workspace.Mobs` or the `ReplicatedStorage.InitClashing` RemoteEvent is missing. Other remotes (`TeleportEvent`, `PlayerDamageTags`, …) are looked up lazily and missing ones are handled.
- **Persistence**: `configurations.SaveConfig`/`LoadConfig` write JSON to `Iamrich/<UserId>/Config.json`. On executors without folder APIs they fall back to the flat file `Iamrich_<UserId>.json`. Waypoints are stored per place in `Waypoint_<PlaceId>.json`. The old `EXPPlus_Config.json` is migrated once. When you add a persisted setting, update both the save table and the load path.
- **UI**: everything is built from Roblox Instances (no web UI). Colors come from the `UIColors` tokens in `Iamrich.lua`, and modules that build UI receive a `palette`. Global scaling is applied through `ApplyGuiScale`/`ApplyTextScale`.
- Modules that create workspace objects (such as FollowSystem's target-line folder) name them with the local `UserId` and delete leftovers from earlier runs on init, so the script can be re-executed safely.
