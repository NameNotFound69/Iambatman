local VERSION = "2.6.30"
print("[Iamrich] Version " .. VERSION .. " starting...")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")

local Player = Players.LocalPlayer
local MobsFolder = workspace:WaitForChild("Mobs", 10)
if not MobsFolder then
	warn("[Iamrich] Startup stopped: workspace.Mobs was not found.")
	return
end
local MovementBoostSnapshot = { Humanoid = nil, WalkSpeed = nil, Stamina = nil, StaminaValue = nil }

local function RestoreMovementBoost()
	if MovementBoostSnapshot.Humanoid and MovementBoostSnapshot.WalkSpeed then
		pcall(function()
			MovementBoostSnapshot.Humanoid.WalkSpeed = MovementBoostSnapshot.WalkSpeed
		end)
	end
	if MovementBoostSnapshot.Stamina and MovementBoostSnapshot.StaminaValue ~= nil then
		pcall(function()
			MovementBoostSnapshot.Stamina.Value = MovementBoostSnapshot.StaminaValue
		end)
	end
	MovementBoostSnapshot.Humanoid = nil
	MovementBoostSnapshot.WalkSpeed = nil
	MovementBoostSnapshot.Stamina = nil
	MovementBoostSnapshot.StaminaValue = nil
end

local InitClashing = ReplicatedStorage:FindFirstChild("InitClashing", true)
if not InitClashing or not InitClashing:IsA("RemoteEvent") then
	warn("[Iamrich] Startup stopped: ReplicatedStorage.InitClashing RemoteEvent was not found.")
	return
end

--==================================================
-- MOB CACHE + MOVEMENT HELPERS
--==================================================
local RunService = game:GetService("RunService")
local MovementOwner = nil

local function ClaimMovement(owner, humanoid, root)
	if MovementOwner ~= owner then
		if humanoid and root then humanoid:MoveTo(root.Position) end
		MovementOwner = owner
		return true
	end
	return false
end

local function ReleaseMovement(owner, humanoid, root)
	if MovementOwner == owner then
		if humanoid and root then humanoid:MoveTo(root.Position) end
		MovementOwner = nil
	end
end

local MobCache = {
	List = {},
	ByInstance = {},
	Dirty = true,
	LastRebuild = 0,
}
local function MobCache_ClearEntry(mob)
	local entry = MobCache.ByInstance[mob]
	if not entry then return end
	MobCache.ByInstance[mob] = nil
	for i = #MobCache.List, 1, -1 do
		if MobCache.List[i] == entry then
			table.remove(MobCache.List, i)
			break
		end
	end
end

local function MobCache_ReadEntry(mob)
	local cfg = mob:FindFirstChild("Config")
	local exp = cfg and cfg:FindFirstChild("EXP")
	local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") then return nil end
	if humanoid and humanoid.Health <= 0 then return nil end
	return {
		Mob = mob,
		Root = root,
		Humanoid = humanoid,
		Config = cfg,
		EXP = exp,
		HasEXP = exp ~= nil and (exp:IsA("IntValue") or exp:IsA("NumberValue")),
	}
end

local function MobCache_Upsert(mob)
	if not mob or not mob:IsDescendantOf(MobsFolder) then
		MobCache_ClearEntry(mob)
		return
	end
	local fresh = MobCache_ReadEntry(mob)
	if not fresh then
		MobCache_ClearEntry(mob)
		return
	end
	local existing = MobCache.ByInstance[mob]
	if existing then
		existing.Root = fresh.Root
		existing.Humanoid = fresh.Humanoid
		existing.Config = fresh.Config
		existing.EXP = fresh.EXP
		existing.HasEXP = fresh.HasEXP
	else
		MobCache.ByInstance[mob] = fresh
		table.insert(MobCache.List, fresh)
	end
end

local function MobCache_Rebuild(force)
	local now = os.clock()
	if not force and not MobCache.Dirty and (now - MobCache.LastRebuild) < 0.75 then
		return
	end
	table.clear(MobCache.List)
	table.clear(MobCache.ByInstance)
	for _, mob in ipairs(MobsFolder:GetChildren()) do
		local entry = MobCache_ReadEntry(mob)
		if entry then
			MobCache.ByInstance[mob] = entry
			table.insert(MobCache.List, entry)
		end
	end
	MobCache.Dirty = false
	MobCache.LastRebuild = now
end

local function MobCache_MarkDirty()
	MobCache.Dirty = true
end

MobsFolder.ChildAdded:Connect(function(child)
	task.defer(function()
		MobCache_Upsert(child)
	end)
end)
MobsFolder.ChildRemoved:Connect(function(child)
	MobCache_ClearEntry(child)
end)
task.defer(function()
	MobCache_Rebuild(true)
end)

-- Smooth approach helpers (shared by EXP farm + auto attack)
local function FlatUnit(fromPos, toPos, fallback)
	local delta = Vector3.new(fromPos.X - toPos.X, 0, fromPos.Z - toPos.Z)
	if delta.Magnitude < 0.05 then
		if fallback and fallback.Magnitude > 0.05 then
			return fallback.Unit
		end
		return Vector3.new(1, 0, 0)
	end
	return delta.Unit
end

local function SmoothMoveTo(humanoid, root, goal, state, minInterval, stopRadius)
	if not humanoid or not root or not goal then return false end
	local now = os.clock()
	local flat = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
	local dist = flat.Magnitude
	if dist <= (stopRadius or 1.6) then
		if state.Active then
			humanoid:MoveTo(root.Position)
			state.Active = false
			state.Goal = nil
		end
		state.ProgressAt, state.ProgressGoal, state.ProgressDistance = nil, nil, nil
		state.JumpUntil, state.LastJumpAt = 0, 0
		return true
	end
	if not state.Active or not state.ProgressAt or not state.ProgressGoal
		or (state.ProgressGoal - goal).Magnitude > 3 then
		state.ProgressAt = now
		state.ProgressGoal = goal
		state.ProgressDistance = dist
		state.JumpUntil = 0
	elseif now - state.ProgressAt >= 1 then
		local progress = (state.ProgressDistance or dist) - dist
		state.ProgressAt = now
		state.ProgressGoal = goal
		state.ProgressDistance = dist
		if progress < 0.45 and dist > (stopRadius or 1.6) + 2 then
			state.JumpUntil = now + 1.6
		else
			state.JumpUntil = 0
		end
	end
	if now <= (state.JumpUntil or 0) and humanoid.FloorMaterial ~= Enum.Material.Air
		and now - (state.LastJumpAt or 0) >= 0.25 then
		humanoid.Jump = true
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
		state.LastJumpAt = now
	end
	local sameGoal = state.Goal and (state.Goal - goal).Magnitude < 1.25
	local interval = minInterval or 0.22
	if state.Active and sameGoal and (now - (state.LastMoveAt or 0)) < interval then
		return false
	end
	-- Keep current Y so pathing stays grounded and avoids hop jitter.
	local point = Vector3.new(goal.X, root.Position.Y, goal.Z)
	humanoid:MoveTo(point)
	state.Active = true
	state.Goal = goal
	state.LastMoveAt = now
	return false
end

local function OrbitApproachPoint(localRoot, targetRoot, standoff)
	local away = FlatUnit(localRoot.Position, targetRoot.Position, Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z))
	return targetRoot.Position + away * standoff
end

--==================================================
-- CONFIG
--==================================================
local configurations = {}
configurations.IsStudio = RunService:IsStudio()
configurations.Amount = 5000
configurations.MaxDistance = 250
configurations.ExpApproachDistance = 30
configurations.ExpAutoApproachEnabled = false
configurations.Interval = 1
configurations.ExpGoal = 2000000
configurations.AutoExecuteEnabled = true
configurations.AlertsDistance = 1000
configurations.FollowDistance = 8
configurations.FollowTargetVisible = false
configurations.SelectedFollowUserId = nil
configurations.FollowEnabled = false
configurations.PartyFollowEnabled = false
configurations.PartyLeaderUserId = nil
configurations.PartyLeaderName = nil
configurations.PartyResumeFarmOnJoin = false
configurations.FPSBoostEnabled = false
configurations.PlayerPanelMode = "server"
configurations.PlayerPanelTargetUserId = nil
configurations.PlayerPanelCardMode = false
configurations.PlayerPanelSavedSize = nil
configurations.PlayerPanelSavedPosition = nil
configurations.PlayerPanelSavedAnchorPoint = nil
configurations.SelectedCombatMob = nil
configurations.WaypointPosition = nil
configurations.WaypointReturnEnabled = false
configurations.PartyWaypointSuspended = false
configurations.WaypointBillboardEnabled = true
configurations.MovementBoostEnabled = true
configurations.SafeBoosterResetEnabled = false
configurations.AutoAttackEnabled = false
configurations.AutoBossTargetEnabled = false
configurations.AutoMiniBossTargetEnabled = false
configurations.ExpTargetRetaliationEnabled = false
configurations.ExpRetaliationHealthPercent = 95
configurations.ExpHitFeedbackEnabled = true
configurations.ExpHitFeedbackTarget = nil
configurations.ExpRetaliationTarget = nil
configurations.AutoSkillEnabled = false
configurations.AutoAttackRange = 25
configurations.AutoAttackSearchRange = 1000
configurations.AutoAttackInterval = 1
configurations.AutoSkillInterval = 3
configurations.AutoAttackStandoff = 4
configurations.Farming = false
configurations.CurrentTarget = nil
configurations.ExpMaxCombatTarget = nil
configurations.ExpFinishTarget = nil
configurations.ExpLastShotTarget = nil
configurations.SpecialGroupCheckInFlight = {}
configurations.SpecialGroupCheckedUsers = {}
configurations.SpecialGroupCheckFailures = {}
configurations.SpecialGroupThreatUsers = {}
configurations.SpecialGroupHopStarted = false
configurations.SpecialGroupHopAttempts = 0
configurations.ExpHitWatchTarget = nil
configurations.ExpHitWatchHumanoid = nil
configurations.ExpHitWatchHumanoidChildAddedConnection = nil
configurations.ExpHitWatchHumanoidChildRemovedConnection = nil
configurations.ExpHitWatchDamageTag = nil
configurations.ExpHitWatchTagChildAddedConnection = nil
configurations.ExpHitWatchHits = nil
configurations.ExpHitWatchHitsConnection = nil
configurations.ExpHitLastHits = nil
configurations.ExpHitDamageTagWasAdded = false
configurations.ExpRetaliationHealthWatchers = setmetatable({}, { __mode = "k" })
configurations.ExpRetaliationPendingMobWatches = setmetatable({}, { __mode = "k" })
configurations.LastTarget = nil
configurations.TargetStartTime = 0
configurations.AccumulatedTime = 0
configurations.IsPaused = false
configurations.CurrentBillboard = nil
configurations.SessionStartEXP = 0
configurations.SessionStartTime = 0
configurations.RecentCycle = "รอบล่าสุด  -"
configurations.SessionExpGained = 0
configurations.SessionFarmSeconds = 0
configurations.NoProgressCycles = 0
configurations.AutoResumeAfterAlert = true
configurations.EmergencyStopActive = false
configurations.AlertsEnabled = true
configurations.JoinAlertsEnabled = false
configurations.AlertFlashEnabled = true
configurations.AutoBlockEnabled = true
configurations.FinishExpAfterBlockEnabled = false
configurations.AutoBlockPostTarget = nil
configurations.AutoBlockPostUserId = nil
configurations.AlertCombatPending = false
configurations.AlertCombatTarget = nil
configurations.AlertCombatHold = false
configurations.AlertCombatBlockReady = false
configurations.AlertResumeRequired = false
configurations.AlertWasFarming = false
configurations.AlertBlockPromptShown = false
configurations.AlertBlockTarget = nil
configurations.LastAlertCombatUserId = nil
configurations.PendingServerHop = false
configurations.ServerHopKillTarget = nil
configurations.ESPEnabled = true
configurations.ESPLineEnabled = true
configurations.ESPBoxEnabled = true
configurations.AntiAFKEnabled = true
configurations.WhitelistIds = {}
configurations.PinnedPlayerIds = {}
configurations.PlayerESPEnabled = {}
configurations.BlockPromptCache = {}
configurations.SavedMinimized = false
-- Design size in pixels (Fluent-style). Does not stretch with the screen.
-- GuiScale zooms everything; auto-fit only shrinks on tiny viewports.
configurations.MainWidthPx = 520
configurations.MainHeightPx = 560
configurations.MainWidthScale = 0.72  -- legacy
configurations.MainHeightScale = 0.84
configurations.GuiScale = 1.0
configurations.TextScale = 1.0
configurations.PlayerPanelWidthPx = 340
configurations.PlayerPanelHeightPx = 420
configurations.WhitelistPanelWidthPx = 300
configurations.WhitelistPanelHeightPx = 360
configurations.JoinLogWidthPx = 320
configurations.JoinLogHeightPx = 360
configurations.CreditLogWidthPx = 340
configurations.CreditLogHeightPx = 380
configurations.PlayerPanelWidthScale = 0.36
configurations.PlayerPanelHeightScale = 0.60
configurations.WhitelistPanelWidthScale = 0.40
configurations.WhitelistPanelHeightScale = 0.55
configurations.JoinLogWidthScale = 0.38
configurations.JoinLogHeightScale = 0.50
configurations.CreditLogEntries = {}
configurations.CreditLogKnownPlayers = {}
configurations.CreditLogHiddenUsers = {}
configurations.CreditLogTarget = nil
configurations.CreditLogHumanoid = nil
configurations.CreditLogChildAddedConnection = nil
configurations.CreditLogChildRemovedConnection = nil
configurations.CreditLogDirty = true
configurations.CreditLogWidthScale = 0.38
configurations.CreditLogHeightScale = 0.50
configurations.ConfigFileName = ""
configurations.ConfigSaveWarningShown = false
configurations.ConfigRootFolder = "Iamrich"
configurations.ConfigUserFolder = ""
configurations.WaypointConfigFileName = ""
configurations.WaypointConfigVersion = 0
configurations.LegacyConfigFileName = "EXPPlus_Config.json"
configurations.LegacyConfigOwnerFileName = "Iamrich_LegacyConfigOwner.txt"
configurations.MigratedLegacyConfig = false
configurations.IsMinimized = false
configurations.Combat = {}

function configurations.CheckExpRetaliationHealth(mob, currentHealth, previousHealth)
	if not mob or configurations.CurrentTarget ~= mob
		or configurations.ExpLastShotTarget ~= mob
		or not configurations.Farming
		or configurations.EmergencyStopActive
		or not configurations.ExpTargetRetaliationEnabled then
		return false
	end
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then return false end
	currentHealth = tonumber(currentHealth) or humanoid.Health
	if previousHealth ~= nil and currentHealth >= previousHealth then return false end
	if currentHealth <= humanoid.MaxHealth * ((tonumber(configurations.ExpRetaliationHealthPercent) or 95) / 100) then
		configurations.ExpRetaliationTarget = mob
		return true
	end
	return false
end

local function DisconnectExpRetaliationHealthWatch(mob)
	local watch = configurations.ExpRetaliationHealthWatchers[mob]
	if watch then
		if watch.Connection then watch.Connection:Disconnect() end
		if watch.HumanoidChildAddedConnection then watch.HumanoidChildAddedConnection:Disconnect() end
		configurations.ExpRetaliationHealthWatchers[mob] = nil
	end
	configurations.ExpRetaliationPendingMobWatches[mob] = nil
end

local function ConnectExpRetaliationHumanoid(mob, humanoid)
	if not humanoid or not mob:IsDescendantOf(MobsFolder) then return end
	DisconnectExpRetaliationHealthWatch(mob)

	local watch = {
		Humanoid = humanoid,
		LastHealth = humanoid.Health,
	}
	configurations.ExpRetaliationHealthWatchers[mob] = watch
	watch.Connection = humanoid.HealthChanged:Connect(function(currentHealth)
		local previousHealth = watch.LastHealth
		watch.LastHealth = currentHealth
		configurations.CheckExpRetaliationHealth(mob, currentHealth, previousHealth)
	end)
	configurations.CheckExpRetaliationHealth(mob)
end

local function ScheduleExpRetaliationHealthWatch(mob)
	if not mob or not mob:IsA("Model") or not mob:IsDescendantOf(MobsFolder)
		or configurations.ExpRetaliationHealthWatchers[mob]
		or configurations.ExpRetaliationPendingMobWatches[mob] then
		return
	end

	configurations.ExpRetaliationPendingMobWatches[mob] = true
	task.delay(0.25, function()
		configurations.ExpRetaliationPendingMobWatches[mob] = nil
		if not mob:IsDescendantOf(MobsFolder) then return end

		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		if humanoid then
			ConnectExpRetaliationHumanoid(mob, humanoid)
			return
		end

		local watch = {}
		configurations.ExpRetaliationHealthWatchers[mob] = watch
		watch.HumanoidChildAddedConnection = mob.ChildAdded:Connect(function(child)
			if child:IsA("Humanoid") then
				task.delay(0.25, function()
					if child.Parent == mob and mob:IsDescendantOf(MobsFolder) then
						ConnectExpRetaliationHumanoid(mob, child)
					end
				end)
			end
		end)
	end)
end

MobsFolder.ChildAdded:Connect(ScheduleExpRetaliationHealthWatch)
MobsFolder.ChildRemoved:Connect(function(mob)
	if mob == configurations.CurrentTarget or mob == configurations.ExpLastShotTarget
		or mob == configurations.ExpRetaliationTarget or mob == configurations.ExpMaxCombatTarget
		or mob == configurations.ExpFinishTarget or mob == configurations.AlertCombatTarget
		or mob == configurations.ServerHopKillTarget then
		if configurations.Combat.StowWeaponAfterMobDeath then
			configurations.Combat.StowWeaponAfterMobDeath(mob)
		end
	end
	DisconnectExpRetaliationHealthWatch(mob)
	if configurations.ExpRetaliationTarget == mob then
		configurations.ExpRetaliationTarget = nil
	end
end)
task.defer(function()
	for _, mob in ipairs(MobsFolder:GetChildren()) do
		ScheduleExpRetaliationHealthWatch(mob)
	end
end)

function configurations.NotifyUser(title, message, duration)
	task.spawn(function()
		for _ = 1, 4 do
			local ok = pcall(function()
				StarterGui:SetCore("SendNotification", {
					Title = tostring(title),
					Text = tostring(message),
					Duration = duration or 5,
				})
			end)
			if ok then return end
			task.wait(0.75)
		end
	end)
end

local FollowInteractBindable
local function InvokeFollowInteract()
	local playerGui = Player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return false end

	if not FollowInteractBindable or not FollowInteractBindable:IsDescendantOf(playerGui) then
		FollowInteractBindable = playerGui:FindFirstChild("InputBindableFunction", true)
	end
	local inputFunction = FollowInteractBindable
	if not inputFunction or not inputFunction:IsA("BindableFunction") then
		FollowInteractBindable = nil
		return false
	end

	local ok = pcall(function()
		inputFunction:Invoke("InteractButton", Enum.UserInputState.Begin)
	end)
	if not ok then FollowInteractBindable = nil end
	return ok
end

-- Runtime controllers: Studio uses ModuleScripts; executor/Git uses HttpGet + loadstring.
if configurations.IsStudio then
	configurations.CombatSystem = require(script:WaitForChild("CombatSystem.lua"))
	local routePlannerModule = script:FindFirstChild("LocalRoutePlanner.lua")
	configurations.LocalRoutePlannerLoadOk, configurations.LocalRoutePlanner = pcall(function()
		assert(routePlannerModule and routePlannerModule:IsA("ModuleScript"), "LocalRoutePlanner.lua ModuleScript is missing")
		return require(routePlannerModule)
	end)
	configurations.WaypointNavigator = require(script:WaitForChild("WaypointNavigation.lua"))
	configurations.FollowSystem = require(script:WaitForChild("FollowSystem.lua"))
	configurations.SafeBoosterResetLoadOk, configurations.SafeBoosterResetLoadResult = pcall(function()
		return require(script:WaitForChild("SafeBoosterResetSystem.lua"))
	end)
	configurations.FPSBoostSystem = require(script:WaitForChild("FPSBoostSystem.lua"))
	configurations.PartySystemLoadOk, configurations.PartySystemLoadResult = pcall(function()
		return require(script:WaitForChild("PartySystem.lua"))
	end)
	configurations.TeleportSystemLoadOk, configurations.TeleportSystemLoadResult = pcall(function()
		local teleportModuleScript = script:FindFirstChild("TeleportSystem.lua")
		assert(teleportModuleScript and teleportModuleScript:IsA("ModuleScript"), "TeleportSystem.lua ModuleScript is missing")
		local teleportModule = require(teleportModuleScript)
		assert(type(teleportModule) == "table" and type(teleportModule.Initialize) == "function", "TeleportSystem has no Initialize function")
		return teleportModule
	end)
else
	configurations.CombatSystem = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/CombatSystem.lua?v=2.2.3")))()
	configurations.LocalRoutePlannerLoadOk, configurations.LocalRoutePlanner = pcall(function()
		local source = game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/LocalRoutePlanner.lua?v=1.0.0")
		local factory, compileError = loadstring(source)
		assert(factory, compileError)
		local module = factory()
		assert(type(module) == "table" and type(module.FindRoute) == "function", "LocalRoutePlanner has no FindRoute function")
		return module
	end)
	configurations.WaypointNavigator = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/WaypointNavigation.lua?v=1.2.4")))()
	configurations.FollowSystem = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/FollowSystem.lua?v=1.16.3")))()
	configurations.SafeBoosterResetLoadOk, configurations.SafeBoosterResetLoadResult = pcall(function()
		local source = game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/SafeBoosterResetSystem.lua?v=1.0.0")
		local moduleFactory, compileError = loadstring(source)
		assert(moduleFactory, compileError)
		local module = moduleFactory()
		assert(type(module) == "table" and type(module.Initialize) == "function", "SafeBoosterReset module has no Initialize function")
		return module
	end)
	configurations.FPSBoostSystem = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/FPSBoostSystem.lua?v=1.2.0")))()
	configurations.PartySystemLoadOk, configurations.PartySystemLoadResult = pcall(function()
		local source = game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/PartySystem.lua?v=1.1.0")
		local moduleFactory, compileError = loadstring(source)
		assert(moduleFactory, compileError)
		local module = moduleFactory()
		assert(type(module) == "table" and type(module.Initialize) == "function", "PartySystem has no Initialize function")
		return module
	end)
	configurations.TeleportSystemLoadOk, configurations.TeleportSystemLoadResult = pcall(function()
		local source = game:HttpGet("https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/TeleportSystem.lua?v=1.0.1")
		local moduleFactory, compileError = loadstring(source)
		assert(moduleFactory, compileError)
		local module = moduleFactory()
		assert(type(module) == "table" and type(module.Initialize) == "function", "TeleportSystem has no Initialize function")
		return module
	end)
end

if not configurations.LocalRoutePlannerLoadOk then
	warn("[Iamrich] LocalRoutePlanner unavailable; movement will use legacy detours until the module is installed.")
end

configurations.CombatSystem.Initialize(configurations, { MobsFolder = MobsFolder })
configurations.WaypointNavigator = configurations.WaypointNavigator.Initialize(configurations, { Players = Players, MobsFolder = MobsFolder, RoutePlanner = configurations.LocalRoutePlanner })
configurations.FollowSystem = configurations.FollowSystem.Initialize(configurations, { Players = Players, MobsFolder = MobsFolder, ClaimMovement = ClaimMovement, ReleaseMovement = ReleaseMovement, Interact = InvokeFollowInteract, RoutePlanner = configurations.LocalRoutePlanner })
if configurations.SafeBoosterResetLoadOk then
	configurations.SafeBoosterResetInitOk, configurations.SafeBoosterResetInitResult = pcall(function()
		return configurations.SafeBoosterResetLoadResult.Initialize(configurations, { Player = Player, ReplicatedStorage = ReplicatedStorage, Notify = configurations.NotifyUser })
	end)
end
configurations.SafeBoosterResetAvailable = configurations.SafeBoosterResetInitOk == true and type(configurations.SafeBoosterResetInitResult) == "table"
if configurations.SafeBoosterResetAvailable then
	configurations.SafeBoosterResetSystem = configurations.SafeBoosterResetInitResult
else
	configurations.SafeBoosterResetEnabled = false
	configurations.SafeBoosterResetSystem = { SetEnabled = function(enabled)
		if enabled then configurations.NotifyUser("Safe booster reset", "Module unavailable; upload SafeBoosterResetSystem.lua first.", 6) end
		return false
	end }
	if not configurations.IsStudio then warn("[Iamrich] SafeBoosterReset is unavailable:", configurations.SafeBoosterResetLoadOk and configurations.SafeBoosterResetInitResult or configurations.SafeBoosterResetLoadResult) end
end
configurations.FPSBoostSystem = configurations.FPSBoostSystem.Initialize(configurations, { Lighting = Lighting })
if configurations.PartySystemLoadOk then
	configurations.PartySystem = configurations.PartySystemLoadResult
else
	warn("[Iamrich] PartySystem is unavailable:", configurations.PartySystemLoadResult)
end
if configurations.TeleportSystemLoadOk then
	configurations.TeleportSystemInitOk, configurations.TeleportSystemInitResult = pcall(function()
		return configurations.TeleportSystemLoadResult.Initialize(configurations, {
			ReplicatedStorage = ReplicatedStorage,
			Workspace = workspace,
		})
	end)
	if configurations.TeleportSystemInitOk and type(configurations.TeleportSystemInitResult) == "table"
		and type(configurations.TeleportSystemInitResult.BuildUI) == "function" then
		configurations.TeleportSystem = configurations.TeleportSystemInitResult
	else
		configurations.TeleportSystem = nil
		warn("[Iamrich] TeleportSystem failed to initialize:", configurations.TeleportSystemInitResult)
	end
else
	warn("[Iamrich] TeleportSystem is unavailable:", configurations.TeleportSystemLoadResult)
end

function configurations.PrepareConfigStorage()
	if configurations.IsStudio then return false end
	local userId = tostring(Player.UserId)
	local placeId = tostring(game.PlaceId)
	configurations.ConfigUserFolder = configurations.ConfigRootFolder .. "/" .. userId
	local nestedPath = configurations.ConfigUserFolder .. "/Config.json"
	local flatPath = configurations.ConfigRootFolder .. "_" .. userId .. ".json"

	if type(makefolder) == "function" then
		pcall(makefolder, configurations.ConfigRootFolder)
		pcall(makefolder, configurations.ConfigUserFolder)
		local folderReady = type(isfolder) ~= "function"
		if type(isfolder) == "function" then
			local ok, exists = pcall(isfolder, configurations.ConfigUserFolder)
			folderReady = ok and exists == true
		end
		if folderReady then
			configurations.ConfigFileName = nestedPath
			configurations.WaypointConfigFileName = configurations.ConfigUserFolder .. "/Waypoint_" .. placeId .. ".json"
			return
		end
	end

	-- Keep per-user isolation even on executors without folder APIs.
	configurations.ConfigFileName = flatPath
	configurations.WaypointConfigFileName = configurations.ConfigRootFolder .. "_" .. userId .. "_Waypoint_" .. placeId .. ".json"
end


function configurations.LoadConfig()
	if configurations.IsStudio then return end
	if type(readfile) ~= "function" then return end
	configurations.PrepareConfigStorage()
	local function ReadConfig(path)
		local ok, config = pcall(function()
			return HttpService:JSONDecode(readfile(path))
		end)
		return ok and type(config) == "table" and config or nil
	end

	local config = ReadConfig(configurations.ConfigFileName)
	if not config then
		-- Import the old shared config once, assigning it to the first UserId that runs this version.
		local owner = ""
		local ownerOk, ownerValue = pcall(function()
			return readfile(configurations.LegacyConfigOwnerFileName)
		end)
		if ownerOk then
			owner = tostring(ownerValue)
		end
		if owner == "" and type(writefile) == "function" then
			local legacyConfig = ReadConfig(configurations.LegacyConfigFileName)
			if legacyConfig then
				local markerWritten = pcall(function()
					writefile(configurations.LegacyConfigOwnerFileName, tostring(Player.UserId))
				end)
				if markerWritten then
					configurations.MigratedLegacyConfig = true
					config = legacyConfig
				end
			end
		end
	end
	if type(config) ~= "table" then return end
	configurations.WaypointConfigVersion = tonumber(config.WaypointConfigVersion) or 0
	if configurations.WaypointConfigVersion < 1 and type(config.WaypointPosition) == "table" then
		configurations.LegacyWaypointConfig = {
			Position = config.WaypointPosition,
			ReturnEnabled = config.WaypointReturnEnabled == true,
		}
	end

	local function ReadNumber(key, current, minimum, allowZero)
		local value = tonumber(config[key])
		if value and value >= minimum and (allowZero or value > 0) then
			return value
		end
		return current
	end

	configurations.Amount = math.floor(ReadNumber("Amount", configurations.Amount, 0, false))
	configurations.ExpApproachDistance = math.clamp(ReadNumber("ExpApproachDistance", configurations.ExpApproachDistance, 5, false), 5, 100)
	if type(config.ExpAutoApproachEnabled) == "boolean" then
		configurations.ExpAutoApproachEnabled = config.ExpAutoApproachEnabled
	end
	configurations.MaxDistance = math.clamp(ReadNumber("MaxDistance", configurations.MaxDistance, 5, false), 5, 100000)
	configurations.Interval = ReadNumber("Interval", configurations.Interval, 0, true)
	configurations.ExpGoal = ReadNumber("ExpGoal", configurations.ExpGoal, 0, false)
	if type(config.AutoExecuteEnabled) == "boolean" then configurations.AutoExecuteEnabled = config.AutoExecuteEnabled end
	if type(config.CreditLogHiddenUsers) == "table" then configurations.CreditLogHiddenUsers = config.CreditLogHiddenUsers end
	configurations.CreditLogWidthScale = math.clamp(ReadNumber("CreditLogWidthScale", configurations.CreditLogWidthScale, 0.32, false), 0.32, 0.65)
	configurations.CreditLogHeightScale = math.clamp(ReadNumber("CreditLogHeightScale", configurations.CreditLogHeightScale, 0.35, false), 0.35, 0.90)
	do
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		local function ReadPx(key, current, lo, hi)
			local v = tonumber(config[key])
			if v and v >= lo then return math.clamp(math.floor(v + 0.5), lo, hi) end
			return current
		end
		configurations.CreditLogWidthPx = ReadPx("CreditLogWidthPx", configurations.CreditLogWidthPx or 340, 260, 560)
		configurations.CreditLogHeightPx = ReadPx("CreditLogHeightPx", configurations.CreditLogHeightPx or 380, 240, 700)
		if config.CreditLogWidthPx == nil and tonumber(config.CreditLogWidthScale) then
			configurations.CreditLogWidthPx = math.clamp(math.floor(tonumber(config.CreditLogWidthScale) * viewport.X + 0.5), 260, 560)
		end
		if config.CreditLogHeightPx == nil and tonumber(config.CreditLogHeightScale) then
			configurations.CreditLogHeightPx = math.clamp(math.floor(tonumber(config.CreditLogHeightScale) * viewport.Y + 0.5), 240, 700)
		end
	end
	configurations.AlertsDistance = math.clamp(ReadNumber("AlertsDistance", configurations.AlertsDistance, 0, true), 0, 100000)
	configurations.FollowDistance = math.clamp(ReadNumber("FollowDistance", configurations.FollowDistance, 2, false), 2, 100)
	if type(config.FollowTargetVisible) == "boolean" then
		configurations.FollowTargetVisible = config.FollowTargetVisible
	end
	if type(config.FPSBoostEnabled) == "boolean" then
		configurations.FPSBoostEnabled = config.FPSBoostEnabled
	end
	configurations.AutoAttackRange = math.clamp(ReadNumber("AutoAttackRange", configurations.AutoAttackRange, 5, false), 5, 500)
	local savedMobSearchRange = ReadNumber("AutoAttackSearchRange", configurations.AutoAttackSearchRange, 5, false)
	-- Earlier builds defaulted mob visibility to 100 studs. The intended default
	-- is 1000, so migrate that legacy default instead of silently keeping targets
	-- such as the 955-stud mob outside the eligible-target search.
	if savedMobSearchRange == 100 then savedMobSearchRange = 1000 end
	configurations.AutoAttackSearchRange = math.clamp(savedMobSearchRange, 5, 1000)
	configurations.AutoAttackInterval = math.clamp(ReadNumber("AutoAttackInterval", configurations.AutoAttackInterval, 1, false), 1, 10)
	configurations.AutoSkillInterval = math.clamp(ReadNumber("AutoSkillInterval", configurations.AutoSkillInterval, 1, false), 1, 30)
	local followUserId = tonumber(config.FollowTargetUserId)
	local isLegacyFollowConfig = config.FollowTargetUserId == nil
	if not followUserId then followUserId = tonumber(config.FollowPlayerUserId) end
	if followUserId and followUserId > 0 and followUserId % 1 == 0 then
		configurations.SelectedFollowUserId = tostring(followUserId)
	end
	if type(config.FollowEnabled) == "boolean" then
		configurations.FollowEnabled = config.FollowEnabled and configurations.SelectedFollowUserId ~= nil
	elseif isLegacyFollowConfig then
		configurations.FollowEnabled = configurations.SelectedFollowUserId ~= nil
	end
	if type(config.PartyFollowEnabled) == "boolean" then configurations.PartyFollowEnabled = config.PartyFollowEnabled end
	local partyLeaderUserId = tonumber(config.PartyLeaderUserId)
	if partyLeaderUserId and partyLeaderUserId > 0 and partyLeaderUserId % 1 == 0 then
		configurations.PartyLeaderUserId = partyLeaderUserId
		configurations.PartyLeaderName = type(config.PartyLeaderName) == "string" and config.PartyLeaderName or nil
	end
	configurations.PartyResumeFarmOnJoin = config.PartyResumeFarmOnJoin == true
	configurations.GuiScale = math.clamp(ReadNumber("GuiScale", configurations.GuiScale, 1, false), 0.20, 2.50)
	configurations.TextScale = math.clamp(ReadNumber("TextScale", configurations.TextScale, 1, false), 0.20, 2.50)
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1000, 800)
	local function ReadPx(key, current, lo, hi)
		local v = tonumber(config[key])
		if v and v >= lo then return math.clamp(math.floor(v + 0.5), lo, hi) end
		return current
	end
	-- Prefer fixed px; migrate scale-based saves once.
	if tonumber(config.MainWidthPx) then
		configurations.MainWidthPx = ReadPx("MainWidthPx", configurations.MainWidthPx or 520, 360, 900)
	elseif tonumber(config.MainWidthScale) then
		configurations.MainWidthPx = math.clamp(math.floor(tonumber(config.MainWidthScale) * viewport.X + 0.5), 360, 900)
	elseif tonumber(config.MainWidth) then
		configurations.MainWidthPx = math.clamp(math.floor(tonumber(config.MainWidth) + 0.5), 360, 900)
	end
	if tonumber(config.MainHeightPx) then
		configurations.MainHeightPx = ReadPx("MainHeightPx", configurations.MainHeightPx or 560, 320, 900)
	elseif tonumber(config.MainHeightScale) then
		configurations.MainHeightPx = math.clamp(math.floor(tonumber(config.MainHeightScale) * viewport.Y + 0.5), 320, 900)
	elseif tonumber(config.MainHeight) then
		configurations.MainHeightPx = math.clamp(math.floor(tonumber(config.MainHeight) + 0.5), 320, 900)
	end
	configurations.MainWidthScale = math.clamp((configurations.MainWidthPx or 520) / math.max(1, viewport.X), 0.15, 0.95)
	configurations.MainHeightScale = math.clamp((configurations.MainHeightPx or 560) / math.max(1, viewport.Y), 0.20, 0.95)

	configurations.PlayerPanelWidthPx = ReadPx("PlayerPanelWidthPx", configurations.PlayerPanelWidthPx or 340, 260, 560)
	configurations.PlayerPanelHeightPx = ReadPx("PlayerPanelHeightPx", configurations.PlayerPanelHeightPx or 420, 280, 700)
	configurations.WhitelistPanelWidthPx = ReadPx("WhitelistPanelWidthPx", configurations.WhitelistPanelWidthPx or 300, 240, 520)
	configurations.WhitelistPanelHeightPx = ReadPx("WhitelistPanelHeightPx", configurations.WhitelistPanelHeightPx or 360, 240, 640)
	configurations.JoinLogWidthPx = ReadPx("JoinLogWidthPx", configurations.JoinLogWidthPx or 320, 260, 560)
	configurations.JoinLogHeightPx = ReadPx("JoinLogHeightPx", configurations.JoinLogHeightPx or 360, 240, 640)
	if config.PlayerPanelWidthPx == nil and tonumber(config.PlayerPanelWidthScale) then
		configurations.PlayerPanelWidthPx = math.clamp(math.floor(tonumber(config.PlayerPanelWidthScale) * viewport.X + 0.5), 260, 560)
	end
	if config.PlayerPanelHeightPx == nil and tonumber(config.PlayerPanelHeightScale) then
		configurations.PlayerPanelHeightPx = math.clamp(math.floor(tonumber(config.PlayerPanelHeightScale) * viewport.Y + 0.5), 280, 700)
	end
	configurations.PlayerPanelWidthScale = math.clamp(ReadNumber("PlayerPanelWidthScale", configurations.PlayerPanelWidthScale, 0.36, false), 0.28, 0.52)
	configurations.PlayerPanelHeightScale = math.clamp(ReadNumber("PlayerPanelHeightScale", configurations.PlayerPanelHeightScale, 0.35, false), 0.35, 0.9)
	configurations.WhitelistPanelWidthScale = math.clamp(ReadNumber("WhitelistPanelWidthScale", configurations.WhitelistPanelWidthScale, 0.26, false), 0.26, 0.8)
	configurations.WhitelistPanelHeightScale = math.clamp(ReadNumber("WhitelistPanelHeightScale", configurations.WhitelistPanelHeightScale, 0.32, false), 0.32, 0.9)
	configurations.JoinLogWidthScale = math.clamp(ReadNumber("JoinLogWidthScale", configurations.JoinLogWidthScale, 0.38, false), 0.32, 0.65)
	configurations.JoinLogHeightScale = math.clamp(ReadNumber("JoinLogHeightScale", configurations.JoinLogHeightScale, 0.50, false), 0.20, 0.9)
	if type(config.AlertsEnabled) == "boolean" then configurations.AlertsEnabled = config.AlertsEnabled end
	if type(config.JoinAlertsEnabled) == "boolean" then configurations.JoinAlertsEnabled = config.JoinAlertsEnabled end
	if config.AutoResumeAfterAlertVersion == 1 and type(config.AutoResumeAfterAlert) == "boolean" then
		configurations.AutoResumeAfterAlert = config.AutoResumeAfterAlert
	elseif config.AutoResumeAfterAlertVersion ~= 1 then
		-- Older configs predate the resume setting; migrate them to the new default.
		configurations.AutoResumeAfterAlert = true
		configurations.MigratedLegacyConfig = true
	end
	if type(config.AlertFlashEnabled) == "boolean" then configurations.AlertFlashEnabled = config.AlertFlashEnabled end
	if type(config.AutoBlockEnabled) == "boolean" then configurations.AutoBlockEnabled = config.AutoBlockEnabled end
	if type(config.FinishExpAfterBlockEnabled) == "boolean" then configurations.FinishExpAfterBlockEnabled = config.FinishExpAfterBlockEnabled end
	if type(config.MovementBoostEnabled) == "boolean" then configurations.MovementBoostEnabled = config.MovementBoostEnabled end
	if type(config.SafeBoosterResetEnabled) == "boolean" then configurations.SafeBoosterResetEnabled = config.SafeBoosterResetEnabled end
	if type(config.AutoAttackEnabled) == "boolean" then configurations.AutoAttackEnabled = config.AutoAttackEnabled end
	if type(config.AutoBossTargetEnabled) == "boolean" then configurations.AutoBossTargetEnabled = config.AutoBossTargetEnabled end
	if type(config.AutoMiniBossTargetEnabled) == "boolean" then configurations.AutoMiniBossTargetEnabled = config.AutoMiniBossTargetEnabled end
	if type(config.WaypointBillboardEnabled) == "boolean" then configurations.WaypointBillboardEnabled = config.WaypointBillboardEnabled end
	if type(config.ExpTargetRetaliationEnabled) == "boolean" then configurations.ExpTargetRetaliationEnabled = config.ExpTargetRetaliationEnabled end
	if type(config.ExpRetaliationHealthPercent) == "number" then
		configurations.ExpRetaliationHealthPercent = math.clamp(math.floor(config.ExpRetaliationHealthPercent), 1, 100)
	end
	if type(config.ExpHitFeedbackEnabled) == "boolean" then configurations.ExpHitFeedbackEnabled = config.ExpHitFeedbackEnabled end
	if type(config.AutoSkillEnabled) == "boolean" then configurations.AutoSkillEnabled = config.AutoSkillEnabled end
	if type(config.ESPEnabled) == "boolean" then configurations.ESPEnabled = config.ESPEnabled end
	if type(config.ESPLineEnabled) == "boolean" then configurations.ESPLineEnabled = config.ESPLineEnabled end
	if type(config.ESPBoxEnabled) == "boolean" then configurations.ESPBoxEnabled = config.ESPBoxEnabled end
	if type(config.AntiAFKEnabled) == "boolean" then configurations.AntiAFKEnabled = config.AntiAFKEnabled end
	configurations.SavedMinimized = config.Minimized == true
	if type(config.WhitelistIds) == "table" then
		for _, userId in ipairs(config.WhitelistIds) do
			local id = tostring(userId)
			if id:match("^%d+$") and tonumber(id) and tonumber(id) > 0 then
				configurations.WhitelistIds[id] = true
			end
		end
	end
	if type(config.PinnedPlayerIds) == "table" then
		for _, userId in ipairs(config.PinnedPlayerIds) do
			local id = tostring(userId)
			if id:match("^%d+$") and tonumber(id) and tonumber(id) > 0 then
				configurations.PinnedPlayerIds[id] = true
			end
		end
	end
end

function configurations.SaveWaypointConfig()
	if configurations.IsStudio or type(writefile) ~= "function" then return false end
	configurations.PrepareConfigStorage()
	if configurations.WaypointConfigFileName == "" then return false end
	local point = configurations.WaypointPosition
	local data = {
		PlaceId = tostring(game.PlaceId),
		Position = point and { X = point.X, Y = point.Y, Z = point.Z } or nil,
		ReturnEnabled = point ~= nil and configurations.WaypointReturnEnabled == true,
	}
	local ok, err = pcall(function()
		writefile(configurations.WaypointConfigFileName, HttpService:JSONEncode(data))
	end)
	if not ok then
		warn("[Iamrich] Waypoint save failed:", err)
		return false
	end
	configurations.WaypointConfigVersion = 1
	configurations.LegacyWaypointConfig = nil
	return true
end

function configurations.LoadWaypointConfig()
	if configurations.IsStudio or type(readfile) ~= "function" then return false end
	configurations.PrepareConfigStorage()
	local shouldSaveVersion = configurations.WaypointConfigVersion < 1
	local loadedPlaceRecord = false
	local fileOk, data = pcall(function()
		return HttpService:JSONDecode(readfile(configurations.WaypointConfigFileName))
	end)
	if fileOk and type(data) == "table" and tostring(data.PlaceId) == tostring(game.PlaceId) then
		loadedPlaceRecord = true
		local point = data.Position
		if type(point) == "table" then
			local x, y, z = tonumber(point.X), tonumber(point.Y), tonumber(point.Z)
			if x and y and z then configurations.WaypointPosition = Vector3.new(x, y, z) end
		end
		configurations.WaypointReturnEnabled = configurations.WaypointPosition ~= nil
			and data.ReturnEnabled == true
	end

	if not loadedPlaceRecord and configurations.WaypointConfigVersion < 1
		and type(configurations.LegacyWaypointConfig) == "table" then
		local point = configurations.LegacyWaypointConfig.Position
		if type(point) == "table" then
			local x, y, z = tonumber(point.X), tonumber(point.Y), tonumber(point.Z)
			if x and y and z then
				configurations.WaypointPosition = Vector3.new(x, y, z)
				configurations.WaypointReturnEnabled = configurations.LegacyWaypointConfig.ReturnEnabled == true
				loadedPlaceRecord = configurations.SaveWaypointConfig()
			end
		end
	end

	if loadedPlaceRecord or not configurations.LegacyWaypointConfig then
		configurations.WaypointConfigVersion = 1
		configurations.LegacyWaypointConfig = nil
	end
	if shouldSaveVersion and configurations.WaypointConfigVersion >= 1 then
		configurations.SaveConfig()
	end
	return loadedPlaceRecord
end

function configurations.SaveConfig()
	if configurations.IsStudio then return false end
	if type(writefile) ~= "function" then
		if not configurations.ConfigSaveWarningShown then
			warn("[Iamrich] Config was not saved: this executor does not provide writefile.")
			configurations.ConfigSaveWarningShown = true
		end
		return false
	end
	configurations.PrepareConfigStorage()
	local ids = {}
	for userId in pairs(configurations.WhitelistIds) do
		table.insert(ids, userId)
	end
	table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
	local pinnedIds = {}
	for userId in pairs(configurations.PinnedPlayerIds) do
		table.insert(pinnedIds, userId)
	end
	table.sort(pinnedIds, function(a, b) return tonumber(a) < tonumber(b) end)

	local config = {
		Amount = configurations.Amount,
		MaxDistance = configurations.MaxDistance,
		ExpApproachDistance = configurations.ExpApproachDistance,
		ExpAutoApproachEnabled = configurations.ExpAutoApproachEnabled,
		Interval = configurations.Interval,
		ExpGoal = configurations.ExpGoal,
		AutoExecuteEnabled = configurations.AutoExecuteEnabled,
		AlertsDistance = configurations.AlertsDistance,
		FollowDistance = configurations.FollowDistance,
		FollowTargetVisible = configurations.FollowTargetVisible,
		FollowTargetUserId = configurations.SelectedFollowUserId,
		FollowEnabled = configurations.FollowEnabled,
		PartyFollowEnabled = configurations.PartyFollowEnabled,
		PartyLeaderUserId = configurations.PartyLeaderUserId,
		PartyLeaderName = configurations.PartyLeaderName,
		PartyResumeFarmOnJoin = configurations.PartyResumeFarmOnJoin,
		FPSBoostEnabled = configurations.FPSBoostEnabled,
		AutoAttackEnabled = configurations.AutoAttackEnabled,
		AutoBossTargetEnabled = configurations.AutoBossTargetEnabled,
		AutoMiniBossTargetEnabled = configurations.AutoMiniBossTargetEnabled,
		ExpTargetRetaliationEnabled = configurations.ExpTargetRetaliationEnabled,
		ExpRetaliationHealthPercent = configurations.ExpRetaliationHealthPercent,
		ExpHitFeedbackEnabled = configurations.ExpHitFeedbackEnabled,
		AutoAttackRange = configurations.AutoAttackRange,
		AutoAttackSearchRange = configurations.AutoAttackSearchRange,
		WaypointConfigVersion = configurations.WaypointConfigVersion,
		WaypointBillboardEnabled = configurations.WaypointBillboardEnabled,
		AutoAttackInterval = configurations.AutoAttackInterval,
		AutoSkillEnabled = configurations.AutoSkillEnabled,
		AutoSkillInterval = configurations.AutoSkillInterval,
		MainWidthPx = configurations.MainWidthPx,
		MainHeightPx = configurations.MainHeightPx,
		MainWidthScale = configurations.MainWidthScale,
		MainHeightScale = configurations.MainHeightScale,
		GuiScale = configurations.GuiScale,
		TextScale = configurations.TextScale,
		PlayerPanelWidthPx = configurations.PlayerPanelWidthPx,
		PlayerPanelHeightPx = configurations.PlayerPanelHeightPx,
		WhitelistPanelWidthPx = configurations.WhitelistPanelWidthPx,
		WhitelistPanelHeightPx = configurations.WhitelistPanelHeightPx,
		JoinLogWidthPx = configurations.JoinLogWidthPx,
		JoinLogHeightPx = configurations.JoinLogHeightPx,
		CreditLogWidthPx = configurations.CreditLogWidthPx,
		CreditLogHeightPx = configurations.CreditLogHeightPx,
		PlayerPanelWidthScale = configurations.PlayerPanelWidthScale,
		PlayerPanelHeightScale = configurations.PlayerPanelHeightScale,
		WhitelistPanelWidthScale = configurations.WhitelistPanelWidthScale,
		WhitelistPanelHeightScale = configurations.WhitelistPanelHeightScale,
		JoinLogWidthScale = configurations.JoinLogWidthScale,
		JoinLogHeightScale = configurations.JoinLogHeightScale,
		CreditLogHiddenUsers = configurations.CreditLogHiddenUsers,
		CreditLogWidthScale = configurations.CreditLogWidthScale,
		CreditLogHeightScale = configurations.CreditLogHeightScale,
		AlertsEnabled = configurations.AlertsEnabled,
		JoinAlertsEnabled = configurations.JoinAlertsEnabled,
		AutoResumeAfterAlert = configurations.AutoResumeAfterAlert,
		AutoResumeAfterAlertVersion = 1,
		AlertFlashEnabled = configurations.AlertFlashEnabled,
		AutoBlockEnabled = configurations.AutoBlockEnabled,
		FinishExpAfterBlockEnabled = configurations.FinishExpAfterBlockEnabled,
		MovementBoostEnabled = configurations.MovementBoostEnabled,
		SafeBoosterResetEnabled = configurations.SafeBoosterResetEnabled,
		ESPEnabled = configurations.ESPEnabled,
		ESPLineEnabled = configurations.ESPLineEnabled,
		ESPBoxEnabled = configurations.ESPBoxEnabled,
		AntiAFKEnabled = configurations.AntiAFKEnabled,
		WhitelistIds = ids,
		PinnedPlayerIds = pinnedIds,
		Minimized = configurations.IsMinimized == true,
	}
	local ok, err = pcall(function()
		writefile(configurations.ConfigFileName, HttpService:JSONEncode(config))
	end)
	if not ok then
		warn("[Iamrich] Config save failed:", err)
	end
	return ok
end

function configurations.SetFPSBoost(enabled)
	enabled = enabled == true
	if configurations.FPSBoostEnabled == enabled then return enabled end
	configurations.FPSBoostEnabled = enabled
	configurations.FPSBoostSystem.SetEnabled(enabled)
	configurations.SaveConfig()
	return enabled
end

configurations.LoadConfig()
configurations.LoadWaypointConfig()
if configurations.PartySystem then
	configurations.PartySystemInitOk, configurations.PartySystemInitResult = pcall(function()
		return configurations.PartySystem.Initialize(configurations, {
			Players = Players,
			Player = Player,
			ReplicatedStorage = ReplicatedStorage,
			TeleportService = TeleportService,
			HttpService = HttpService,
		})
	end)
	if configurations.PartySystemInitOk then
		configurations.PartySystem = configurations.PartySystemInitResult
	else
		warn("[Iamrich] PartySystem failed to initialize:", configurations.PartySystemInitResult)
		configurations.PartySystem = nil
	end
end
if not configurations.SafeBoosterResetAvailable then configurations.SafeBoosterResetEnabled = false end
if configurations.FPSBoostEnabled then configurations.FPSBoostSystem.SetEnabled(true) end
configurations.FollowSystem.SetTargetLineVisible(configurations.FollowTargetVisible)
if configurations.MigratedLegacyConfig then
	configurations.SaveConfig()
end
function configurations.IsWhitelisted(otherPlayer)
	return configurations.WhitelistIds[tostring(otherPlayer.UserId)] == true
end

configurations.JoinAlertSeen = {}
configurations.PlayerJoinLog = {}
configurations.JoinLogOnline = {}
function configurations.RecordPlayerLog(player, eventType)
	if not player or player == Player then return false end
	table.insert(configurations.PlayerJoinLog, {
		Time = os.date("%H:%M:%S"),
		Event = eventType,
		Username = player.Name,
		UserId = tostring(player.UserId),
		Whitelisted = configurations.IsWhitelisted(player),
		SpecialThreat = configurations.SpecialGroupThreatUsers[tostring(player.UserId)] == true
			and not configurations.IsWhitelisted(player),
	})
	while #configurations.PlayerJoinLog > 100 do
		table.remove(configurations.PlayerJoinLog, 1)
	end
	if configurations.JoinLogPanel and configurations.JoinLogPanel.Visible then
		configurations.RefreshJoinLog()
	end
	return true
end

function configurations.StartSpecialGroupServerHop(player)
	if configurations.SpecialGroupHopStarted or not player or player.Parent ~= Players
		or configurations.IsWhitelisted(player) then
		return false
	end
	configurations.SpecialGroupHopStarted = true
	configurations.SpecialGroupHopAttempts += 1
	configurations.Farming = false
	configurations.PendingServerHop = false
	configurations.ServerHopKillTarget = nil
	task.spawn(function()
		if player.Parent ~= Players or configurations.IsWhitelisted(player) then
			configurations.SpecialGroupHopStarted = false
			return
		end
		local ok, err = pcall(function()
			TeleportService:Teleport(game.PlaceId, Player)
		end)
		if not ok then
			configurations.SpecialGroupHopStarted = false
			warn("Special group server hop failed:", err)
			if configurations.SpecialGroupHopAttempts < 3 then
				configurations.NotifyUser("Server hop failed", "Retrying the server hop.", 6)
				task.delay(3, function()
					configurations.StartSpecialGroupServerHop(player)
				end)
			else
				configurations.NotifyUser("Server hop failed", "Teleport failed after 3 attempts.", 7)
			end
		end
	end)
	return true
end

function configurations.MarkSpecialGroupThreat(player)
	if not player or player == Player or player.Parent ~= Players then return false end
	local userId = tostring(player.UserId)
	configurations.SpecialGroupThreatUsers[userId] = true
	if configurations.IsWhitelisted(player) then
		if configurations.JoinLogPanel and configurations.JoinLogPanel.Visible and configurations.RefreshJoinLog then
			configurations.RefreshJoinLog()
		end
		return false
	end
	local markedEntry = nil
	for index = #configurations.PlayerJoinLog, 1, -1 do
		local entry = configurations.PlayerJoinLog[index]
		if entry.UserId == userId then
			entry.SpecialThreat = true
			markedEntry = entry
			break
		end
	end
	if not markedEntry then
		configurations.RecordPlayerLog(player, "present")
		markedEntry = configurations.PlayerJoinLog[#configurations.PlayerJoinLog]
		if markedEntry and markedEntry.UserId == userId then markedEntry.SpecialThreat = true end
	end
	if configurations.JoinLogPanel and configurations.JoinLogPanel.Visible and configurations.RefreshJoinLog then
		configurations.RefreshJoinLog()
	end
	configurations.NotifyUser("Special danger", "@" .. player.Name .. " is in group 5928691. Leaving this server.", 7)
	configurations.StartSpecialGroupServerHop(player)
	return true
end

function configurations.CheckSpecialGroupPlayer(player)
	if not player or player == Player then return false end
	local userId = tostring(player.UserId)
	if configurations.IsWhitelisted(player) then return false end
	if configurations.SpecialGroupThreatUsers[userId] then
		configurations.StartSpecialGroupServerHop(player)
		return true
	end
	if configurations.SpecialGroupCheckedUsers[userId] or configurations.SpecialGroupCheckInFlight[userId] then return false end
	configurations.SpecialGroupCheckInFlight[userId] = true
	task.spawn(function()
		local ok, isMember = pcall(function()
			return player:IsInGroupAsync(5928691)
		end)
		configurations.SpecialGroupCheckInFlight[userId] = nil
		if not ok then
			warn("Special group membership check failed for @" .. player.Name .. ":", isMember)
			configurations.SpecialGroupCheckFailures[userId] = (configurations.SpecialGroupCheckFailures[userId] or 0) + 1
			if configurations.SpecialGroupCheckFailures[userId] < 3 then
				task.delay(5, function()
					if player.Parent == Players then configurations.CheckSpecialGroupPlayer(player) end
				end)
			else
				configurations.NotifyUser("Group check failed", "Could not check @" .. player.Name .. " after 3 tries.", 7)
			end
			return
		end
		configurations.SpecialGroupCheckFailures[userId] = nil
		configurations.SpecialGroupCheckedUsers[userId] = true
		if isMember and player.Parent == Players then
			configurations.MarkSpecialGroupThreat(player)
		end
	end)
	return true
end

function configurations.OnWhitelistChanged(userId)
	if configurations.JoinLogPanel and configurations.JoinLogPanel.Visible and configurations.RefreshJoinLog then
		configurations.RefreshJoinLog()
	end
	if userId == nil then return end
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if tostring(otherPlayer.UserId) == tostring(userId) and not configurations.IsWhitelisted(otherPlayer) then
			if configurations.SpecialGroupThreatUsers[tostring(userId)] then
				configurations.MarkSpecialGroupThreat(otherPlayer)
			else
				configurations.CheckSpecialGroupPlayer(otherPlayer)
			end
			return
		end
	end
end

function configurations.NotifyUnwhitelistedPlayer(player, wasAlreadyHere)
	if not player or player == Player or configurations.JoinAlertsEnabled ~= true
		or configurations.IsWhitelisted(player) then
		return false
	end
	local userId = tostring(player.UserId)
	if configurations.JoinAlertSeen[userId] then return false end
	configurations.JoinAlertSeen[userId] = true
	local title = wasAlreadyHere and "Player already in server" or "Player joined"
	local message = "@" .. player.Name .. (wasAlreadyHere and " is already here." or " joined the server.")
	configurations.NotifyUser(title, message, 6)
	return true
end

function configurations.ScanServerJoinAlerts()
	local alerted = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if configurations.NotifyUnwhitelistedPlayer(player, true) then alerted += 1 end
	end
	return alerted
end

function configurations.SetJoinAlertsEnabled(enabled)
	configurations.JoinAlertsEnabled = enabled == true
	if configurations.JoinAlertsEnabled then
		configurations.ScanServerJoinAlerts()
	end
	configurations.SaveConfig()
	return configurations.JoinAlertsEnabled
end

Players.PlayerAdded:Connect(function(player)
	if player ~= Player then
		local userId = tostring(player.UserId)
		if not configurations.JoinLogOnline[userId] then
			configurations.JoinLogOnline[userId] = true
			configurations.RecordPlayerLog(player, "joined")
		end
	end
	task.defer(configurations.NotifyUnwhitelistedPlayer, player, false)
	configurations.CheckSpecialGroupPlayer(player)
end)
Players.PlayerRemoving:Connect(function(player)
	if player ~= Player then
		local userId = tostring(player.UserId)
		if configurations.JoinLogOnline[userId] then
			configurations.RecordPlayerLog(player, "left")
		end
		configurations.JoinLogOnline[userId] = nil
	end
	configurations.JoinAlertSeen[tostring(player.UserId)] = nil
	configurations.SpecialGroupCheckedUsers[tostring(player.UserId)] = nil
	configurations.SpecialGroupCheckFailures[tostring(player.UserId)] = nil
end)
for _, existingPlayer in ipairs(Players:GetPlayers()) do
	if existingPlayer ~= Player then
		local userId = tostring(existingPlayer.UserId)
		if not configurations.JoinLogOnline[userId] then
			configurations.JoinLogOnline[userId] = true
			configurations.RecordPlayerLog(existingPlayer, "present")
		end
		configurations.CheckSpecialGroupPlayer(existingPlayer)
	end
end
if configurations.JoinAlertsEnabled then
	task.defer(configurations.ScanServerJoinAlerts)
end

function configurations.GetBlockedUserSet()
	local ok, blockedUserIds = pcall(function()
		return StarterGui:GetCore("GetBlockedUserIds")
	end)
	if not ok or type(blockedUserIds) ~= "table" then return nil end
	local blocked = {}
	for _, userId in pairs(blockedUserIds) do
		blocked[tostring(userId)] = true
	end
	return blocked
end

function configurations.IsPlayerESPEnabled(otherPlayer)
	local userId = tostring(otherPlayer.UserId)
	local explicitSetting = configurations.PlayerESPEnabled[userId]
	if explicitSetting ~= nil then return explicitSetting == true end
	return not configurations.IsWhitelisted(otherPlayer)
end

function configurations.GetPlayerHealth(otherPlayer)
	local character = otherPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil, nil end
	return math.max(0, math.floor(humanoid.Health + 0.5)), math.max(0, math.floor(humanoid.MaxHealth + 0.5))
end

function configurations.GetPlayerStats(otherPlayer)
	local stats = otherPlayer:FindFirstChild("PlayerStats")
	local level = stats and stats:FindFirstChild("Level")
	local defense = stats and stats:FindFirstChild("Defense")
	local levelValue = level and level.Value
	local defenseValue = defense and defense.Value
	return levelValue, defenseValue
end

function configurations.FormatPlayerStats(otherPlayer)
	local level, defense = configurations.GetPlayerStats(otherPlayer)
	return string.format("Level %s  •  Defense %s", level ~= nil and tostring(level) or "—", defense ~= nil and tostring(defense) or "—")
end

local function ReadPlayerListValue(statsFolder, fullName, shortName)
	if not statsFolder then return "—" end
	local valueObject = statsFolder:FindFirstChild(fullName) or statsFolder:FindFirstChild(shortName)
	if not valueObject or not valueObject:IsA("ValueBase") then return "—" end
	local value = valueObject.Value
	if type(value) == "number" then return string.format("%.0f", value) end
	return tostring(value)
end

function configurations.GetPlayerListStatValues(otherPlayer)
	local statsFolder = otherPlayer and otherPlayer:FindFirstChild("PlayerStats")
	return ReadPlayerListValue(statsFolder, "Level", "LVL"),
		ReadPlayerListValue(statsFolder, "Defense", "DEF"),
		ReadPlayerListValue(statsFolder, "Strength", "STR"),
		ReadPlayerListValue(statsFolder, "Agility", "AGI"),
		ReadPlayerListValue(statsFolder, "Luck", "LUK"),
		ReadPlayerListValue(statsFolder, "Vitality", "VIT")
end

function configurations.FormatPlayerListStats(otherPlayer)
	local level, defense, strength, agility, luck, vitality = configurations.GetPlayerListStatValues(otherPlayer)
	return string.format(
		"Lv %s   DEF %s  STR %s  AGI %s  LUK %s  VIT %s",
		level, defense, strength, agility, luck, vitality
	)
end

function configurations.GetPlayerExpProgress(otherPlayer)
	local statsFolder = otherPlayer and otherPlayer:FindFirstChild("PlayerStats")
	if not statsFolder then return nil, nil, nil, 0 end
	local levelObject = statsFolder:FindFirstChild("Level") or statsFolder:FindFirstChild("LVL")
	local expObject = statsFolder:FindFirstChild("EXP") or statsFolder:FindFirstChild("Exp")
	local level = levelObject and tonumber(levelObject.Value)
	local exp = expObject and tonumber(expObject.Value)
	if not level or not exp then return level, exp, nil, 0 end
	local maxExp = configurations.NeededExp(level)
	local ratio = maxExp > 0 and math.clamp(exp / maxExp, 0, 1) or 0
	return level, exp, maxExp, ratio
end

function configurations.GetPlayerPassiveMode(otherPlayer)
	local statsFolder = otherPlayer and otherPlayer:FindFirstChild("PlayerStats")
	local passiveMode = statsFolder and statsFolder:FindFirstChild("PassiveMode")
	if not passiveMode or not passiveMode:IsA("ValueBase") then return nil end
	local value = passiveMode.Value
	if type(value) == "boolean" then return value end
	local normalized = string.lower(tostring(value))
	if normalized == "true" or normalized == "on" or normalized == "1" then return true end
	if normalized == "false" or normalized == "off" or normalized == "0" then return false end
	return nil
end

function configurations.FormatPlayerDisplayName(otherPlayer)
	local passiveMode = configurations.GetPlayerPassiveMode(otherPlayer)
	local passiveText = passiveMode == true and "ON" or (passiveMode == false and "OFF" or "—")
	return otherPlayer.DisplayName .. "  ·  PASSIVE " .. passiveText
end

-- Local player level + EXP progress from PlayerStats and/or the game's HUD ("EXP: 58354/59211").
local HUD_EXP_NAMES = { "EXP", "Exp", "Experience", "EXPLabel", "ExpLabel", "LevelEXP", "LevelExp" }

local LevelProgressCache = {
	ExpLabel = nil,
	LastScanAt = 0,
	LastExp = nil,
	LastMax = nil,
}

local function ParseExpPair(text)
	if type(text) ~= "string" or text == "" then return nil, nil end
	-- Matches: EXP:58354/59211  |  EXP: 58,354 / 59,211  |  58354/59211
	local a, b = string.match(text, "[Ee][Xx][Pp]%s*:?%s*([%d,]+)%s*/%s*([%d,]+)")
	if not a then
		a, b = string.match(text, "^%s*([%d,]+)%s*/%s*([%d,]+)%s*$")
	end
	if not a or not b then return nil, nil end
	local cur = tonumber((a:gsub(",", "")))
	local maxv = tonumber((b:gsub(",", "")))
	if cur and maxv then return cur, maxv end
	return nil, nil
end

local function ReadNumberValue(inst)
	if not inst then return nil end
	-- Prefer .Value on any value-like instance (IntValue, NumberValue, StringValue, constrained, etc.).
	local ok, val = pcall(function()
		return inst.Value
	end)
	if ok and val ~= nil then
		if type(val) == "number" then
			return val
		end
		local n = tonumber(tostring(val):gsub(",", ""):match("[-%d%.]+"))
		if n then return n end
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
		return tonumber((inst.Text or ""):gsub(",", ""):match("[-%d%.]+"))
	end
	-- Nested Value child
	local nested = inst:FindFirstChild("Value")
	if nested then
		return ReadNumberValue(nested)
	end
	return nil
end

local function FindPlayerStatsFolder()
	local stats = Player:FindFirstChild("PlayerStats")
	if stats then return stats end
	-- Case-insensitive / delayed load
	for _, child in ipairs(Player:GetChildren()) do
		if string.lower(child.Name) == "playerstats" then
			return child
		end
	end
	return nil
end

local function FindHudExpLabel(force)
	local now = os.clock()
	if not force and LevelProgressCache.ExpLabel and LevelProgressCache.ExpLabel.Parent then
		return LevelProgressCache.ExpLabel
	end
	if not force and (now - LevelProgressCache.LastScanAt) < 2.5 then
		return LevelProgressCache.ExpLabel
	end
	LevelProgressCache.LastScanAt = now
	local playerGui = Player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end

	local function consider(label)
		if not label or not (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox")) then
			return false
		end
		-- Skip our own UI.
		local ownGui = label:FindFirstAncestor("EXPFarmUI")
		if ownGui then return false end
		local cur, maxv = ParseExpPair(label.Text)
		if cur and maxv and maxv > 0 then
			LevelProgressCache.ExpLabel = label
			return true
		end
		return false
	end

	-- Fast path: GameGui common layout.
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui then
		for _, name in ipairs(HUD_EXP_NAMES) do
			local node = gameGui:FindFirstChild(name, true)
			if node and consider(node) then
				return LevelProgressCache.ExpLabel
			end
			if node then
				for _, child in ipairs(node:GetDescendants()) do
					if consider(child) then
						return LevelProgressCache.ExpLabel
					end
				end
			end
		end
		-- Also scan all GameGui text for EXP:x/y once.
		for _, desc in ipairs(gameGui:GetDescendants()) do
			if consider(desc) then
				return LevelProgressCache.ExpLabel
			end
		end
	end

	-- Broader scan (throttled).
	for _, desc in ipairs(playerGui:GetDescendants()) do
		if consider(desc) then
			return LevelProgressCache.ExpLabel
		end
	end
	return LevelProgressCache.ExpLabel
end

-- Game formula: total EXP required for the given level bar.
function configurations.NeededExp(lvl)
	lvl = tonumber(lvl)
	if not lvl or lvl < 1 then return 9 end
	lvl = math.floor(lvl) - 1
	local total = 9
	for i = 1, lvl do
		total = total + (6 * (i + 2))
	end
	return total
end

function configurations.GetLocalLevelProgress()
	local level, exp, maxExp = nil, nil, nil

	local ok, err = pcall(function()
		local stats = Player:FindFirstChild("PlayerStats")
		if not stats then
			-- Sometimes replicated a moment later / alternate casing
			for _, child in ipairs(Player:GetChildren()) do
				if string.lower(child.Name) == "playerstats" then
					stats = child
					break
				end
			end
		end
		if not stats then
			return
		end

		-- Direct NumberValue read (confirmed: PlayerStats.Level / PlayerStats.EXP)
		local levelInst = stats:FindFirstChild("Level")
		local expInst = stats:FindFirstChild("EXP")
		if not expInst then
			expInst = stats:FindFirstChild("Exp")
		end

		if levelInst then
			level = tonumber(levelInst.Value)
		end
		if expInst then
			exp = tonumber(expInst.Value)
		end

		if level then
			maxExp = configurations.NeededExp(level)
		end
	end)

	if not ok then
		warn("[Iamrich] GetLocalLevelProgress error:", err)
	end

	-- HUD fallback only if stats missing
	if (not level or not exp) then
		local hudOk, hud = pcall(FindHudExpLabel, true)
		if hudOk and hud then
			local cur, maxv = ParseExpPair(hud.Text)
			if cur and not exp then exp = cur end
			if maxv and not maxExp then maxExp = maxv end
		end
	end

	if level and not maxExp then
		maxExp = configurations.NeededExp(level)
	end

	local ratio = nil
	if exp and maxExp and maxExp > 0 then
		ratio = math.clamp(exp / maxExp, 0, 1)
	end
	return level, exp, maxExp, ratio
end


--==================================================
-- COLORS (Tailwind-inspired slate/blue tokens — Roblox Instance UI, not web CSS)
--==================================================
local UIColors = {
	BG = Color3.fromRGB(14, 16, 24),
	SIDEBAR_BG = Color3.fromRGB(10, 12, 20),
	CARD = Color3.fromRGB(22, 26, 38),
	INPUT = Color3.fromRGB(30, 34, 48),
	BORDER = Color3.fromRGB(48, 56, 74),
	TEXT = Color3.fromRGB(240, 244, 252),
	MUTED = Color3.fromRGB(120, 130, 152),
	ACCENT = Color3.fromRGB(88, 166, 255),
	ACCENT_SEL = Color3.fromRGB(140, 190, 255),
	GREEN = Color3.fromRGB(72, 220, 168),
	RED = Color3.fromRGB(255, 96, 118),
	YELLOW = Color3.fromRGB(255, 200, 96),
	ACCENT_DIM = Color3.fromRGB(28, 52, 92),
	GREEN_DIM = Color3.fromRGB(22, 52, 44),
	RED_DIM = Color3.fromRGB(58, 28, 36),
	SEL_BG = Color3.fromRGB(42, 72, 128),
	SEL_TEXT = Color3.fromRGB(230, 240, 255),
}

function configurations.GetHealthColor(current, maximum)
	if not current or not maximum or maximum <= 0 then return UIColors.MUTED end
	local ratio = current / maximum
	if ratio <= 0.25 then return UIColors.RED end
	if ratio <= 0.6 then return UIColors.YELLOW end
	return UIColors.GREEN
end

--==================================================
-- HELPERS
--==================================================
function configurations.FormatNumber(n)
	n = tonumber(n)
	if not n then return "0" end
	local s = tostring(math.floor(n + 0))
	local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if result:sub(1, 1) == "," then
		result = result:sub(2)
	end
	return result
end

function configurations.FormatTime(sec)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = math.floor(sec % 60)
	return string.format("%02d:%02d:%02d", h, m, s)
end

--==================================================
-- BILLBOARD
--==================================================
function configurations.ClearBillboard()
	if configurations.CurrentBillboard then
		pcall(function() configurations.CurrentBillboard:Destroy() end)
		configurations.CurrentBillboard = nil
	end
	configurations.BillboardAdornee = nil
end

function configurations.BuildBillboardText(expValue, isMax)
	local cur = tonumber(expValue) or 0
	local goal = tonumber(configurations.ExpGoal) or 0
	local curText = configurations.FormatNumber(cur)
	local goalText = configurations.FormatNumber(goal)
	if isMax or (goal > 0 and cur >= goal) then
		return "MAX\n" .. curText .. " / " .. goalText, true
	end
	local pct = goal > 0 and math.clamp(cur / goal, 0, 1) * 100 or 0
	return string.format("FARMING\n%s / %s\n%.1f%%", curText, goalText, pct), false
end

-- Fixed on-screen pixel size (does not grow/shrink with camera distance).
local BILLBOARD_WIDTH = 150
local BILLBOARD_HEIGHT = 52

function configurations.AttachBillboard(mob, expValue)
	configurations.ClearBillboard()
	if not mob then return end
	local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return end

	local playerGui = Player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	local bb = Instance.new("BillboardGui")
	bb.Name = "FarmMarker"
	-- Parent to PlayerGui + Adornee keeps Offset size stable in screen pixels.
	bb.Adornee = root
	bb.Size = UDim2.fromOffset(BILLBOARD_WIDTH, BILLBOARD_HEIGHT)
	bb.StudsOffset = Vector3.new(0, 3.4, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 250
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false
	bb.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	bb.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Frame"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Parent = bb
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Name = "Stroke"
	stroke.Color = UIColors.ACCENT
	stroke.Thickness = 1.5

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -8, 1, -4)
	label.Position = UDim2.fromOffset(4, 2)
	label.BackgroundTransparency = 1
	label.TextColor3 = UIColors.ACCENT
	label.TextSize = 12
	label.Font = Enum.Font.GothamBold
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextWrapped = true
	label.Parent = frame

	local text, isMax = configurations.BuildBillboardText(expValue, false)
	label.Text = text
	label.TextColor3 = isMax and UIColors.GREEN or UIColors.ACCENT
	if isMax then stroke.Color = UIColors.GREEN end

	configurations.CurrentBillboard = bb
	configurations.BillboardAdornee = root
end

function configurations.UpdateBillboardText(expValue, isMax)
	local bb = configurations.CurrentBillboard
	if not bb or not bb.Parent then
		configurations.CurrentBillboard = nil
		configurations.BillboardAdornee = nil
		return
	end
	-- Keep adornee on the live root if the mob's PrimaryPart changed.
	local target = configurations.CurrentTarget
	if target and target.Parent then
		local root = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and bb.Adornee ~= root then
			bb.Adornee = root
			configurations.BillboardAdornee = root
		end
	end
	-- Re-assert fixed pixel size (prevents any accidental scale mutation).
	if bb.Size.X.Offset ~= BILLBOARD_WIDTH or bb.Size.Y.Offset ~= BILLBOARD_HEIGHT
		or bb.Size.X.Scale ~= 0 or bb.Size.Y.Scale ~= 0 then
		bb.Size = UDim2.fromOffset(BILLBOARD_WIDTH, BILLBOARD_HEIGHT)
	end
	local label = bb:FindFirstChild("Text", true)
	if not label then return end
	local text, maxed = configurations.BuildBillboardText(expValue, isMax)
	if label.Text ~= text then
		label.Text = text
	end
	label.TextColor3 = maxed and UIColors.GREEN or UIColors.ACCENT
	local stroke = bb:FindFirstChild("Stroke", true)
	if stroke then
		stroke.Color = maxed and UIColors.GREEN or UIColors.ACCENT
	end
end

--==================================================
-- GUI
--==================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "EXPFarmUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 100
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = Player:WaitForChild("PlayerGui")

local Main = Instance.new("Frame")
-- Fixed design size (Fluent-style). GuiScale zooms; does not stretch with the screen.
Main.Size = UDim2.fromOffset(configurations.MainWidthPx or 520, configurations.MainHeightPx or 560)
Main.Position = UDim2.fromScale(0.5, 0.5)
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.ZIndex = 90
Main.BackgroundColor3 = UIColors.BG
Main.BorderSizePixel = 0
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 14)
local MainStroke = Instance.new("UIStroke", Main)
MainStroke.Color = UIColors.BORDER
MainStroke.Thickness = 1
MainStroke.Transparency = 0.35

--==================================================
-- GLOBAL UI SCALE (Tailwind-inspired tokens; applies to ALL windows)
-- GuiScale / TextScale affect Main + floating panels together.
--==================================================
local MainUIScale = Instance.new("UIScale")
MainUIScale.Name = "GuiScale"
MainUIScale.Scale = configurations.GuiScale
MainUIScale.Parent = Main

-- Roots that receive GuiScale (UIScale) and TextScale
configurations.ScaledRoots = { Main }

function configurations.RegisterScaledRoot(root)
	if not root or not root:IsA("GuiObject") then return end
	for _, existing in ipairs(configurations.ScaledRoots) do
		if existing == root then
			-- Ensure UIScale exists
			local scaleObj = root:FindFirstChild("GuiScale")
			if not scaleObj then
				scaleObj = Instance.new("UIScale")
				scaleObj.Name = "GuiScale"
				scaleObj.Parent = root
			end
			scaleObj.Scale = math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
			configurations.ApplyTextScale(root)
			return
		end
	end
	table.insert(configurations.ScaledRoots, root)
	local scaleObj = root:FindFirstChild("GuiScale")
	if not scaleObj then
		scaleObj = Instance.new("UIScale")
		scaleObj.Name = "GuiScale"
		scaleObj.Parent = root
	end
	scaleObj.Scale = math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
	configurations.ApplyTextScale(root)
end

-- UI-wide text scaling. Base sizes are stored once so changing the setting
-- repeatedly never compounds the scale or changes the original design values.
function configurations.ApplyTextScale(root)
	local scale = math.clamp(tonumber(configurations.TextScale) or 1, 0.20, 2.50)
	local function applyTo(target)
		if not target then return end
		for _, obj in ipairs(target:GetDescendants()) do
			if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				if not obj.TextScaled then
					local base = obj:GetAttribute("IamrichBaseTextSize")
					if type(base) ~= "number" then
						base = obj.TextSize
						obj:SetAttribute("IamrichBaseTextSize", base)
					end
					obj.TextSize = math.max(1, math.floor(base * scale + 0.5))
				end
			end
		end
	end
	if root then
		applyTo(root)
		return
	end
	for _, scaledRoot in ipairs(configurations.ScaledRoots) do
		if scaledRoot and scaledRoot.Parent then
			applyTo(scaledRoot)
		end
	end
end

function configurations.GetEffectiveGuiScale()
	local userScale = math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize
	if not viewport or viewport.X < 1 or viewport.Y < 1 then return userScale end
	-- Auto-fit: never grow past design size on large screens; shrink only if the
	-- fixed window would overflow the viewport (Fluent-style fixed UI).
	local designW = tonumber(configurations.MainWidthPx) or 520
	local designH = tonumber(configurations.MainHeightPx) or 560
	local fit = math.min(1, (viewport.X - 24) / designW, (viewport.Y - 24) / designH)
	return math.clamp(userScale * fit, 0.20, 2.50)
end

function configurations.ApplyGuiScale()
	local scale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale()
		or math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize

	for _, root in ipairs(configurations.ScaledRoots) do
		if root and root.Parent then
			local scaleObj = root:FindFirstChild("GuiScale")
			if not scaleObj or not scaleObj:IsA("UIScale") then
				scaleObj = Instance.new("UIScale")
				scaleObj.Name = "GuiScale"
				scaleObj.Parent = root
			end

			local keepCenter = (root == Main) and viewport and viewport.X > 0 and viewport.Y > 0
			local oldCenter = nil
			if keepCenter and root.AbsoluteSize.X > 0 then
				oldCenter = root.AbsolutePosition + root.AbsoluteSize * 0.5
			end

			scaleObj.Scale = scale

			if keepCenter and oldCenter and root.AbsoluteSize.X > 0 then
				local newSize = root.AbsoluteSize
				local px = math.clamp(oldCenter.X - newSize.X * 0.5, 8, math.max(8, viewport.X - newSize.X - 8))
				local py = math.clamp(oldCenter.Y - newSize.Y * 0.5, 8, math.max(8, viewport.Y - newSize.Y - 8))
				root.AnchorPoint = Vector2.new(0, 0)
				root.Position = UDim2.fromOffset(px, py)
			end
		end
	end
end

configurations.SetGuiScale = function(value, save)
	configurations.GuiScale = math.clamp(tonumber(value) or 1, 0.20, 2.50)
	configurations.ApplyGuiScale()
	if save ~= false and configurations.SaveConfig then
		configurations.SaveConfig()
	end
end

configurations.SetTextScale = function(value, save)
	configurations.TextScale = math.clamp(tonumber(value) or 1, 0.20, 2.50)
	configurations.ApplyTextScale() -- all registered windows
	if save ~= false and configurations.SaveConfig then
		configurations.SaveConfig()
	end
end

-- Convert a GuiObject's current position (Scale and/or Offset) into viewport-relative scale
-- using the live camera ViewportSize, then clamp so it stays fully on-screen.
function configurations.GetViewportSize()
	local camera = workspace.CurrentCamera
	if not camera then return Vector2.new(1280, 720) end
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then
		return Vector2.new(1280, 720)
	end
	return viewport
end

function configurations.PositionToScale(guiObject, viewport)
	viewport = viewport or configurations.GetViewportSize()
	local vx = math.max(1, viewport.X)
	local vy = math.max(1, viewport.Y)
	-- Prefer AbsolutePosition when available (works for both Scale and Offset positions).
	local abs = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	local xScale = abs.X / vx
	local yScale = abs.Y / vy
	-- Fallback if Absolute* is not ready yet (e.g. first frame before layout).
	if size.X < 1 and size.Y < 1 then
		xScale = guiObject.Position.X.Scale + guiObject.Position.X.Offset / vx
		yScale = guiObject.Position.Y.Scale + guiObject.Position.Y.Offset / vy
	end
	return xScale, yScale
end

function configurations.ClampPositionScale(xScale, yScale, widthScale, heightScale)
	local maxX = math.max(0, 1 - (widthScale or 0))
	local maxY = math.max(0, 1 - (heightScale or 0))
	return math.clamp(xScale or 0, 0, maxX), math.clamp(yScale or 0, 0, maxY)
end

function configurations.ApplyResponsiveMainSize()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then return end
	local uiScale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale()
		or math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)

	if configurations.IsMinimized then
		local w, h = 300, 136
		local abs = Main.AbsolutePosition
		local px = (Main.AbsoluteSize.X > 0) and abs.X or 8
		local py = (Main.AbsoluteSize.Y > 0) and abs.Y or 8
		px = math.clamp(px, 8, math.max(8, viewport.X - w * uiScale - 8))
		py = math.clamp(py, 8, math.max(8, viewport.Y - h * uiScale - 8))
		Main.AnchorPoint = Vector2.new(0, 0)
		Main.Size = UDim2.fromOffset(w, h)
		Main.Position = UDim2.fromOffset(px, py)
		return
	end

	-- Fixed pixel design size — never stretch to fill the screen.
	local wantW = math.floor(tonumber(configurations.MainWidthPx) or 520)
	local wantH = math.floor(tonumber(configurations.MainHeightPx) or 560)
	local maxW = math.max(360, math.floor((viewport.X - 24) / uiScale))
	local maxH = math.max(320, math.floor((viewport.Y - 24) / uiScale))
	local w = math.clamp(wantW, 360, math.min(900, maxW))
	local h = math.clamp(wantH, 320, math.min(900, maxH))

	local abs = Main.AbsolutePosition
	local px, py
	if Main.AbsoluteSize.X > 0 then
		px, py = abs.X, abs.Y
	else
		px = math.max(8, (viewport.X - w * uiScale) * 0.5)
		py = math.max(8, (viewport.Y - h * uiScale) * 0.5)
	end

	Main.AnchorPoint = Vector2.new(0, 0)
	Main.Size = UDim2.fromOffset(w, h)

	if not configurations.MainWindowInitialized then
		px = math.max(8, (viewport.X - w * uiScale) * 0.5)
		py = math.max(8, (viewport.Y - h * uiScale) * 0.5)
		configurations.MainWindowInitialized = true
	else
		px = math.clamp(px, 8, math.max(8, viewport.X - w * uiScale - 8))
		py = math.clamp(py, 8, math.max(8, viewport.Y - h * uiScale - 8))
	end
	Main.Position = UDim2.fromOffset(px, py)
	configurations.MainWidthScale = w / math.max(1, viewport.X)
	configurations.MainHeightScale = h / math.max(1, viewport.Y)
end

configurations.ApplyResponsiveMainSize()
configurations._ViewportSizeConnection = nil
configurations.BindResponsiveViewport = function()
	local camera = workspace.CurrentCamera
	if configurations._ViewportSizeConnection then
		configurations._ViewportSizeConnection:Disconnect()
		configurations._ViewportSizeConnection = nil
	end
	if not camera then return end
	configurations._ViewportSizeConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		-- Defer one frame so AbsolutePosition/Size settle after the viewport change.
		task.defer(function()
			configurations.ApplyResponsiveMainSize()
			if configurations.ApplyResponsiveOverlaySizes then
				configurations.ApplyResponsiveOverlaySizes()
			end
			if configurations.ApplyGuiScale then
				configurations.ApplyGuiScale()
			end
		end)
	end)
end
configurations.BindResponsiveViewport()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(configurations.BindResponsiveViewport)

--==================================================
-- HEADER (compact)
--==================================================
local Content
local ContentPanel
local Sidebar
local InfoCard, StartBtn, ToggleGrid, SettingsCard
local AlarmOverlay
local HEADER_H = 40
local SIDEBAR_W = 118
local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.Active = true
Header.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
Header.BorderSizePixel = 0
Header.Parent = Main
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 12)

local HeaderFix = Instance.new("Frame")
HeaderFix.Size = UDim2.new(1, 0, 0, 14)
HeaderFix.Position = UDim2.new(0, 0, 1, -14)
HeaderFix.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
HeaderFix.BorderSizePixel = 0
HeaderFix.Parent = Header

local HeaderRule = Instance.new("Frame")
HeaderRule.Size = UDim2.new(1, -20, 0, 1)
HeaderRule.Position = UDim2.new(0, 10, 1, -1)
HeaderRule.BackgroundColor3 = UIColors.BORDER
HeaderRule.BackgroundTransparency = 0.5
HeaderRule.BorderSizePixel = 0
HeaderRule.Parent = Header

local WindowDots = {}
function configurations.MakeWindowDot(xOffset, color)
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Position = UDim2.fromOffset(xOffset, 15)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Parent = Header
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
	table.insert(WindowDots, dot)
	return dot
end
configurations.MakeWindowDot(14, Color3.fromRGB(255, 95, 86))
configurations.MakeWindowDot(30, Color3.fromRGB(255, 190, 46))
configurations.MakeWindowDot(46, Color3.fromRGB(40, 201, 64))

local Title = Instance.new("TextLabel")
Title.Size = UDim2.fromOffset(80, 22)
Title.Position = UDim2.fromOffset(66, 9)
Title.BackgroundTransparency = 1
Title.Text = "EXP+"
Title.TextColor3 = UIColors.TEXT
Title.TextSize = 16
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Subtitle = Instance.new("TextLabel")
Subtitle.Size = UDim2.fromOffset(64, 18)
Subtitle.Position = UDim2.fromOffset(140, 11)
Subtitle.BackgroundTransparency = 1
Subtitle.Text = "v" .. VERSION
Subtitle.TextColor3 = UIColors.MUTED
Subtitle.TextSize = 11
Subtitle.Font = Enum.Font.Gotham
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.Parent = Header

-- Order (right edge): [ Status ON/OFF ] [ − / + ]  — same in full + mini
local Status = Instance.new("TextButton")
Status.Size = UDim2.fromOffset(52, 22)
Status.Position = UDim2.new(1, -88, 0, 9)
Status.BackgroundColor3 = UIColors.RED_DIM
Status.BorderSizePixel = 0
Status.AutoButtonColor = false
Status.Text = "OFF"
Status.TextColor3 = UIColors.RED
Status.TextSize = 11
Status.Font = Enum.Font.GothamBold
Status.Parent = Header
Instance.new("UICorner", Status).CornerRadius = UDim.new(1, 0)

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Size = UDim2.fromOffset(26, 26)
MinimizeBtn.Position = UDim2.new(1, -34, 0, 7)
MinimizeBtn.BackgroundColor3 = UIColors.INPUT
MinimizeBtn.BorderSizePixel = 0
MinimizeBtn.Text = "−"
MinimizeBtn.TextColor3 = UIColors.TEXT
MinimizeBtn.TextSize = 16
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Parent = Header
Instance.new("UICorner", MinimizeBtn).CornerRadius = UDim.new(0, 7)

--==================================================
-- MINI UIColors.CARD (compact EXP box when minimized)
--==================================================
local MINI_WIDTH = 300
local MINI_HEIGHT = 136
local SavedMainPosition = nil

local MiniBar = Instance.new("Frame")
MiniBar.Name = "MiniBar"
MiniBar.Size = UDim2.fromScale(1, 1)
MiniBar.BackgroundTransparency = 1
MiniBar.Visible = false
MiniBar.Parent = Header

-- Top strip: title + status + expand
local MiniTop = Instance.new("Frame")
MiniTop.Size = UDim2.new(1, -16, 0, 28)
MiniTop.Position = UDim2.fromOffset(8, 6)
MiniTop.BackgroundTransparency = 1
MiniTop.Parent = MiniBar

local MiniTitle = Instance.new("TextLabel")
MiniTitle.Size = UDim2.new(0.4, 0, 1, 0)
MiniTitle.BackgroundTransparency = 1
MiniTitle.Text = "EXP+"
MiniTitle.TextColor3 = UIColors.TEXT
MiniTitle.TextSize = 13
MiniTitle.Font = Enum.Font.GothamBold
MiniTitle.TextXAlignment = Enum.TextXAlignment.Left
MiniTitle.Parent = MiniTop

local MiniLevel = Instance.new("TextLabel")
MiniLevel.Name = "MiniLevel"
MiniLevel.Size = UDim2.new(0.55, 0, 0, 14)
MiniLevel.Position = UDim2.fromOffset(10, 30)
MiniLevel.BackgroundTransparency = 1
MiniLevel.Text = "Lv —"
MiniLevel.TextColor3 = UIColors.ACCENT
MiniLevel.TextSize = 11
MiniLevel.Font = Enum.Font.GothamBold
MiniLevel.TextXAlignment = Enum.TextXAlignment.Left
MiniLevel.Parent = MiniBar

-- Big farm EXP number
local MiniExp = Instance.new("TextLabel")
MiniExp.Name = "MiniExp"
MiniExp.Size = UDim2.new(0.58, 0, 0, 28)
MiniExp.Position = UDim2.fromOffset(10, 44)
MiniExp.BackgroundTransparency = 1
MiniExp.Text = "0"
MiniExp.TextColor3 = UIColors.GREEN
MiniExp.TextSize = 24
MiniExp.Font = Enum.Font.GothamBlack
MiniExp.TextXAlignment = Enum.TextXAlignment.Left
MiniExp.Parent = MiniBar

local MiniMax = Instance.new("TextLabel")
MiniMax.Size = UDim2.new(0.55, 0, 0, 14)
MiniMax.Position = UDim2.fromOffset(10, 72)
MiniMax.BackgroundTransparency = 1
MiniMax.Text = "/ " .. configurations.FormatNumber(configurations.ExpGoal)
MiniMax.TextColor3 = UIColors.MUTED
MiniMax.TextSize = 11
MiniMax.Font = Enum.Font.Gotham
MiniMax.TextXAlignment = Enum.TextXAlignment.Left
MiniMax.Parent = MiniBar

-- Right side: elapsed time
local MiniTime = Instance.new("TextLabel")
MiniTime.Name = "MiniTime"
MiniTime.Size = UDim2.new(0.42, 0, 0, 20)
MiniTime.Position = UDim2.new(1, -12, 0, 42)
MiniTime.AnchorPoint = Vector2.new(1, 0)
MiniTime.BackgroundTransparency = 1
MiniTime.Text = "00:00:00"
MiniTime.TextColor3 = UIColors.YELLOW
MiniTime.TextSize = 14
MiniTime.Font = Enum.Font.GothamBold
MiniTime.TextXAlignment = Enum.TextXAlignment.Right
MiniTime.Parent = MiniBar

local MiniState = Instance.new("TextLabel")
MiniState.Name = "MiniState"
MiniState.Size = UDim2.new(1, -20, 0, 14)
MiniState.Position = UDim2.fromOffset(10, 105)
MiniState.AnchorPoint = Vector2.new(0, 0)
MiniState.BackgroundTransparency = 1
MiniState.Text = "Idle"
MiniState.TextColor3 = UIColors.MUTED
MiniState.TextSize = 11
MiniState.Font = Enum.Font.Gotham
MiniState.TextXAlignment = Enum.TextXAlignment.Left
MiniState.Parent = MiniBar

-- Player EXP text (current/max) beside level
local MiniLevelExpLabel = Instance.new("TextLabel")
MiniLevelExpLabel.Name = "MiniLevelExpLabel"
MiniLevelExpLabel.Size = UDim2.new(0.55, 0, 0, 14)
MiniLevelExpLabel.Position = UDim2.fromOffset(70, 30)
MiniLevelExpLabel.BackgroundTransparency = 1
MiniLevelExpLabel.Text = "Exp —/—"
MiniLevelExpLabel.TextColor3 = UIColors.MUTED
MiniLevelExpLabel.TextSize = 11
MiniLevelExpLabel.Font = Enum.Font.Gotham
MiniLevelExpLabel.TextXAlignment = Enum.TextXAlignment.Left
MiniLevelExpLabel.Parent = MiniBar

-- Farm target EXP progress bar only
local MiniBarBg = Instance.new("Frame")
MiniBarBg.Size = UDim2.new(1, -20, 0, 5)
MiniBarBg.Position = UDim2.fromOffset(10, 96)
MiniBarBg.BackgroundColor3 = UIColors.INPUT
MiniBarBg.BorderSizePixel = 0
MiniBarBg.Parent = MiniBar
Instance.new("UICorner", MiniBarBg).CornerRadius = UDim.new(1, 0)

local MiniBarFill = Instance.new("Frame")
MiniBarFill.Name = "MiniBarFill"
MiniBarFill.Size = UDim2.fromScale(0, 1)
MiniBarFill.BackgroundColor3 = UIColors.GREEN
MiniBarFill.BorderSizePixel = 0
MiniBarFill.Parent = MiniBarBg
Instance.new("UICorner", MiniBarFill).CornerRadius = UDim.new(1, 0)

function configurations.ApplyMinimized(state)
	configurations.IsMinimized = state
	if Content then Content.Visible = not state end
	if ContentPanel then ContentPanel.Visible = not state end
	if Sidebar then Sidebar.Visible = not state end
	MiniBar.Visible = state
	Title.Visible = not state
	Subtitle.Visible = not state
	HeaderFix.Visible = not state
	HeaderRule.Visible = not state
	for _, dot in ipairs(WindowDots) do
		dot.Visible = not state
	end
	MinimizeBtn.Text = state and "+" or "−"

	if state then
		-- Save as Scale (from AbsolutePosition) so expand + ViewportSize resize stay correct.
		local viewport = configurations.GetViewportSize and configurations.GetViewportSize()
			or (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize)
			or Vector2.new(1280, 720)
		local sx, sy = configurations.PositionToScale(Main, viewport)
		SavedMainPosition = UDim2.fromScale(sx, sy)
		-- Compact floating card
		Main.Size = UDim2.fromOffset(MINI_WIDTH, MINI_HEIGHT)
		Header.Size = UDim2.fromScale(1, 1)
		Header.BackgroundColor3 = UIColors.BG
		-- Keep near previous top-left, clamp into viewport using pixel x/y
		local px = math.clamp(sx * viewport.X, 8, math.max(8, viewport.X - MINI_WIDTH - 8))
		local py = math.clamp(sy * viewport.Y, 8, math.max(8, viewport.Y - MINI_HEIGHT - 8))
		Main.Position = UDim2.fromOffset(px, py)
		-- Same order as full UI: Status left, expand (+) rightmost
		Status.Position = UDim2.new(1, -84, 0, 8)
		Status.Size = UDim2.fromOffset(48, 20)
		MinimizeBtn.Position = UDim2.new(1, -32, 0, 6)
		MinimizeBtn.Size = UDim2.fromOffset(24, 24)
	else
		Header.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
		Header.Size = UDim2.new(1, 0, 0, HEADER_H)
		configurations.MainWindowInitialized = true
		configurations.ApplyResponsiveMainSize()
		if SavedMainPosition then
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
			local uiScale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale() or 1
			local w = Main.Size.X.Offset
			local h = Main.Size.Y.Offset
			local px = SavedMainPosition.X.Scale * viewport.X + SavedMainPosition.X.Offset
			local py = SavedMainPosition.Y.Scale * viewport.Y + SavedMainPosition.Y.Offset
			px = math.clamp(px, 8, math.max(8, viewport.X - w * uiScale - 8))
			py = math.clamp(py, 8, math.max(8, viewport.Y - h * uiScale - 8))
			Main.AnchorPoint = Vector2.new(0, 0)
			Main.Position = UDim2.fromOffset(px, py)
		end
		Status.Position = UDim2.new(1, -84, 0, 9)
		Status.Size = UDim2.fromOffset(48, 22)
		MinimizeBtn.Position = UDim2.new(1, -32, 0, 8)
		MinimizeBtn.Size = UDim2.fromOffset(24, 24)
	end
	local resizeHandle = Main:FindFirstChild("ResizeHandle")
	if resizeHandle then resizeHandle.Visible = not state end
end

configurations.IsMinimized = configurations.SavedMinimized
MinimizeBtn.MouseButton1Click:Connect(function()
	configurations.ApplyMinimized(not configurations.IsMinimized)
	configurations.SaveConfig()
end)

-- Drag
local Dragging = false
local DragStart = nil
local StartPos = nil

Header.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	Dragging = true
	DragStart = input.Position
	StartPos = Main.AbsolutePosition

	input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End then
			Dragging = false
		end
	end)
end)

UserInputService.InputChanged:Connect(function(input)
	if not Dragging then
		return
	end

	if input.UserInputType ~= Enum.UserInputType.MouseMovement
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	local parent = Main.Parent
	if not parent then
		return
	end

	local parentSize = parent.AbsoluteSize
	local mainSize = Main.AbsoluteSize
	local delta = input.Position - DragStart

	local x = StartPos.X + delta.X
	local y = StartPos.Y + delta.Y

	x = math.clamp(
		x,
		0,
		math.max(0, parentSize.X - mainSize.X)
	)

	y = math.clamp(
		y,
		0,
		math.max(0, parentSize.Y - mainSize.Y)
	)

	Main.AnchorPoint = Vector2.new(0, 0)
	Main.Position = UDim2.fromOffset(x, y)
end)

--==================================================
-- CONTENT
--==================================================
-- Right content panel (dark like the image)
ContentPanel = Instance.new("Frame")
ContentPanel.Name = "ContentPanel"
ContentPanel.Size = UDim2.new(1, -(SIDEBAR_W + 20), 1, -(HEADER_H + 12))
ContentPanel.Position = UDim2.fromOffset(SIDEBAR_W + 12, HEADER_H + 6)
ContentPanel.BackgroundColor3 = Color3.fromRGB(15, 17, 25)
ContentPanel.BorderSizePixel = 0
ContentPanel.Parent = Main
Instance.new("UICorner", ContentPanel).CornerRadius = UDim.new(0, 10)

Content = Instance.new("Frame")
Content.Name = "MainContent"
Content.Size = UDim2.fromScale(1, 1)
Content.Position = UDim2.fromScale(0, 0)
Content.BackgroundTransparency = 1
Content.BorderSizePixel = 0
Content.Parent = ContentPanel

local ContentPad = Instance.new("UIPadding")
ContentPad.PaddingTop = UDim.new(0, 12)
ContentPad.PaddingLeft = UDim.new(0, 14)
ContentPad.PaddingRight = UDim.new(0, 14)
ContentPad.PaddingBottom = UDim.new(0, 14)
ContentPad.Parent = Content

configurations.ApplyMinimized(configurations.IsMinimized)

local Pages = {}
local PageLayouts = {}
function configurations.CreatePage(name, visible)
	local page = Instance.new("ScrollingFrame")
	page.Name = name .. "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 4
	page.ScrollBarImageColor3 = UIColors.BORDER
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.Visible = visible
	page.Parent = Content
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = page
	Pages[name] = page
	PageLayouts[name] = layout
	return page
end

local ExpPage = configurations.CreatePage("EXP", true)
local ESPPage = configurations.CreatePage("ESP", false)
local PlayerPage = configurations.CreatePage("Player", false)
local AlertsPage = configurations.CreatePage("Alerts", false)
local FarmPage = configurations.CreatePage("Farm", false)
local CombatPage = configurations.CreatePage("Combat", false)
local WaypointPage = configurations.CreatePage("Waypoint", false)
local PerformancePage = configurations.CreatePage("Performance", false)

function configurations.AddPageHeading(page, title, description)
	local heading = Instance.new("Frame")
	heading.Size = UDim2.new(1, 0, 0, 40)
	heading.LayoutOrder = 1
	heading.BackgroundTransparency = 1
	heading.Parent = page
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -8, 0, 20)
	titleLabel.Position = UDim2.fromOffset(2, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = UIColors.TEXT
	titleLabel.TextSize = 16
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = heading
	local descriptionLabel = Instance.new("TextLabel")
	descriptionLabel.Size = UDim2.new(1, -8, 0, 16)
	descriptionLabel.Position = UDim2.fromOffset(2, 20)
	descriptionLabel.BackgroundTransparency = 1
	descriptionLabel.Text = description
	descriptionLabel.TextColor3 = UIColors.MUTED
	descriptionLabel.TextSize = 11
	descriptionLabel.Font = Enum.Font.Gotham
	descriptionLabel.TextXAlignment = Enum.TextXAlignment.Left
	descriptionLabel.TextTruncate = Enum.TextTruncate.AtEnd
	descriptionLabel.Parent = heading
	return heading
end

configurations.AddPageHeading(ExpPage, "Overview", "Level, EXP, server status and active farm session")
configurations.AddPageHeading(ESPPage, "ESP", "Player markers, lines and boxes on screen")
configurations.AddPageHeading(PlayerPage, "Players", "Follow, whitelist, server players and block settings")
configurations.AddPageHeading(AlertsPage, "Alerts & Safety", "Nearby alerts and join log")
configurations.AddPageHeading(FarmPage, "EXP Farm", "Cycle, range, timing and target behavior")
configurations.AddPageHeading(CombatPage, "Combat", "Auto attack, skills, Boss and Miniboss targeting")
configurations.AddPageHeading(WaypointPage, "Waypoint", "Pin a position and return when displaced")
configurations.AddPageHeading(PerformancePage, "Performance", "Reduce graphics load for higher FPS")

Sidebar = Instance.new("Frame")
Sidebar.Name = "Navigation"
Sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -(HEADER_H + 12))
Sidebar.Position = UDim2.fromOffset(8, HEADER_H + 6)
Sidebar.BackgroundColor3 = UIColors.SIDEBAR_BG
Sidebar.BorderSizePixel = 0
Sidebar.Visible = not configurations.IsMinimized
Sidebar.Parent = Main
Instance.new("UICorner", Sidebar).CornerRadius = UDim.new(0, 10)

-- Sidebar scroll for many items
local SidebarScroll = Instance.new("ScrollingFrame")
SidebarScroll.Name = "SidebarScroll"
SidebarScroll.Size = UDim2.fromScale(1, 1)
SidebarScroll.BackgroundTransparency = 1
SidebarScroll.BorderSizePixel = 0
SidebarScroll.ScrollBarThickness = 3
SidebarScroll.ScrollBarImageColor3 = UIColors.MUTED
SidebarScroll.CanvasSize = UDim2.new()
SidebarScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SidebarScroll.ScrollingDirection = Enum.ScrollingDirection.Y
SidebarScroll.Parent = Sidebar

local SidebarLayout = Instance.new("UIListLayout")
SidebarLayout.Padding = UDim.new(0, 3)
SidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
SidebarLayout.Parent = SidebarScroll

local SidebarPad = Instance.new("UIPadding")
SidebarPad.PaddingTop = UDim.new(0, 8)
SidebarPad.PaddingLeft = UDim.new(0, 8)
SidebarPad.PaddingRight = UDim.new(0, 8)
SidebarPad.PaddingBottom = UDim.new(0, 14)
SidebarPad.Parent = SidebarScroll

function configurations.MakeNavSection(text, order)
	-- Section header (not clickable) — visually distinct from nav buttons
	local wrap = Instance.new("Frame")
	wrap.Name = "Section_" .. text
	wrap.Size = UDim2.new(1, 0, 0, 30)
	wrap.LayoutOrder = order
	wrap.BackgroundTransparency = 1
	wrap.Parent = SidebarScroll

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -14, 0, 14)
	label.Position = UDim2.fromOffset(10, 12)
	label.BackgroundTransparency = 1
	label.Text = string.upper(text)
	label.TextColor3 = Color3.fromRGB(98, 112, 142)
	label.TextSize = 10
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTransparency = 0
	label.Parent = wrap

	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -20, 0, 1)
	line.Position = UDim2.fromOffset(10, 28)
	line.BackgroundColor3 = UIColors.BORDER
	line.BackgroundTransparency = 0.4
	line.BorderSizePixel = 0
	line.Parent = wrap
	return wrap
end

function configurations.MakeNavButton(text, icon, order)
	local button = Instance.new("TextButton")
	button.Name = "Nav_" .. text
	button.Size = UDim2.new(1, 0, 0, 34)
	button.LayoutOrder = order
	button.BackgroundColor3 = UIColors.SEL_BG
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Parent = SidebarScroll
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Label"
	textLabel.Size = UDim2.new(1, -22, 1, 0)
	textLabel.Position = UDim2.fromOffset(12, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextColor3 = UIColors.MUTED
	textLabel.TextSize = 13
	textLabel.Font = Enum.Font.GothamMedium
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.Parent = button

	return button
end

-- Categories ordered for daily use: status → farm → social → movement → visuals
configurations.MakeNavSection("Main", 1)
local NavButtons = {
	EXP = configurations.MakeNavButton("Overview", nil, 2),
}
configurations.MakeNavSection("Farm", 3)
NavButtons.Farm   = configurations.MakeNavButton("EXP Farm", nil, 4)
NavButtons.Combat = configurations.MakeNavButton("Combat", nil, 5)
configurations.MakeNavSection("Social", 6)
NavButtons.Player = configurations.MakeNavButton("Players", nil, 7)
NavButtons.Alerts = configurations.MakeNavButton("Alerts", nil, 8)
if configurations.PartySystem then
	NavButtons.Party = configurations.MakeNavButton("Party", nil, 9)
end
configurations.MakeNavSection("Movement", 10)
NavButtons.Waypoint = configurations.MakeNavButton("Waypoint", nil, 11)
if configurations.TeleportSystem then
	NavButtons.Teleport = configurations.MakeNavButton("Teleport", nil, 12)
end
if configurations.PartySystem and type(configurations.PartySystem.BuildServerUI) == "function" then
	NavButtons.Server = configurations.MakeNavButton("Server", nil, configurations.TeleportSystem and 13 or 12)
end
configurations.MakeNavSection("Visuals", configurations.TeleportSystem and 14 or 13)
NavButtons.ESP = configurations.MakeNavButton("ESP", nil, configurations.TeleportSystem and 15 or 14)
NavButtons.Performance = configurations.MakeNavButton("Performance", nil, configurations.TeleportSystem and 16 or 15)

function configurations.SetMainTab(tab)
	for name, page in pairs(Pages) do
		page.Visible = name == tab
		if page.Visible then page.CanvasPosition = Vector2.zero end
	end
	for name, button in pairs(NavButtons) do
		local selected = name == tab
		button.BackgroundTransparency = selected and 0 or 1
		button.BackgroundColor3 = UIColors.SEL_BG
		local label = button:FindFirstChild("Label")
		if label then
			label.TextColor3 = selected and UIColors.SEL_TEXT or UIColors.MUTED
			label.Font = selected and Enum.Font.GothamBold or Enum.Font.GothamMedium
		end
		local accent = button:FindFirstChild("SelAccent")
		if not accent then
			accent = Instance.new("Frame")
			accent.Name = "SelAccent"
			accent.Size = UDim2.new(0, 3, 0.55, 0)
			accent.Position = UDim2.new(0, 4, 0.225, 0)
			accent.BackgroundColor3 = UIColors.ACCENT
			accent.BorderSizePixel = 0
			accent.Parent = button
			Instance.new("UICorner", accent).CornerRadius = UDim.new(1, 0)
		end
		accent.Visible = selected
	end
	if tab == "Combat" and configurations.RefreshCombatMobs then
		configurations.RefreshCombatMobs()
	end
end

for name, button in pairs(NavButtons) do
	button.MouseButton1Click:Connect(function() configurations.SetMainTab(name) end)
end
configurations.SetMainTab("EXP")

--==================================================
-- SERVER STATUS WIDGET
--==================================================
local ServerCard = Instance.new("Frame")
ServerCard.Name = "ServerCard"
ServerCard.Size = UDim2.new(1, 0, 0, 78)
ServerCard.LayoutOrder = 2
ServerCard.BackgroundColor3 = UIColors.CARD
ServerCard.BorderSizePixel = 0
ServerCard.Parent = ExpPage
Instance.new("UICorner", ServerCard).CornerRadius = UDim.new(0, 12)
local ServerStroke = Instance.new("UIStroke", ServerCard)
ServerStroke.Color = UIColors.BORDER
ServerStroke.Thickness = 1
ServerStroke.Transparency = 0.45

local ServerTitle = Instance.new("TextLabel")
ServerTitle.Size = UDim2.new(0.5, -12, 0, 14)
ServerTitle.Position = UDim2.fromOffset(14, 10)
ServerTitle.BackgroundTransparency = 1
ServerTitle.Text = "SERVER"
ServerTitle.TextColor3 = UIColors.ACCENT
ServerTitle.TextSize = 12
ServerTitle.Font = Enum.Font.GothamBold
ServerTitle.TextXAlignment = Enum.TextXAlignment.Left
ServerTitle.Parent = ServerCard

local ServerPlayersLabel = Instance.new("TextLabel")
ServerPlayersLabel.Name = "ServerPlayers"
ServerPlayersLabel.Size = UDim2.fromOffset(134, 26)
ServerPlayersLabel.Position = UDim2.new(1, -148, 0, 5)
ServerPlayersLabel.BackgroundColor3 = UIColors.ACCENT_DIM
ServerPlayersLabel.BorderSizePixel = 0
ServerPlayersLabel.Text = "0 PLAYERS"
ServerPlayersLabel.TextColor3 = UIColors.ACCENT
ServerPlayersLabel.TextSize = 14
ServerPlayersLabel.Font = Enum.Font.GothamBold
ServerPlayersLabel.TextXAlignment = Enum.TextXAlignment.Center
ServerPlayersLabel.Parent = ServerCard
Instance.new("UICorner", ServerPlayersLabel).CornerRadius = UDim.new(0, 7)

local ServerPlaceLabel = Instance.new("TextLabel")
ServerPlaceLabel.Name = "ServerPlace"
ServerPlaceLabel.Size = UDim2.new(1, -28, 0, 18)
ServerPlaceLabel.Position = UDim2.fromOffset(14, 29)
ServerPlaceLabel.BackgroundTransparency = 1
ServerPlaceLabel.Text = "—"
ServerPlaceLabel.TextColor3 = UIColors.TEXT
ServerPlaceLabel.TextSize = 13
ServerPlaceLabel.Font = Enum.Font.GothamMedium
ServerPlaceLabel.TextXAlignment = Enum.TextXAlignment.Left
ServerPlaceLabel.TextTruncate = Enum.TextTruncate.AtEnd
ServerPlaceLabel.Parent = ServerCard

local ServerJobLabel = Instance.new("TextLabel")
ServerJobLabel.Name = "ServerJob"
ServerJobLabel.Size = UDim2.new(1, -28, 0, 12)
ServerJobLabel.Position = UDim2.fromOffset(14, 49)
ServerJobLabel.BackgroundTransparency = 1
ServerJobLabel.Text = "Job —"
ServerJobLabel.TextColor3 = UIColors.MUTED
ServerJobLabel.TextSize = 11
ServerJobLabel.Font = Enum.Font.Gotham
ServerJobLabel.TextXAlignment = Enum.TextXAlignment.Left
ServerJobLabel.TextTruncate = Enum.TextTruncate.AtEnd
ServerJobLabel.Parent = ServerCard

configurations.ServerFPSLabel = Instance.new("TextLabel")
configurations.ServerFPSLabel.Name = "ServerFPS"
configurations.ServerFPSLabel.Size = UDim2.fromOffset(92, 18)
configurations.ServerFPSLabel.Position = UDim2.fromOffset(14, 67)
configurations.ServerFPSLabel.BackgroundColor3 = UIColors.INPUT
configurations.ServerFPSLabel.BorderSizePixel = 0
configurations.ServerFPSLabel.Text = "FPS --"
configurations.ServerFPSLabel.TextColor3 = UIColors.GREEN
configurations.ServerFPSLabel.TextSize = 12
configurations.ServerFPSLabel.Font = Enum.Font.GothamBold
configurations.ServerFPSLabel.TextXAlignment = Enum.TextXAlignment.Center
configurations.ServerFPSLabel.Parent = ServerCard
Instance.new("UICorner", configurations.ServerFPSLabel).CornerRadius = UDim.new(0, 6)

configurations.ServerPingLabel = Instance.new("TextLabel")
configurations.ServerPingLabel.Name = "ServerPing"
configurations.ServerPingLabel.Size = UDim2.fromOffset(104, 18)
configurations.ServerPingLabel.Position = UDim2.fromOffset(112, 67)
configurations.ServerPingLabel.BackgroundColor3 = UIColors.INPUT
configurations.ServerPingLabel.BorderSizePixel = 0
configurations.ServerPingLabel.Text = "Ping -- ms"
configurations.ServerPingLabel.TextColor3 = UIColors.ACCENT
configurations.ServerPingLabel.TextSize = 12
configurations.ServerPingLabel.Font = Enum.Font.GothamBold
configurations.ServerPingLabel.TextXAlignment = Enum.TextXAlignment.Center
configurations.ServerPingLabel.Parent = ServerCard
Instance.new("UICorner", configurations.ServerPingLabel).CornerRadius = UDim.new(0, 6)

function configurations.RefreshServerWidget()
	local count = #Players:GetPlayers()
	ServerPlayersLabel.Text = string.format("%d PLAYERS", count)
	local placeName = "Place " .. tostring(game.PlaceId)
	pcall(function()
		local info = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		if info and info.Name then placeName = info.Name end
	end)
	ServerPlaceLabel.Text = placeName
	local job = tostring(game.JobId or "")
	if #job > 18 then job = job:sub(1, 8) .. "…" .. job:sub(-6) end
	ServerJobLabel.Text = "Job " .. (job ~= "" and job or "—") .. "  ·  PlaceId " .. tostring(game.PlaceId)
end
configurations.RefreshServerWidget()
Players.PlayerAdded:Connect(function() configurations.RefreshServerWidget() end)
Players.PlayerRemoving:Connect(function() task.defer(configurations.RefreshServerWidget) end)

configurations.ServerFPSFrames = 0
configurations.ServerFPSSampleAt = os.clock()
RunService.RenderStepped:Connect(function()
	configurations.ServerFPSFrames += 1
	local sampleAt = os.clock()
	local elapsed = sampleAt - configurations.ServerFPSSampleAt
	if elapsed < 1 then return end
	local fps = math.floor(configurations.ServerFPSFrames / elapsed + 0.5)
	configurations.ServerFPSFrames = 0
	configurations.ServerFPSSampleAt = sampleAt
	configurations.ServerFPSLabel.Text = string.format("FPS %d", fps)
	configurations.ServerFPSLabel.TextColor3 = fps >= 50 and UIColors.GREEN or (fps >= 30 and UIColors.YELLOW or UIColors.RED)

	local pingOk, pingSeconds = pcall(function()
		return Player:GetNetworkPing()
	end)
	if pingOk and type(pingSeconds) == "number" then
		local pingMs = math.floor(pingSeconds * 1000 + 0.5)
		configurations.ServerPingLabel.Text = string.format("Ping %d ms", pingMs)
		configurations.ServerPingLabel.TextColor3 = pingMs < 100 and UIColors.GREEN or (pingMs < 200 and UIColors.YELLOW or UIColors.RED)
	else
		configurations.ServerPingLabel.Text = "Ping -- ms"
		configurations.ServerPingLabel.TextColor3 = UIColors.MUTED
	end
end)

--==================================================
-- HERO EXP UIColors.CARD (big numbers)
--==================================================
InfoCard = Instance.new("Frame")
InfoCard.Size = UDim2.new(1, 0, 0, 190)
InfoCard.LayoutOrder = 3
InfoCard.BackgroundColor3 = UIColors.CARD
InfoCard.BorderSizePixel = 0
InfoCard.Parent = ExpPage
Instance.new("UICorner", InfoCard).CornerRadius = UDim.new(0, 12)
local InfoStroke = Instance.new("UIStroke", InfoCard)
InfoStroke.Color = UIColors.BORDER
InfoStroke.Thickness = 1
InfoStroke.Transparency = 0.45

-- Player level + Exp current/max (no separate level progress bar)
local LevelCaption = Instance.new("TextLabel")
LevelCaption.Size = UDim2.new(0.5, -12, 0, 12)
LevelCaption.Position = UDim2.fromOffset(12, 6)
LevelCaption.BackgroundTransparency = 1
LevelCaption.Text = "YOUR LEVEL"
LevelCaption.TextColor3 = UIColors.ACCENT
LevelCaption.TextSize = 11
LevelCaption.Font = Enum.Font.GothamBold
LevelCaption.TextXAlignment = Enum.TextXAlignment.Left
LevelCaption.Parent = InfoCard

local LevelLabel = Instance.new("TextLabel")
LevelLabel.Name = "LevelLabel"
LevelLabel.Size = UDim2.new(0.45, -8, 0, 22)
LevelLabel.Position = UDim2.fromOffset(12, 18)
LevelLabel.BackgroundTransparency = 1
LevelLabel.Text = "Lv —"
LevelLabel.TextColor3 = UIColors.TEXT
LevelLabel.TextSize = 18
LevelLabel.Font = Enum.Font.GothamBlack
LevelLabel.TextXAlignment = Enum.TextXAlignment.Left
LevelLabel.Parent = InfoCard

local LevelExpText = Instance.new("TextLabel")
LevelExpText.Name = "LevelExpText"
LevelExpText.Size = UDim2.new(0.55, -12, 0, 22)
LevelExpText.Position = UDim2.new(0.45, 0, 0, 18)
LevelExpText.BackgroundTransparency = 1
LevelExpText.Text = "Exp —/—"
LevelExpText.TextColor3 = UIColors.MUTED
LevelExpText.TextSize = 13
LevelExpText.Font = Enum.Font.GothamBold
LevelExpText.TextXAlignment = Enum.TextXAlignment.Right
LevelExpText.Parent = InfoCard

-- Big farm EXP number (target mob EXP toward goal)
local ExpCaption = Instance.new("TextLabel")
ExpCaption.Size = UDim2.new(1, -20, 0, 12)
ExpCaption.Position = UDim2.fromOffset(10, 44)
ExpCaption.BackgroundTransparency = 1
ExpCaption.Text = "FARM EXP"
ExpCaption.TextColor3 = UIColors.ACCENT
ExpCaption.TextSize = 11
ExpCaption.Font = Enum.Font.GothamBold
ExpCaption.TextXAlignment = Enum.TextXAlignment.Center
ExpCaption.Parent = InfoCard

local ExpLabel = Instance.new("TextLabel")
ExpLabel.Size = UDim2.new(1, -20, 0, 40)
ExpLabel.Position = UDim2.fromOffset(10, 56)
ExpLabel.BackgroundTransparency = 1
ExpLabel.Text = "0"
ExpLabel.TextColor3 = UIColors.GREEN
ExpLabel.TextSize = 32
ExpLabel.Font = Enum.Font.GothamBlack
ExpLabel.TextXAlignment = Enum.TextXAlignment.Center
ExpLabel.Parent = InfoCard

local MaxLabel = Instance.new("TextLabel")
MaxLabel.Size = UDim2.new(1, -20, 0, 14)
MaxLabel.Position = UDim2.fromOffset(10, 96)
MaxLabel.BackgroundTransparency = 1
MaxLabel.Text = "/ " .. configurations.FormatNumber(configurations.ExpGoal)
MaxLabel.TextColor3 = UIColors.MUTED
MaxLabel.TextSize = 12
MaxLabel.Font = Enum.Font.Gotham
MaxLabel.TextXAlignment = Enum.TextXAlignment.Center
MaxLabel.Parent = InfoCard

-- Farm target progress bar only
local BarBg = Instance.new("Frame")
BarBg.Size = UDim2.new(1, -28, 0, 8)
BarBg.Position = UDim2.fromOffset(14, 114)
BarBg.BackgroundColor3 = UIColors.INPUT
BarBg.BorderSizePixel = 0
BarBg.Parent = InfoCard
Instance.new("UICorner", BarBg).CornerRadius = UDim.new(1, 0)

local Bar = Instance.new("Frame")
Bar.Size = UDim2.fromScale(0, 1)
Bar.BackgroundColor3 = UIColors.GREEN
Bar.BorderSizePixel = 0
Bar.Parent = BarBg
Instance.new("UICorner", Bar).CornerRadius = UDim.new(1, 0)

local PercentLabel = Instance.new("TextLabel")
PercentLabel.Size = UDim2.new(1, 0, 0, 14)
PercentLabel.Position = UDim2.fromOffset(0, 126)
PercentLabel.BackgroundTransparency = 1
PercentLabel.Text = "0%"
PercentLabel.TextColor3 = UIColors.MUTED
PercentLabel.TextSize = 11
PercentLabel.Font = Enum.Font.GothamBold
PercentLabel.TextXAlignment = Enum.TextXAlignment.Center
PercentLabel.Parent = InfoCard

-- Meta row 1: Target + Dist
local TargetLabel = Instance.new("TextLabel")
TargetLabel.Size = UDim2.new(0.58, -8, 0, 16)
TargetLabel.Position = UDim2.fromOffset(12, 146)
TargetLabel.BackgroundTransparency = 1
TargetLabel.Text = "No target"
TargetLabel.TextColor3 = UIColors.TEXT
TargetLabel.TextSize = 12
TargetLabel.Font = Enum.Font.GothamBold
TargetLabel.TextXAlignment = Enum.TextXAlignment.Left
TargetLabel.TextTruncate = Enum.TextTruncate.AtEnd
TargetLabel.Parent = InfoCard

local DistLabel = Instance.new("TextLabel")
DistLabel.Size = UDim2.new(0.42, -12, 0, 16)
DistLabel.Position = UDim2.new(0.58, 0, 0, 146)
DistLabel.BackgroundTransparency = 1
DistLabel.Text = "Dist  -"
DistLabel.TextColor3 = UIColors.MUTED
DistLabel.TextSize = 11
DistLabel.Font = Enum.Font.Gotham
DistLabel.TextXAlignment = Enum.TextXAlignment.Right
DistLabel.Parent = InfoCard

-- Meta row 2: Time + Rate
local TimeLabel = Instance.new("TextLabel")
TimeLabel.Size = UDim2.new(0.38, -4, 0, 15)
TimeLabel.Position = UDim2.fromOffset(12, 166)
TimeLabel.BackgroundTransparency = 1
TimeLabel.Text = "00:00:00"
TimeLabel.TextColor3 = UIColors.YELLOW
TimeLabel.TextSize = 11
TimeLabel.Font = Enum.Font.GothamBold
TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
TimeLabel.Parent = InfoCard

local RateLabel = Instance.new("TextLabel")
RateLabel.Size = UDim2.new(0.32, -4, 0, 15)
RateLabel.Position = UDim2.new(0.36, 0, 0, 166)
RateLabel.BackgroundTransparency = 1
RateLabel.Text = "Rate -"
RateLabel.TextColor3 = UIColors.MUTED
RateLabel.TextSize = 11
RateLabel.Font = Enum.Font.Gotham
RateLabel.TextXAlignment = Enum.TextXAlignment.Center
RateLabel.Parent = InfoCard

local StateLabel = Instance.new("TextLabel")
StateLabel.Size = UDim2.new(1, -24, 0, 14)
StateLabel.Position = UDim2.fromOffset(12, 184)
StateLabel.BackgroundTransparency = 1
StateLabel.Text = "Idle"
StateLabel.TextColor3 = UIColors.MUTED
StateLabel.TextSize = 11
StateLabel.Font = Enum.Font.Gotham
StateLabel.TextXAlignment = Enum.TextXAlignment.Left
StateLabel.Parent = InfoCard

-- Session + recent
local SessionLabel = Instance.new("TextLabel")
SessionLabel.Size = UDim2.new(1, -24, 0, 14)
SessionLabel.Position = UDim2.fromOffset(12, 204)
SessionLabel.BackgroundTransparency = 1
SessionLabel.Text = "Session: +0 EXP / 00:00:00 / 0 EXP/h"
SessionLabel.TextColor3 = UIColors.MUTED
SessionLabel.TextSize = 11
SessionLabel.Font = Enum.Font.Gotham
SessionLabel.TextXAlignment = Enum.TextXAlignment.Left
SessionLabel.Parent = InfoCard

local RecentCycleLabel = Instance.new("TextLabel")
RecentCycleLabel.Size = UDim2.new(1, -24, 0, 14)
RecentCycleLabel.Position = UDim2.fromOffset(12, 222)
RecentCycleLabel.BackgroundTransparency = 1
RecentCycleLabel.Text = configurations.RecentCycle
RecentCycleLabel.TextColor3 = UIColors.MUTED
RecentCycleLabel.TextSize = 11
RecentCycleLabel.Font = Enum.Font.Gotham
RecentCycleLabel.TextXAlignment = Enum.TextXAlignment.Left
RecentCycleLabel.Parent = InfoCard

--==================================================
-- START BUTTON
--==================================================
StartBtn = Instance.new("TextButton")
StartBtn.Size = UDim2.new(1, 0, 0, 44)
StartBtn.LayoutOrder = 3
StartBtn.BackgroundColor3 = UIColors.ACCENT
StartBtn.BorderSizePixel = 0
StartBtn.Text = "Start"
StartBtn.TextColor3 = Color3.new(1, 1, 1)
StartBtn.TextSize = 15
StartBtn.Font = Enum.Font.GothamBold
StartBtn.Parent = ExpPage
Instance.new("UICorner", StartBtn).CornerRadius = UDim.new(0, 11)
local StartStroke = Instance.new("UIStroke", StartBtn)
StartStroke.Color = Color3.fromRGB(140, 190, 255)
StartStroke.Transparency = 0.65
StartStroke.Thickness = 1

local EmergencyStopButton = Instance.new("TextButton")
EmergencyStopButton.Size = UDim2.new(1, 0, 0, 36)
EmergencyStopButton.LayoutOrder = 4
EmergencyStopButton.BackgroundColor3 = UIColors.CARD
EmergencyStopButton.BorderSizePixel = 0
EmergencyStopButton.Text = "Emergency stop: OFF"
EmergencyStopButton.TextColor3 = UIColors.MUTED
EmergencyStopButton.TextSize = 12
EmergencyStopButton.Font = Enum.Font.GothamBold
EmergencyStopButton.Parent = ExpPage
Instance.new("UICorner", EmergencyStopButton).CornerRadius = UDim.new(0, 10)
local EmergencyStroke = Instance.new("UIStroke", EmergencyStopButton)
EmergencyStroke.Color = UIColors.BORDER
EmergencyStroke.Transparency = 0.55
EmergencyStroke.Thickness = 1

--==================================================
-- TOGGLE LIST (label left, switch right)
--==================================================
ToggleGrid = Instance.new("Frame")
ToggleGrid.Size = UDim2.new(1, 0, 0, 0)
ToggleGrid.AutomaticSize = Enum.AutomaticSize.Y
ToggleGrid.LayoutOrder = 2
ToggleGrid.BackgroundTransparency = 1
ToggleGrid.Parent = ESPPage
local ToggleGridLayout = Instance.new("UIListLayout", ToggleGrid)
ToggleGridLayout.Padding = UDim.new(0, 8)
ToggleGridLayout.SortOrder = Enum.SortOrder.LayoutOrder

function configurations.MakeToggleGrid(parent, order)
	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = order
	grid.BackgroundTransparency = 1
	grid.Parent = parent
	local layout = Instance.new("UIListLayout", grid)
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	return grid
end

local AlertsGrid = configurations.MakeToggleGrid(AlertsPage, 2)
local PlayersGrid = configurations.MakeToggleGrid(PlayerPage, 2)
local CombatGrid = configurations.MakeToggleGrid(CombatPage, 2)
local PerformanceGrid = configurations.MakeToggleGrid(PerformancePage, 2)

local AlertsDistanceCard = Instance.new("Frame")
AlertsDistanceCard.Size = UDim2.new(1, 0, 0, 48)
AlertsDistanceCard.LayoutOrder = 3
AlertsDistanceCard.BackgroundColor3 = UIColors.CARD
AlertsDistanceCard.BorderSizePixel = 0
AlertsDistanceCard.Parent = AlertsPage
Instance.new("UICorner", AlertsDistanceCard).CornerRadius = UDim.new(0, 8)

local AlertsDistanceLabel = Instance.new("TextLabel")
AlertsDistanceLabel.Size = UDim2.new(0.58, -16, 1, 0)
AlertsDistanceLabel.Position = UDim2.new(0, 10, 0, 0)
AlertsDistanceLabel.BackgroundTransparency = 1
AlertsDistanceLabel.Text = "Player alert range (studs)"
AlertsDistanceLabel.TextColor3 = UIColors.TEXT
AlertsDistanceLabel.TextSize = 11
AlertsDistanceLabel.Font = Enum.Font.Gotham
AlertsDistanceLabel.TextXAlignment = Enum.TextXAlignment.Left
AlertsDistanceLabel.Parent = AlertsDistanceCard

local AlertsDistanceInput = Instance.new("TextBox")
AlertsDistanceInput.Size = UDim2.new(0.36, -8, 0, 30)
AlertsDistanceInput.Position = UDim2.new(0.62, 0, 0.5, -15)
AlertsDistanceInput.BackgroundColor3 = UIColors.INPUT
AlertsDistanceInput.BorderSizePixel = 0
AlertsDistanceInput.Text = tostring(configurations.AlertsDistance)
AlertsDistanceInput.TextColor3 = UIColors.TEXT
AlertsDistanceInput.TextSize = 12
AlertsDistanceInput.Font = Enum.Font.GothamBold
AlertsDistanceInput.ClearTextOnFocus = false
AlertsDistanceInput.Parent = AlertsDistanceCard
Instance.new("UICorner", AlertsDistanceInput).CornerRadius = UDim.new(0, 6)
AlertsDistanceInput.FocusLost:Connect(function()
	local value = tonumber(AlertsDistanceInput.Text)
	if value and value >= 0 then
		configurations.AlertsDistance = math.clamp(math.floor(value), 0, 100000)
	end
	AlertsDistanceInput.Text = tostring(configurations.AlertsDistance)
	configurations.SaveConfig()
end)

function configurations.SetToggleVisual(btn, title, isOn, onColor, onBg)
	if not btn then return end
	local titleLabel = btn:FindFirstChild("Title")
	local switch = btn:FindFirstChild("Switch")
	local knob = switch and switch:FindFirstChild("Knob")
	local clean = title or btn:GetAttribute("BaseTitle") or ""
	clean = tostring(clean):gsub("%s*:?%s*ON%s*$", ""):gsub("%s*:?%s*OFF%s*$", "")
	if titleLabel then
		titleLabel.Text = clean
		titleLabel.TextColor3 = UIColors.TEXT
	end
	btn:SetAttribute("BaseTitle", clean)
	btn:SetAttribute("IsOn", isOn and true or false)
	btn.BackgroundColor3 = UIColors.CARD
	btn.Text = ""
	if switch then
		-- Always use accent blue for ON (Slayers2-style), gray for OFF
		switch.BackgroundColor3 = isOn and UIColors.ACCENT or Color3.fromRGB(55, 60, 78)
		if knob then
			knob.Position = isOn and UDim2.new(1, -20, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
		end
	end
end

function configurations.MakeToggle(text, isOn, onColor, onBg, order, parent, description)
	local clean = tostring(text or ""):gsub("%s*:?%s*ON%s*$", ""):gsub("%s*:?%s*OFF%s*$", "")
	local hasDesc = type(description) == "string" and description ~= ""
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, hasDesc and 64 or 48)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = UIColors.CARD
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent or ToggleGrid
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = UIColors.BORDER
	stroke.Transparency = 0.55
	stroke.Thickness = 1

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -72, 0, hasDesc and 20 or 48)
	titleLabel.Position = UDim2.fromOffset(16, hasDesc and 10 or 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = clean
	titleLabel.TextColor3 = UIColors.TEXT
	titleLabel.TextSize = 14
	titleLabel.Font = Enum.Font.GothamMedium
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = hasDesc and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Parent = btn

	if hasDesc then
		local descLabel = Instance.new("TextLabel")
		descLabel.Name = "Desc"
		descLabel.Size = UDim2.new(1, -72, 0, 22)
		descLabel.Position = UDim2.fromOffset(16, 30)
		descLabel.BackgroundTransparency = 1
		descLabel.Text = description
		descLabel.TextColor3 = UIColors.MUTED
		descLabel.TextSize = 11
		descLabel.Font = Enum.Font.Gotham
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.TextYAlignment = Enum.TextYAlignment.Top
		descLabel.TextWrapped = true
		descLabel.Parent = btn
	end

	local switch = Instance.new("Frame")
	switch.Name = "Switch"
	switch.Size = UDim2.fromOffset(44, 24)
	switch.Position = UDim2.new(1, -58, 0.5, -12)
	switch.BackgroundColor3 = isOn and UIColors.ACCENT or Color3.fromRGB(55, 60, 78)
	switch.BorderSizePixel = 0
	switch.Parent = btn
	Instance.new("UICorner", switch).CornerRadius = UDim.new(1, 0)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(20, 20)
	knob.Position = isOn and UDim2.new(1, -20, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
	knob.BackgroundColor3 = Color3.fromRGB(250, 250, 255)
	knob.BorderSizePixel = 0
	knob.Parent = switch
	Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

	btn:SetAttribute("BaseTitle", clean)
	btn:SetAttribute("IsOn", isOn and true or false)
	return btn
end

if configurations.TeleportSystem then
	configurations.TeleportSystem.BuildUI({
		CARD = UIColors.CARD,
		INPUT = UIColors.INPUT,
		BORDER = UIColors.BORDER,
		TEXT = UIColors.TEXT,
		MUTED = UIColors.MUTED,
		ACCENT = UIColors.ACCENT,
		ACCENT_DIM = UIColors.ACCENT_DIM,
		RED = UIColors.RED,
	})
end

if configurations.PartySystem then
	configurations.PartySystem.BuildUI({
		CARD = UIColors.CARD,
		INPUT = UIColors.INPUT,
		BORDER = UIColors.BORDER,
		TEXT = UIColors.TEXT,
		MUTED = UIColors.MUTED,
		ACCENT = UIColors.ACCENT,
		ACCENT_DIM = UIColors.ACCENT_DIM,
		RED = UIColors.RED,
	})
	if type(configurations.PartySystem.BuildServerUI) == "function" then
		configurations.PartySystem.BuildServerUI({
		CARD = UIColors.CARD,
		INPUT = UIColors.INPUT,
		BORDER = UIColors.BORDER,
		TEXT = UIColors.TEXT,
		MUTED = UIColors.MUTED,
		ACCENT = UIColors.ACCENT,
		ACCENT_DIM = UIColors.ACCENT_DIM,
		RED = UIColors.RED,
		})
	else
		warn("[Iamrich] Server list UI is unavailable; update PartySystem.lua to v1.1.0 or newer.")
	end
end

-- Action row: title + description + chevron (opens a panel / runs an action — not a switch)
function configurations.SetActionVisual(btn, title, accented)
	if not btn then return end
	local titleLabel = btn:FindFirstChild("Title")
	local clean = tostring(title or btn:GetAttribute("BaseTitle") or "")
	if titleLabel then
		titleLabel.Text = clean
		titleLabel.TextColor3 = accented and UIColors.ACCENT or UIColors.TEXT
	end
	btn:SetAttribute("BaseTitle", clean)
	btn.BackgroundColor3 = accented and UIColors.ACCENT_DIM or UIColors.CARD
	btn.Text = ""
end

function configurations.MakeActionRow(text, order, parent, description)
	local clean = tostring(text or "")
	local hasDesc = type(description) == "string" and description ~= ""
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, hasDesc and 64 or 48)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = UIColors.CARD
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = UIColors.BORDER
	stroke.Transparency = 0.55
	stroke.Thickness = 1

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -48, 0, hasDesc and 20 or 48)
	titleLabel.Position = UDim2.fromOffset(16, hasDesc and 10 or 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = clean
	titleLabel.TextColor3 = UIColors.TEXT
	titleLabel.TextSize = 14
	titleLabel.Font = Enum.Font.GothamMedium
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = hasDesc and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Parent = btn

	if hasDesc then
		local descLabel = Instance.new("TextLabel")
		descLabel.Name = "Desc"
		descLabel.Size = UDim2.new(1, -48, 0, 22)
		descLabel.Position = UDim2.fromOffset(16, 30)
		descLabel.BackgroundTransparency = 1
		descLabel.Text = description
		descLabel.TextColor3 = UIColors.MUTED
		descLabel.TextSize = 11
		descLabel.Font = Enum.Font.Gotham
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.TextYAlignment = Enum.TextYAlignment.Top
		descLabel.TextWrapped = true
		descLabel.Parent = btn
	end

	local chevron = Instance.new("TextLabel")
	chevron.Name = "Chevron"
	chevron.Size = UDim2.fromOffset(24, 24)
	chevron.Position = UDim2.new(1, -34, 0.5, -12)
	chevron.BackgroundTransparency = 1
	chevron.Text = ">"
	chevron.TextColor3 = UIColors.MUTED
	chevron.TextSize = 16
	chevron.Font = Enum.Font.GothamBold
	chevron.Parent = btn

	btn:SetAttribute("BaseTitle", clean)
	btn:SetAttribute("IsAction", true)
	return btn
end

function configurations.MakeNumberCard(parent, title, initialValue, order, minValue, maxValue, onChanged)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 52)
	card.LayoutOrder = order
	card.BackgroundColor3 = UIColors.CARD
	card.BorderSizePixel = 0
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
	local cardStroke = Instance.new("UIStroke", card)
	cardStroke.Color = UIColors.BORDER
	cardStroke.Transparency = 0.65
	cardStroke.Thickness = 1

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.58, -16, 1, 0)
	label.Position = UDim2.new(0, 16, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = UIColors.TEXT
	label.TextSize = 13
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = card

	local input = Instance.new("TextBox")
	input.Size = UDim2.new(0.34, -8, 0, 30)
	input.Position = UDim2.new(0.64, 0, 0.5, -15)
	input.BackgroundColor3 = UIColors.INPUT
	input.BorderSizePixel = 0
	input.Text = tostring(initialValue())
	input.TextColor3 = UIColors.TEXT
	input.TextSize = 12
	input.Font = Enum.Font.GothamBold
	input.ClearTextOnFocus = false
	input.Parent = card
	Instance.new("UICorner", input).CornerRadius = UDim.new(0, 6)
	input.FocusLost:Connect(function()
		local value = tonumber(input.Text)
		if value and value >= minValue then onChanged(math.clamp(math.floor(value), minValue, maxValue)) end
		input.Text = tostring(initialValue())
		configurations.SaveConfig()
	end)
	return card, input
end

local WaypointInfo = Instance.new("TextLabel")
WaypointInfo.Size = UDim2.new(1, -12, 0, 34)
WaypointInfo.LayoutOrder = 2
WaypointInfo.BackgroundTransparency = 1
WaypointInfo.TextColor3 = UIColors.MUTED
WaypointInfo.TextSize = 12
WaypointInfo.Font = Enum.Font.Gotham
WaypointInfo.TextWrapped = true
WaypointInfo.TextXAlignment = Enum.TextXAlignment.Left
WaypointInfo.Parent = WaypointPage

local WaypointMarker = Instance.new("Part")
WaypointMarker.Name = "IamrichWaypoint"
WaypointMarker.Anchored = true
WaypointMarker.CanCollide = false
WaypointMarker.CanTouch = false
WaypointMarker.CanQuery = false
WaypointMarker.Size = Vector3.new(0.8, 0.8, 0.8)
WaypointMarker.Shape = Enum.PartType.Ball
WaypointMarker.Material = Enum.Material.Neon
WaypointMarker.Color = UIColors.ACCENT
WaypointMarker.Transparency = 0.15
WaypointMarker.CastShadow = false
WaypointMarker.Parent = workspace

local WaypointBillboard = Instance.new("BillboardGui")
WaypointBillboard.Name = "WaypointBillboard"
WaypointBillboard.Adornee = WaypointMarker
WaypointBillboard.AlwaysOnTop = true
WaypointBillboard.LightInfluence = 0
WaypointBillboard.MaxDistance = 250
WaypointBillboard.Size = UDim2.fromOffset(40, 40)
WaypointBillboard.StudsOffset = Vector3.new(0, 1.6, 0)
WaypointBillboard.ResetOnSpawn = false
WaypointBillboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
WaypointBillboard.Parent = Player:FindFirstChildOfClass("PlayerGui")

local WaypointBillboardFrame = Instance.new("Frame")
WaypointBillboardFrame.Name = "Frame"
WaypointBillboardFrame.Size = UDim2.fromScale(1, 1)
WaypointBillboardFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
WaypointBillboardFrame.BackgroundTransparency = 0.12
WaypointBillboardFrame.BorderSizePixel = 0
WaypointBillboardFrame.Parent = WaypointBillboard

local WaypointBillboardCorner = Instance.new("UICorner")
WaypointBillboardCorner.CornerRadius = UDim.new(0, 8)
WaypointBillboardCorner.Parent = WaypointBillboardFrame

local WaypointBillboardStroke = Instance.new("UIStroke")
WaypointBillboardStroke.Color = UIColors.ACCENT
WaypointBillboardStroke.Name = "Stroke"
WaypointBillboardStroke.Thickness = 1.5
WaypointBillboardStroke.Parent = WaypointBillboardFrame

local WaypointBillboardDot = Instance.new("Frame")
WaypointBillboardDot.Name = "Dot"
WaypointBillboardDot.AnchorPoint = Vector2.new(0.5, 0.5)
WaypointBillboardDot.Position = UDim2.fromScale(0.5, 0.5)
WaypointBillboardDot.Size = UDim2.fromOffset(12, 12)
WaypointBillboardDot.BackgroundColor3 = UIColors.ACCENT
WaypointBillboardDot.BorderSizePixel = 0
WaypointBillboardDot.Parent = WaypointBillboardFrame
local WaypointBillboardDotCorner = Instance.new("UICorner")
WaypointBillboardDotCorner.CornerRadius = UDim.new(1, 0)
WaypointBillboardDotCorner.Parent = WaypointBillboardDot

local function UpdateWaypointMarker()
	local point = configurations.WaypointPosition
	local visible = point ~= nil and configurations.WaypointBillboardEnabled
	WaypointMarker.Position = point or Vector3.zero
	WaypointMarker.Transparency = visible and 0.15 or 1
	WaypointBillboard.Enabled = visible
end

local WaypointBillboardButton = configurations.MakeToggle(
	"Show waypoint marker",
	configurations.WaypointBillboardEnabled,
	UIColors.ACCENT,
	UIColors.ACCENT_DIM,
	3,
	WaypointPage,
	"Show or hide the pinned point in the world."
)

local ReturnToWaypointButton = configurations.MakeToggle(
	"Return to waypoint",
	configurations.WaypointReturnEnabled,
	UIColors.ACCENT,
	UIColors.ACCENT_DIM,
	4,
	WaypointPage,
	"Walk back to the pinned position when displaced."
)

local function UpdateWaypointInfo()
	local point = configurations.WaypointPosition
	UpdateWaypointMarker()
	WaypointInfo.Text = not point and "No waypoint set"
		or (configurations.WaypointReturnEnabled and configurations.PartyWaypointSuspended
			and "Return paused while searching for Party Leader" or "Waypoint set")
	configurations.SetToggleVisual(
		ReturnToWaypointButton,
		"Return to waypoint",
		configurations.WaypointReturnEnabled,
		UIColors.ACCENT,
		UIColors.ACCENT_DIM
	)
	configurations.SetToggleVisual(
		WaypointBillboardButton,
		"Show waypoint marker",
		configurations.WaypointBillboardEnabled,
		UIColors.ACCENT,
		UIColors.ACCENT_DIM
	)
end

local SetWaypointButton = configurations.MakeActionRow(
	"Pin current position",
	5,
	WaypointPage,
	"Save where you are standing as the return point."
)
SetWaypointButton.MouseButton1Click:Connect(function()
	local character = Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	configurations.WaypointPosition = root.Position
	configurations.WaypointReturnEnabled = true
	UpdateWaypointInfo()
	configurations.SaveWaypointConfig()
	configurations.SaveConfig()
end)

local ClearWaypointButton = configurations.MakeActionRow("Clear waypoint", 6, WaypointPage)
ClearWaypointButton.MouseButton1Click:Connect(function()
	configurations.WaypointPosition = nil
	configurations.WaypointReturnEnabled = false
	configurations.WaypointNavigator.Reset()
	UpdateWaypointInfo()
	configurations.SaveWaypointConfig()
	configurations.SaveConfig()
end)

WaypointBillboardButton.MouseButton1Click:Connect(function()
	configurations.WaypointBillboardEnabled = not configurations.WaypointBillboardEnabled
	UpdateWaypointInfo()
	configurations.SaveConfig()
end)
ReturnToWaypointButton.MouseButton1Click:Connect(function()
	if not configurations.WaypointPosition then
		configurations.WaypointReturnEnabled = false
		UpdateWaypointInfo()
		return
	end
	configurations.WaypointReturnEnabled = not configurations.WaypointReturnEnabled
	UpdateWaypointInfo()
	configurations.SaveWaypointConfig()
	configurations.SaveConfig()
end)
UpdateWaypointInfo()

local FollowDistanceCard, FollowDistanceInput = configurations.MakeNumberCard(
	PlayerPage, "Follow spacing (studs)", function() return configurations.FollowDistance end, 3, 2, 100,
	function(value) configurations.FollowDistance = value end
)
local FollowTargetButton = configurations.MakeToggle(
	"Show follow target",
	configurations.FollowTargetVisible,
	UIColors.ACCENT,
	UIColors.ACCENT_DIM,
	6,
	PlayersGrid,
	"Draw a line to the current follow position."
)
FollowTargetButton.MouseButton1Click:Connect(function()
	configurations.FollowTargetVisible = not configurations.FollowTargetVisible
	configurations.SetToggleVisual(FollowTargetButton, "Show follow target", configurations.FollowTargetVisible, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.FollowSystem.SetTargetLineVisible(configurations.FollowTargetVisible)
	configurations.SaveConfig()
end)

local AutoAttackButton = configurations.MakeToggle("Auto attack", configurations.AutoAttackEnabled, UIColors.RED, UIColors.RED_DIM, 1, CombatGrid, "Move to and attack selected or marked mobs.")
local AutoSkillButton = configurations.MakeToggle("Auto skill", configurations.AutoSkillEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 2, CombatGrid, "Use skills while attacking the current target.")
local AutoBossTargetButton = configurations.MakeToggle("Boss", configurations.AutoBossTargetEnabled, UIColors.RED, UIColors.RED_DIM, 4, CombatGrid, "Auto-target Boss mobs and move in to attack.")
local AutoMiniBossTargetButton = configurations.MakeToggle("Miniboss", configurations.AutoMiniBossTargetEnabled, UIColors.RED, UIColors.RED_DIM, 5, CombatGrid, "Auto-target Miniboss mobs and move in to attack.")

local AutoAttackRangeCard, AutoAttackRangeInput = configurations.MakeNumberCard(
	CombatPage, "Attack target range (studs)", function() return configurations.AutoAttackRange end, 6, 5, 500,
	function(value) configurations.AutoAttackRange = value end
)

local AutoAttackSearchRangeCard, AutoAttackSearchRangeInput = configurations.MakeNumberCard(
	CombatPage, "Mob visibility range (studs)", function() return configurations.AutoAttackSearchRange end, 7, 5, 1000,
	function(value) configurations.AutoAttackSearchRange = value end
)

local AutoAttackIntervalCard, AutoAttackIntervalInput = configurations.MakeNumberCard(
	CombatPage, "Attack interval (seconds)", function() return configurations.AutoAttackInterval end, 8, 1, 10,
	function(value) configurations.AutoAttackInterval = value end
)

local AutoSkillIntervalCard, AutoSkillIntervalInput = configurations.MakeNumberCard(
	CombatPage, "Skill interval (seconds)", function() return configurations.AutoSkillInterval end, 9, 1, 30,
	function(value) configurations.AutoSkillInterval = value end
)

local CombatMobHeading = Instance.new("Frame")
CombatMobHeading.Size = UDim2.new(1, 0, 0, 30)
CombatMobHeading.LayoutOrder = 10
CombatMobHeading.BackgroundTransparency = 1
CombatMobHeading.Parent = CombatPage

local CombatMobTitle = Instance.new("TextLabel")
CombatMobTitle.Size = UDim2.new(0.65, 0, 1, 0)
CombatMobTitle.BackgroundTransparency = 1
CombatMobTitle.Text = "Available mobs"
CombatMobTitle.TextColor3 = UIColors.TEXT
CombatMobTitle.TextSize = 12
CombatMobTitle.Font = Enum.Font.GothamBold
CombatMobTitle.TextXAlignment = Enum.TextXAlignment.Left
CombatMobTitle.Parent = CombatMobHeading

local CombatMobRefresh = Instance.new("TextButton")
CombatMobRefresh.Size = UDim2.new(0.32, 0, 1, 0)
CombatMobRefresh.Position = UDim2.new(0.68, 0, 0, 0)
CombatMobRefresh.BackgroundColor3 = UIColors.INPUT
CombatMobRefresh.BorderSizePixel = 0
CombatMobRefresh.Text = "Refresh list"
CombatMobRefresh.TextColor3 = UIColors.TEXT
CombatMobRefresh.TextSize = 11
CombatMobRefresh.Font = Enum.Font.GothamBold
CombatMobRefresh.Parent = CombatMobHeading
Instance.new("UICorner", CombatMobRefresh).CornerRadius = UDim.new(0, 7)

local CombatMobScroll = Instance.new("ScrollingFrame")
CombatMobScroll.Size = UDim2.new(1, 0, 0, 120)
CombatMobScroll.LayoutOrder = 9
CombatMobScroll.BackgroundColor3 = UIColors.CARD
CombatMobScroll.BorderSizePixel = 0
CombatMobScroll.ScrollBarThickness = 3
CombatMobScroll.ScrollBarImageColor3 = UIColors.MUTED
CombatMobScroll.CanvasSize = UDim2.new()
CombatMobScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
CombatMobScroll.ScrollingDirection = Enum.ScrollingDirection.Y
CombatMobScroll.Parent = CombatPage
Instance.new("UICorner", CombatMobScroll).CornerRadius = UDim.new(0, 8)

local CombatMobListLayout = Instance.new("UIListLayout")
CombatMobListLayout.Padding = UDim.new(0, 4)
CombatMobListLayout.SortOrder = Enum.SortOrder.LayoutOrder
CombatMobListLayout.Parent = CombatMobScroll

configurations.CombatMobRows = {}
configurations.CombatMobUI = { RowByMob = {}, RefreshQueued = false, LastRefreshAt = 0, ListDirty = true }
function configurations.SyncCombatMobRowSelection()
	for mob, row in pairs(configurations.CombatMobUI.RowByMob) do
		if row.Parent then
			local selected = configurations.SelectedCombatMob == mob
			row.BackgroundColor3 = selected and UIColors.ACCENT_DIM or UIColors.INPUT
			row.TextColor3 = selected and UIColors.ACCENT or UIColors.TEXT
			row.Text = selected and row:GetAttribute("SelectedText") or row:GetAttribute("BaseText")
		end
	end
end

function configurations.RefreshCombatMobs()
	if not CombatPage.Visible then return end
	if not configurations.CombatMobUI.ListDirty then
		configurations.SyncCombatMobRowSelection()
		return
	end
	configurations.CombatMobUI.ListDirty = false
	for _, row in ipairs(configurations.CombatMobRows) do
		row:Destroy()
	end
	table.clear(configurations.CombatMobRows)
	table.clear(configurations.CombatMobUI.RowByMob)

	local entries = {}
	local groupCounts = {}
	local groupHasLevels = {}
	local function numericValue(value)
		if typeof(value) == "Instance" then
			if value:IsA("ValueBase") then
				return tonumber((value :: any).Value)
			end
			return nil
		end
		return tonumber(value)
	end
	local function readLevel(source)
		if not source or typeof(source) ~= "Instance" then return nil end
		local level = numericValue(source:GetAttribute("Level")) or numericValue(source:GetAttribute("LV"))
		if level then return level end
		local levelValue = source:FindFirstChild("Level") or source:FindFirstChild("LV")
		return numericValue(levelValue)
	end

	local localCharacter = Player.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
	for _, mob in ipairs(MobsFolder:GetChildren()) do
		local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		local visibleDistance = localRoot and root and (localRoot.Position - root.Position).Magnitude or math.huge
		if root and root:IsA("BasePart") and visibleDistance <= configurations.AutoAttackSearchRange and (not humanoid or humanoid.Health > 0) then
			local cfg = mob:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			local entity = cfg and cfg:FindFirstChild("Entity")
			local entityValue = entity and entity.Value
			local entityName = typeof(entityValue) == "Instance" and entityValue.Name or (entityValue ~= nil and tostring(entityValue) or mob.Name)
			local key = string.lower(entityName)
			local entry = {
				Mob = mob,
				Name = entityName,
				Key = key,
				EXP = exp and tonumber(exp.Value) or -math.huge,
				Level = readLevel(mob) or readLevel(cfg) or readLevel(entityValue),
			}
			table.insert(entries, entry)
			groupCounts[key] = (groupCounts[key] or 0) + 1
			if groupHasLevels[key] == nil then groupHasLevels[key] = true end
			if not entry.Level then groupHasLevels[key] = false end
		end
	end

	table.sort(entries, function(a, b)
		local aUnique = groupCounts[a.Key] == 1
		local bUnique = groupCounts[b.Key] == 1
		if aUnique ~= bUnique then return aUnique end
		if a.Key ~= b.Key then return a.Key < b.Key end
		if not aUnique then
			if groupHasLevels[a.Key] and a.Level ~= b.Level then return a.Level > b.Level end
			if a.EXP ~= b.EXP then return a.EXP > b.EXP end
		end
		return a.Mob.Name < b.Mob.Name
	end)

	for order, entry in ipairs(entries) do
		local selectedMob = entry.Mob
		local isSelectedMob = configurations.SelectedCombatMob == selectedMob
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -8, 0, 30)
		row.LayoutOrder = order
		row.BackgroundColor3 = isSelectedMob and UIColors.ACCENT_DIM or UIColors.INPUT
		row.BorderSizePixel = 0
		local baseText = string.format("%s  •  Lv %s  •  EXP %s", entry.Name,
			entry.Level and tostring(entry.Level) or "—", entry.EXP > -math.huge and tostring(entry.EXP) or "—")
		row:SetAttribute("BaseText", baseText)
		row:SetAttribute("SelectedText", "✓  " .. baseText)
		row.Text = isSelectedMob and ("✓  " .. baseText) or baseText
		row.TextColor3 = isSelectedMob and UIColors.ACCENT or UIColors.TEXT
		row.TextSize = 11
		row.Font = Enum.Font.Gotham
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Parent = CombatMobScroll
		configurations.CombatMobUI.RowByMob[selectedMob] = row
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
		row.MouseButton1Click:Connect(function()
			if not selectedMob:IsDescendantOf(MobsFolder) then
				configurations.CombatMobUI.ListDirty = true
				configurations.RefreshCombatMobs()
				return
			end
			configurations.SelectedCombatMob = selectedMob
			configurations.SaveConfig()
			configurations.RefreshCombatMobs()
		end)
		table.insert(configurations.CombatMobRows, row)
	end
	if #entries == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -8, 0, 30)
		empty.BackgroundTransparency = 1
		empty.Text = "No mobs found in this server"
		empty.TextColor3 = UIColors.MUTED
		empty.TextSize = 11
		empty.Font = Enum.Font.Gotham
		empty.Parent = CombatMobScroll
		table.insert(configurations.CombatMobRows, empty)
	end
end

function configurations.RequestCombatMobRefresh()
	configurations.CombatMobUI.ListDirty = true
	if configurations.CombatMobUI.RefreshQueued or not CombatPage.Visible then return end
	configurations.CombatMobUI.RefreshQueued = true
	local delay = math.max(0.12, 0.45 - (os.clock() - configurations.CombatMobUI.LastRefreshAt))
	task.delay(delay, function()
		configurations.CombatMobUI.RefreshQueued = false
		if CombatMobScroll.Parent and CombatPage.Visible then
			configurations.CombatMobUI.LastRefreshAt = os.clock()
			configurations.RefreshCombatMobs()
		end
	end)
end

CombatMobRefresh.MouseButton1Click:Connect(function()
	configurations.CombatMobUI.ListDirty = true
	configurations.RefreshCombatMobs()
end)
MobsFolder.ChildAdded:Connect(configurations.RequestCombatMobRefresh)
MobsFolder.ChildRemoved:Connect(configurations.RequestCombatMobRefresh)
configurations.RefreshCombatMobs()

configurations.CombatStatusCard = Instance.new("Frame")
configurations.CombatStatusCard.Size = UDim2.new(1, 0, 0, 78)
configurations.CombatStatusCard.LayoutOrder = 10
configurations.CombatStatusCard.BackgroundColor3 = UIColors.CARD
configurations.CombatStatusCard.BorderSizePixel = 0
configurations.CombatStatusCard.Parent = CombatPage
Instance.new("UICorner", configurations.CombatStatusCard).CornerRadius = UDim.new(0, 8)
configurations.CombatStatusStroke = Instance.new("UIStroke", configurations.CombatStatusCard)
configurations.CombatStatusStroke.Color = UIColors.INPUT
configurations.CombatStatusStroke.Transparency = 0.35

configurations.CombatStatusAccent = Instance.new("Frame")
configurations.CombatStatusAccent.Size = UDim2.new(0, 3, 1, -18)
configurations.CombatStatusAccent.Position = UDim2.fromOffset(8, 9)
configurations.CombatStatusAccent.BackgroundColor3 = UIColors.ACCENT
configurations.CombatStatusAccent.BorderSizePixel = 0
configurations.CombatStatusAccent.Parent = configurations.CombatStatusCard
Instance.new("UICorner", configurations.CombatStatusAccent).CornerRadius = UDim.new(1, 0)

configurations.CombatStatusTitle = Instance.new("TextLabel")
configurations.CombatStatusTitle.Size = UDim2.new(1, -28, 0, 16)
configurations.CombatStatusTitle.Position = UDim2.fromOffset(19, 7)
configurations.CombatStatusTitle.BackgroundTransparency = 1
configurations.CombatStatusTitle.Text = "COMBAT STATUS"
configurations.CombatStatusTitle.TextColor3 = UIColors.ACCENT
configurations.CombatStatusTitle.TextSize = 11
configurations.CombatStatusTitle.Font = Enum.Font.GothamBold
configurations.CombatStatusTitle.TextXAlignment = Enum.TextXAlignment.Left
configurations.CombatStatusTitle.Parent = configurations.CombatStatusCard

configurations.CombatInfo = Instance.new("TextLabel")
configurations.CombatInfo.Size = UDim2.new(1, -28, 0, 49)
configurations.CombatInfo.Position = UDim2.fromOffset(19, 23)
configurations.CombatInfo.BackgroundTransparency = 1
configurations.CombatInfo.Text = "Targets selected mobs or enabled Boss / Miniboss markers; moves with MoveTo and attacks while closing in."
configurations.CombatInfo.TextColor3 = UIColors.TEXT
configurations.CombatInfo.TextSize = 11
configurations.CombatInfo.Font = Enum.Font.Gotham
configurations.CombatInfo.TextWrapped = true
configurations.CombatInfo.TextXAlignment = Enum.TextXAlignment.Left
configurations.CombatInfo.TextYAlignment = Enum.TextYAlignment.Top
configurations.CombatInfo.Parent = configurations.CombatStatusCard

configurations.LastCombatStatusUpdate = 0

function configurations.UpdateCombatStatus(target, targetRoot, distance, navigationState, moveState)
	local now = os.clock()
	if now - configurations.LastCombatStatusUpdate < 0.18 then return end
	configurations.LastCombatStatusUpdate = now
	if not target or not targetRoot then
		configurations.CombatInfo.Text = configurations.Farming and "Combat paused during EXP firing."
			or ((configurations.AutoBossTargetEnabled or configurations.AutoMiniBossTargetEnabled)
				and "Searching for Boss / Miniboss targets..."
				or (configurations.AutoAttackEnabled and "Select a mob from the list to start moving and attacking."
					or "Auto attack is off."))
		return
	end
	local action = navigationState == "detouring" and "going around obstacle"
		or (moveState and moveState.Active and "moving to mob" or "tracking selected mob")
	local ready, needsEquip = configurations.Combat.GetWeaponEquipState(Player.Character)
	local weapon = ready and "weapon ready" or (needsEquip and "equipping weapon" or "weapon unavailable")
	configurations.CombatInfo.Text = string.format("Mob: %s\n%.0f studs · %s · %s", target.Name, distance or 0, action, weapon)
end

AutoAttackButton.MouseButton1Click:Connect(function()
	configurations.AutoAttackEnabled = not configurations.AutoAttackEnabled
	configurations.SetToggleVisual(AutoAttackButton, "Auto attack", configurations.AutoAttackEnabled, UIColors.RED, UIColors.RED_DIM)
	configurations.SaveConfig()
end)

AutoSkillButton.MouseButton1Click:Connect(function()
	configurations.AutoSkillEnabled = not configurations.AutoSkillEnabled
	configurations.SetToggleVisual(AutoSkillButton, "Auto skill", configurations.AutoSkillEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.SaveConfig()
end)

AutoBossTargetButton.MouseButton1Click:Connect(function()
	configurations.AutoBossTargetEnabled = not configurations.AutoBossTargetEnabled
	configurations.SetToggleVisual(AutoBossTargetButton, "Boss", configurations.AutoBossTargetEnabled, UIColors.RED, UIColors.RED_DIM)
	configurations.SaveConfig()
end)

AutoMiniBossTargetButton.MouseButton1Click:Connect(function()
	configurations.AutoMiniBossTargetEnabled = not configurations.AutoMiniBossTargetEnabled
	configurations.SetToggleVisual(AutoMiniBossTargetButton, "Miniboss", configurations.AutoMiniBossTargetEnabled, UIColors.RED, UIColors.RED_DIM)
	configurations.SaveConfig()
end)

local AlertToggleButton = configurations.MakeToggle("Player alert", configurations.AlertsEnabled, UIColors.GREEN, UIColors.GREEN_DIM, 1, AlertsGrid, "Alert when a non-whitelisted player gets close.")
local AlertFlashButton = configurations.MakeToggle("Screen flash", configurations.AlertFlashEnabled, UIColors.RED, UIColors.RED_DIM, 2, AlertsGrid, "Flash the screen when an alert triggers.")
local AutoResumeButton = configurations.MakeToggle("Auto resume", configurations.AutoResumeAfterAlert, UIColors.ACCENT, UIColors.ACCENT_DIM, 3, AlertsGrid, "Off: press Start yourself after the Alert clears.")
configurations.JoinAlertButton = configurations.MakeToggle("Join alerts", configurations.JoinAlertsEnabled, UIColors.GREEN, UIColors.GREEN_DIM, 4, AlertsGrid, "Notify when a non-whitelisted player joins or is already in this server.")
configurations.JoinLogButton = configurations.MakeActionRow("Join Log", 5, AlertsGrid, "Open the player join and leave log.")
configurations.CreditLogButton = configurations.MakeActionRow("Credit Log", 10, FarmPage, "Show players credited with hits on the current EXP target.")

-- Compact display controls used by the Performance page.
function configurations.MakeScaleControl(parent, title, getter, setter, minValue, maxValue, step, order)
	local card = Instance.new("Frame")
	card.Name = title:gsub("%s+", "")
	card.Size = UDim2.new(1, 0, 0, 48)
	card.LayoutOrder = order
	card.BackgroundColor3 = UIColors.CARD
	card.BorderSizePixel = 0
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
	local stroke = Instance.new("UIStroke", card)
	stroke.Color = UIColors.BORDER
	stroke.Transparency = 0.65
	stroke.Thickness = 1

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.new(1, -190, 1, 0)
	label.Position = UDim2.fromOffset(16, 0)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = UIColors.TEXT
	label.TextSize = 14
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = card

	local minus = Instance.new("TextButton")
	minus.Name = "Decrease"
	minus.Size = UDim2.fromOffset(30, 30)
	minus.Position = UDim2.new(1, -142, 0.5, -15)
	minus.BackgroundColor3 = UIColors.INPUT
	minus.BorderSizePixel = 0
	minus.Text = "−"
	minus.TextColor3 = UIColors.TEXT
	minus.TextSize = 16
	minus.Font = Enum.Font.GothamBold
	minus.Parent = card
	Instance.new("UICorner", minus).CornerRadius = UDim.new(0, 7)

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.Size = UDim2.fromOffset(74, 30)
	value.Position = UDim2.new(1, -108, 0.5, -15)
	value.BackgroundColor3 = UIColors.INPUT
	value.BorderSizePixel = 0
	value.TextColor3 = UIColors.ACCENT_SEL
	value.TextSize = 12
	value.Font = Enum.Font.GothamBold
	value.Parent = card
	Instance.new("UICorner", value).CornerRadius = UDim.new(0, 7)

	local plus = Instance.new("TextButton")
	plus.Name = "Increase"
	plus.Size = UDim2.fromOffset(30, 30)
	plus.Position = UDim2.new(1, -42, 0.5, -15)
	plus.BackgroundColor3 = UIColors.INPUT
	plus.BorderSizePixel = 0
	plus.Text = "+"
	plus.TextColor3 = UIColors.TEXT
	plus.TextSize = 16
	plus.Font = Enum.Font.GothamBold
	plus.Parent = card
	Instance.new("UICorner", plus).CornerRadius = UDim.new(0, 7)

	local function refresh()
		value.Text = string.format("%d%%", math.floor((getter() or 1) * 100 + 0.5))
	end

	local function change(delta)
		local current = getter() or 1
		local nextValue = math.clamp(current + delta, minValue, maxValue)
		nextValue = math.floor(nextValue / step + 0.5) * step
		nextValue = math.clamp(nextValue, minValue, maxValue)
		setter(nextValue, true)
		refresh()
	end

	minus.MouseButton1Click:Connect(function() change(-step) end)
	plus.MouseButton1Click:Connect(function() change(step) end)
	refresh()
	return card
end

local GuiScaleControl = configurations.MakeScaleControl(
	PerformanceGrid,
	"GUI size (all windows)",
	function() return configurations.GuiScale end,
	configurations.SetGuiScale,
	0.20, 2.50, 0.05, 2
)

local TextScaleControl = configurations.MakeScaleControl(
	PerformanceGrid,
	"Text size (all windows)",
	function() return configurations.TextScale end,
	configurations.SetTextScale,
	0.20, 2.50, 0.05, 3
)

local ESPToggleButton = configurations.MakeToggle("Player ESP", configurations.ESPEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 2, nil, "Show markers for other players.")
local ESPLineButton = configurations.MakeToggle("ESP lines", configurations.ESPLineEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 3, nil, "Draw lines to players.")
local ESPBoxButton = configurations.MakeToggle("ESP boxes", configurations.ESPBoxEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 4, nil, "Draw boxes around players.")
local FPSBoostButton = configurations.MakeToggle("Boost FPS", configurations.FPSBoostEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 1, PerformanceGrid, "Reduce visual effects while keeping scene lights and color correction.")
local AutoBlockButton = configurations.MakeToggle("Auto block", configurations.AutoBlockEnabled, UIColors.RED, UIColors.RED_DIM, 5, PlayersGrid, "Open Roblox's Block prompt for non-whitelisted players.")
local PlayerListButton = configurations.MakeActionRow("Player list", 1, PlayersGrid, "View players in this server.")
local WhitelistButton = configurations.MakeActionRow("Whitelist", 2, PlayersGrid, "Whitelisted players do not trigger alerts or auto-block.")
FollowSelectButton = configurations.MakeActionRow("Choose follow target", 3, PlayersGrid, "Select who to follow.")
FollowToggleButton = configurations.MakeToggle("Follow", configurations.FollowEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM, 4, PlayersGrid, "Follow the selected player; turn off to pause.")
configurations.FinishExpAfterBlockButton = configurations.MakeToggle(
	"Attack after block",
	configurations.FinishExpAfterBlockEnabled,
	UIColors.RED,
	UIColors.RED_DIM,
	6,
	PlayersGrid,
	"With Auto block on, confirm Block first, then finish the locked EXP mob before hopping."
)

function configurations.UpdateFollowButtons()
	local selectedId = configurations.SelectedFollowUserId
	local selectedPlayer = selectedId and Players:GetPlayerByUserId(tonumber(selectedId))
	local targetLabel = selectedPlayer and ("Target: @" .. selectedPlayer.Name)
		or (selectedId and "Target: offline" or "Choose follow target")
	configurations.SetActionVisual(FollowSelectButton, targetLabel, selectedId ~= nil)
	configurations.SetToggleVisual(FollowToggleButton, "Follow", configurations.FollowEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
end

function configurations.RefreshPartyWaypointState()
	local leaderUserId = tonumber(configurations.PartyLeaderUserId)
	local leaderPresent = leaderUserId and Players:GetPlayerByUserId(leaderUserId) ~= nil
	local shouldSuspend = configurations.PartyFollowEnabled == true
		and leaderUserId ~= nil and not leaderPresent or false
	if configurations.PartyWaypointSuspended == shouldSuspend then return end
	configurations.PartyWaypointSuspended = shouldSuspend
	UpdateWaypointInfo()
end

function configurations.SetFollowEnabled(enabled)
	configurations.FollowEnabled = enabled == true and configurations.SelectedFollowUserId ~= nil
	if not configurations.FollowEnabled then
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root then
			configurations.FollowSystem.Reset(humanoid, root)
		end
	end
	configurations.UpdateFollowButtons()
	configurations.SaveConfig()
	return configurations.FollowEnabled
end
configurations.UpdateFollowButtons()


AlertToggleButton.MouseButton1Click:Connect(function()
	configurations.AlertsEnabled = not configurations.AlertsEnabled
	configurations.SetToggleVisual(AlertToggleButton, "Player alert", configurations.AlertsEnabled, UIColors.GREEN, UIColors.GREEN_DIM)
	configurations.SaveConfig()
	if not configurations.AlertsEnabled then
		AlarmOverlay.Visible = false
	end
end)

AlertFlashButton.MouseButton1Click:Connect(function()
	configurations.AlertFlashEnabled = not configurations.AlertFlashEnabled
	configurations.SetToggleVisual(AlertFlashButton, "Screen flash", configurations.AlertFlashEnabled, UIColors.RED, UIColors.RED_DIM)
	if not configurations.AlertFlashEnabled then AlarmOverlay.Visible = false end
	configurations.SaveConfig()
end)

AutoResumeButton.MouseButton1Click:Connect(function()
	configurations.AutoResumeAfterAlert = not configurations.AutoResumeAfterAlert
	configurations.SetToggleVisual(AutoResumeButton, "Auto resume", configurations.AutoResumeAfterAlert, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.SaveConfig()
end)

configurations.JoinAlertButton.MouseButton1Click:Connect(function()
	configurations.SetJoinAlertsEnabled(not configurations.JoinAlertsEnabled)
	configurations.SetToggleVisual(configurations.JoinAlertButton, "Join alerts", configurations.JoinAlertsEnabled, UIColors.GREEN, UIColors.GREEN_DIM)
end)

ESPToggleButton.MouseButton1Click:Connect(function()
	configurations.ESPEnabled = not configurations.ESPEnabled
	configurations.SetToggleVisual(ESPToggleButton, "Player ESP", configurations.ESPEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.SaveConfig()
end)

ESPLineButton.MouseButton1Click:Connect(function()
	configurations.ESPLineEnabled = not configurations.ESPLineEnabled
	configurations.SetToggleVisual(ESPLineButton, "ESP lines", configurations.ESPLineEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.SaveConfig()
end)

ESPBoxButton.MouseButton1Click:Connect(function()
	configurations.ESPBoxEnabled = not configurations.ESPBoxEnabled
	configurations.SetToggleVisual(ESPBoxButton, "ESP boxes", configurations.ESPBoxEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
	configurations.SaveConfig()
end)

FPSBoostButton.MouseButton1Click:Connect(function()
	configurations.SetFPSBoost(not configurations.FPSBoostEnabled)
	configurations.SetToggleVisual(FPSBoostButton, "Boost FPS", configurations.FPSBoostEnabled, UIColors.ACCENT, UIColors.ACCENT_DIM)
end)

AutoBlockButton.MouseButton1Click:Connect(function()
	configurations.AutoBlockEnabled = not configurations.AutoBlockEnabled
	configurations.SetToggleVisual(AutoBlockButton, "Auto block", configurations.AutoBlockEnabled, UIColors.RED, UIColors.RED_DIM)
	if not configurations.AutoBlockEnabled and not configurations.AlertCombatPending then
		configurations.AlertCombatBlockReady = false
		configurations.AlertBlockPromptShown = false
		configurations.AlertBlockTarget = nil
		configurations.AutoBlockPostTarget = nil
		configurations.AutoBlockPostUserId = nil
	end
	configurations.SaveConfig()
end)

configurations.FinishExpAfterBlockButton.MouseButton1Click:Connect(function()
	configurations.FinishExpAfterBlockEnabled = not configurations.FinishExpAfterBlockEnabled
	configurations.SetToggleVisual(
		configurations.FinishExpAfterBlockButton,
		"Attack after block",
		configurations.FinishExpAfterBlockEnabled,
		UIColors.RED,
		UIColors.RED_DIM
	)
	if not configurations.FinishExpAfterBlockEnabled then
		configurations.AutoBlockPostTarget = nil
		configurations.AutoBlockPostUserId = nil
	end
	configurations.SaveConfig()
end)

function configurations.UpdateEmergencyStopButton()
	EmergencyStopButton.Text = configurations.EmergencyStopActive and "Emergency stop: ON  •  click to resume" or "Emergency stop: OFF"
	EmergencyStopButton.TextColor3 = configurations.EmergencyStopActive and UIColors.RED or UIColors.MUTED
	EmergencyStopButton.BackgroundColor3 = configurations.EmergencyStopActive and UIColors.RED_DIM or UIColors.CARD
end

EmergencyStopButton.MouseButton1Click:Connect(function()
	configurations.EmergencyStopActive = not configurations.EmergencyStopActive
	if configurations.EmergencyStopActive then
		configurations.Farming = false
		configurations.ExpFinishTarget = nil
		if configurations.StopExpMovement then configurations.StopExpMovement() end
		configurations.PauseTimer()
		configurations.ExpMaxCombatTarget = nil
		configurations.ExpLastShotTarget = nil
		configurations.AlertCombatPending = false
		configurations.AlertCombatTarget = nil
		configurations.AlertCombatHold = false
		configurations.AlertCombatBlockReady = false
		configurations.AlertResumeRequired = false
		configurations.AlertWasFarming = false
		configurations.AlertBlockPromptShown = false
		configurations.AlertBlockTarget = nil
		configurations.LastAlertCombatUserId = nil
		configurations.ExpRetaliationTarget = nil
		configurations.PendingServerHop = false
		configurations.ServerHopKillTarget = nil
		StartBtn.Text = "Start"
		StartBtn.BackgroundColor3 = UIColors.ACCENT
		Status.Text = "OFF"
		Status.TextColor3 = UIColors.RED
		Status.BackgroundColor3 = UIColors.RED_DIM
		StateLabel.Text = "Emergency stop"
		MiniState.Text = "Emergency stop"
		local character = Player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid then humanoid:MoveTo(root.Position) end
		RestoreMovementBoost()
	else
		StateLabel.Text = configurations.Farming and "Searching..." or "Stopped"
		MiniState.Text = StateLabel.Text
	end
	configurations.UpdateEmergencyStopButton()
end)

Player.Idled:Connect(function()
	if not configurations.AntiAFKEnabled or configurations.EmergencyStopActive then return end
	task.spawn(function()
		pcall(function()
			local camera = workspace.CurrentCamera
			if not camera then return end
			local position = Vector2.new(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5)
			VirtualUser:CaptureController()
			VirtualUser:Button2Down(position, camera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(position, camera.CFrame)
		end)
	end)
end)

task.spawn(function()
	while task.wait(1) do
		if not configurations.MovementBoostEnabled or configurations.EmergencyStopActive then
			RestoreMovementBoost()
			continue
		end

		local playerGui = Player:FindFirstChildOfClass("PlayerGui")
		local gameGui = playerGui and playerGui:FindFirstChild("GameGui")
		local stamina = gameGui and gameGui:FindFirstChild("Stamina")
		local playerStats = Player:FindFirstChild("PlayerStats")
		local level = playerStats and playerStats:FindFirstChild("Level")
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if (MovementBoostSnapshot.Stamina and MovementBoostSnapshot.Stamina ~= stamina)
			or (MovementBoostSnapshot.Humanoid and MovementBoostSnapshot.Humanoid ~= humanoid) then
			RestoreMovementBoost()
		end
		if stamina and (stamina:IsA("NumberValue") or stamina:IsA("IntValue")) and not MovementBoostSnapshot.Stamina then
			MovementBoostSnapshot.Stamina = stamina
			MovementBoostSnapshot.StaminaValue = stamina.Value
		end
		if level and humanoid then
			if not MovementBoostSnapshot.Humanoid then
				MovementBoostSnapshot.Humanoid = humanoid
				MovementBoostSnapshot.WalkSpeed = humanoid.WalkSpeed
			end
		end
		if stamina and (stamina:IsA("NumberValue") or stamina:IsA("IntValue")) then
			local ok = pcall(function()
				stamina.Value = 1e18
			end)
			if not ok and stamina:IsA("IntValue") then
				pcall(function() stamina.Value = 2147483647 end)
			end
		end
		if level and humanoid then
			if level.Value >= 300 then
				humanoid.WalkSpeed = 38
			elseif humanoid.WalkSpeed < 28 then
				humanoid.WalkSpeed = 28
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(leavingPlayer)
	if configurations.SelectedFollowUserId == tostring(leavingPlayer.UserId) then
		configurations.SetFollowEnabled(false)
	end
end)

Players.PlayerAdded:Connect(function(joiningPlayer)
	if configurations.SelectedFollowUserId == tostring(joiningPlayer.UserId) then
		configurations.UpdateFollowButtons()
	end
end)

--==================================================
-- SETTINGS (compact 2x2)
--==================================================
SettingsCard = Instance.new("Frame")
SettingsCard.Size = UDim2.new(1, 0, 0, 142)
SettingsCard.LayoutOrder = 2
SettingsCard.BackgroundColor3 = UIColors.CARD
SettingsCard.BorderSizePixel = 0
SettingsCard.Parent = FarmPage
Instance.new("UICorner", SettingsCard).CornerRadius = UDim.new(0, 10)

local SettingsTitle = Instance.new("TextLabel")
SettingsTitle.Size = UDim2.new(1, -16, 0, 18)
SettingsTitle.Position = UDim2.fromOffset(8, 4)
SettingsTitle.BackgroundTransparency = 1
SettingsTitle.Text = "Farming settings"
SettingsTitle.TextColor3 = UIColors.TEXT
SettingsTitle.TextSize = 13
SettingsTitle.Font = Enum.Font.GothamBold
SettingsTitle.TextXAlignment = Enum.TextXAlignment.Left
SettingsTitle.Parent = SettingsCard

function configurations.MakeCompactSetting(parent, name, default, xScale, yOffset)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.5, -16, 0, 14)
	lbl.Position = UDim2.new(xScale, 8, 0, yOffset)
	lbl.BackgroundTransparency = 1
	lbl.Text = name
	lbl.TextColor3 = UIColors.MUTED
	lbl.TextSize = 11
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = parent

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.5, -16, 0, 24)
	box.Position = UDim2.new(xScale, 8, 0, yOffset + 14)
	box.BackgroundColor3 = UIColors.INPUT
	box.BorderSizePixel = 0
	box.Text = tostring(default)
	box.TextColor3 = UIColors.TEXT
	box.TextSize = 12
	box.Font = Enum.Font.GothamBold
	box.ClearTextOnFocus = false
	box.Parent = parent
	Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
	return box
end

local AmountBox = configurations.MakeCompactSetting(SettingsCard, "Amount / cycle", configurations.Amount, 0, 24)
local DistBox = configurations.MakeCompactSetting(SettingsCard, "EXP target search radius (studs)", configurations.MaxDistance, 0.5, 24)
local IntervalBox = configurations.MakeCompactSetting(SettingsCard, "Interval (s)", configurations.Interval, 0, 62)
local MaxBox = configurations.MakeCompactSetting(SettingsCard, "EXP Max", configurations.ExpGoal, 0.5, 62)
local ExpApproachBox = configurations.MakeCompactSetting(SettingsCard, "EXP firing range / standoff (studs)", configurations.ExpApproachDistance, 0, 100)

local ExpAutoApproachButton = configurations.MakeToggle(
	"Move to target",
	configurations.ExpAutoApproachEnabled,
	UIColors.ACCENT,
	UIColors.ACCENT_DIM,
	3,
	FarmPage,
	"When off, waits within the search radius. When on, approaches the target and jumps if stuck."
)
ExpAutoApproachButton.MouseButton1Click:Connect(function()
	configurations.ExpAutoApproachEnabled = not configurations.ExpAutoApproachEnabled
	configurations.SetToggleVisual(
		ExpAutoApproachButton,
		"Move to target",
		configurations.ExpAutoApproachEnabled,
		UIColors.ACCENT,
		UIColors.ACCENT_DIM
	)
	configurations.SaveConfig()
end)

local AutoExecuteButton = configurations.MakeToggle(
	"Auto Execute",
	configurations.AutoExecuteEnabled,
	UIColors.RED,
	UIColors.RED_DIM,
	4,
	FarmPage,
	"Finish the locked mob at EXP Max or stop. Off: skip capped mobs and keep farming eligible targets."
)
AutoExecuteButton.MouseButton1Click:Connect(function()
	configurations.AutoExecuteEnabled = not configurations.AutoExecuteEnabled
	configurations.SetToggleVisual(AutoExecuteButton, "Auto Execute", configurations.AutoExecuteEnabled, UIColors.RED, UIColors.RED_DIM)
	if not configurations.AutoExecuteEnabled then
		configurations.ExpFinishTarget = nil
		configurations.ExpMaxCombatTarget = nil
		configurations.ExpLastShotTarget = nil
		if configurations.AlertCombatPending then
			configurations.AlertCombatPending = false
			configurations.AlertCombatTarget = nil
			configurations.AlertCombatHold = true
			configurations.AlertCombatBlockReady = configurations.AutoBlockEnabled
			if not configurations.AutoBlockEnabled then configurations.AlertBlockTarget = nil end
		end
	end
	configurations.SaveConfig()
end)

local ExpTargetRetaliationButton = configurations.MakeToggle(
	"Avengers Assemble",
	configurations.ExpTargetRetaliationEnabled,
	UIColors.RED,
	UIColors.RED_DIM,
	5,
	FarmPage,
	"Attack the EXP target after its health reaches the configured threshold."
)
ExpTargetRetaliationButton.MouseButton1Click:Connect(function()
	configurations.ExpTargetRetaliationEnabled = not configurations.ExpTargetRetaliationEnabled
	configurations.SetToggleVisual(
		ExpTargetRetaliationButton,
		"Avengers Assemble",
		configurations.ExpTargetRetaliationEnabled,
		UIColors.RED,
		UIColors.RED_DIM
	)
	if not configurations.ExpTargetRetaliationEnabled then
		configurations.ExpRetaliationTarget = nil
	else
		configurations.CheckExpRetaliationHealth(configurations.CurrentTarget)
	end
	configurations.SaveConfig()
end)

configurations.ExpRetaliationHealthCard, configurations.ExpRetaliationHealthInput = configurations.MakeNumberCard(
	FarmPage,
	"Avengers HP trigger (%)",
	function() return configurations.ExpRetaliationHealthPercent end,
	6,
	1,
	100,
	function(value)
		configurations.ExpRetaliationHealthPercent = value
		if configurations.ExpTargetRetaliationEnabled then
			configurations.CheckExpRetaliationHealth(configurations.CurrentTarget)
		end
	end
)

configurations.SafeBoosterResetButton = configurations.MakeToggle(
	"Safe booster reset",
	configurations.SafeBoosterResetEnabled,
	UIColors.RED,
	UIColors.RED_DIM,
	7,
	FarmPage,
	"Reset on positive EXP Boost updates unless the mob-damage tag is present."
)
configurations.SafeBoosterResetButton.MouseButton1Click:Connect(function()
	configurations.SafeBoosterResetEnabled = configurations.SafeBoosterResetSystem.SetEnabled(
		not configurations.SafeBoosterResetEnabled
	)
	configurations.SetToggleVisual(
		configurations.SafeBoosterResetButton,
		"Safe booster reset",
		configurations.SafeBoosterResetEnabled,
		UIColors.RED,
		UIColors.RED_DIM
	)
	configurations.SaveConfig()
end)

configurations.ExpHitFeedbackButton = configurations.MakeToggle(
	"EXP hit alert",
	configurations.ExpHitFeedbackEnabled,
	UIColors.ACCENT,
	UIColors.ACCENT_DIM,
	8,
	FarmPage,
	"Keep the hit confirmation visible until that EXP mob dies."
)
configurations.ExpHitFeedbackButton.MouseButton1Click:Connect(function()
	configurations.ExpHitFeedbackEnabled = not configurations.ExpHitFeedbackEnabled
	configurations.SetToggleVisual(
		configurations.ExpHitFeedbackButton,
		"EXP hit alert",
		configurations.ExpHitFeedbackEnabled,
		UIColors.ACCENT,
		UIColors.ACCENT_DIM
	)
	if not configurations.ExpHitFeedbackEnabled then
		configurations.ExpHitFeedbackTarget = nil
	end
	configurations.UpdateExpHitFeedback()
	configurations.SaveConfig()
end)

configurations.ResetStatsButton = configurations.MakeActionRow(
	"Reset stats",
	9,
	FarmPage,
	"Use the AIC reset for stats below 500 points."
)
configurations.ResetStatsButton.MouseButton1Click:Connect(function()
	if configurations.ResetStatsInProgress then return end
	configurations.ResetStatsInProgress = true
	task.spawn(function()
		local playerStats = Player:WaitForChild("PlayerStats", 5)
		local statsEvent = ReplicatedStorage:FindFirstChild("StatsEvent", true)
		if not playerStats then
			configurations.NotifyUser("Reset stats", "PlayerStats is unavailable.", 5)
			configurations.ResetStatsInProgress = false
			return
		end
		if not statsEvent or not statsEvent:IsA("RemoteEvent") then
			configurations.NotifyUser("Reset stats", "StatsEvent is unavailable.", 5)
			configurations.ResetStatsInProgress = false
			return
		end

		local statNames = { "Vitality", "Agility", "Luck", "Strength", "Defense" }
		local skippedStats = {}
		for _, statName in ipairs(statNames) do
			local statValue = playerStats:FindFirstChild(statName)
			if statValue and (statValue:IsA("IntValue") or statValue:IsA("NumberValue")) then
				if statValue.Value < 500 then
					local ok, err = pcall(function()
						statsEvent:FireServer(statName, 0)
					end)
					if not ok then
						configurations.NotifyUser("Reset stats", "Failed to reset " .. statName .. ": " .. tostring(err), 6)
					end
				else
					table.insert(skippedStats, statName)
				end
			end
		end
		if #skippedStats > 0 then
			configurations.NotifyUser("Reset stats", "Skipped (500+): " .. table.concat(skippedStats, ", "), 6)
		end
		configurations.ResetStatsInProgress = false
	end)
end)

AmountBox.FocusLost:Connect(function()
	local v = tonumber(AmountBox.Text)
	if v and v > 0 then
		configurations.Amount = math.floor(v)
	end
	AmountBox.Text = tostring(configurations.Amount)
	configurations.SaveConfig()
end)
DistBox.FocusLost:Connect(function()
	local v = tonumber(DistBox.Text)
	if v and v > 0 then
		configurations.MaxDistance = math.clamp(v, 5, 100000)
	end
	DistBox.Text = tostring(configurations.MaxDistance)
	configurations.SaveConfig()
end)
ExpApproachBox.FocusLost:Connect(function()
	local v = tonumber(ExpApproachBox.Text)
	if v and v > 0 then
		configurations.ExpApproachDistance = math.clamp(v, 5, 100)
	end
	ExpApproachBox.Text = tostring(configurations.ExpApproachDistance)
	configurations.SaveConfig()
end)
IntervalBox.FocusLost:Connect(function()
	local v = tonumber(IntervalBox.Text)
	if v and v >= 0 then configurations.Interval = v end
	IntervalBox.Text = tostring(configurations.Interval)
	configurations.SaveConfig()
end)
MaxBox.FocusLost:Connect(function()
	local v = tonumber((MaxBox.Text:gsub(",", "")))
	if v and v > 0 then
		configurations.ExpGoal = v
		MaxLabel.Text = "/ " .. configurations.FormatNumber(configurations.ExpGoal)
	end
	MaxBox.Text = tostring(configurations.ExpGoal)
	configurations.SaveConfig()
end)

--==================================================
-- PLAYER / WHITELIST PANELS (unchanged structure)
--==================================================
local PlayerPanel = Instance.new("Frame")
PlayerPanel.Name = "PlayerListPanel"
PlayerPanel.Size = UDim2.fromOffset(configurations.PlayerPanelWidthPx or 340, configurations.PlayerPanelHeightPx or 420)
PlayerPanel.Position = UDim2.fromOffset(80, 80)
PlayerPanel.ZIndex = 90
PlayerPanel.BackgroundColor3 = UIColors.BG
PlayerPanel.BorderSizePixel = 0
PlayerPanel.Visible = false
PlayerPanel.Parent = ScreenGui
Instance.new("UICorner", PlayerPanel).CornerRadius = UDim.new(0, 12)
configurations.RegisterScaledRoot(PlayerPanel)
local PlayerPanelStroke = Instance.new("UIStroke", PlayerPanel)
PlayerPanelStroke.Color = UIColors.BORDER
PlayerPanelStroke.Thickness = 1
PlayerPanelStroke.Transparency = 0.35

-- Header bar matching main UI
local PlayerPanelHeader = Instance.new("Frame")
PlayerPanelHeader.Name = "Header"
PlayerPanelHeader.Size = UDim2.new(1, 0, 0, 44)
PlayerPanelHeader.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
PlayerPanelHeader.BorderSizePixel = 0
PlayerPanelHeader.ZIndex = 91
PlayerPanelHeader.Parent = PlayerPanel
Instance.new("UICorner", PlayerPanelHeader).CornerRadius = UDim.new(0, 12)

local PlayerPanelHeaderFix = Instance.new("Frame")
PlayerPanelHeaderFix.Size = UDim2.new(1, 0, 0, 16)
PlayerPanelHeaderFix.Position = UDim2.new(0, 0, 1, -16)
PlayerPanelHeaderFix.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
PlayerPanelHeaderFix.BorderSizePixel = 0
PlayerPanelHeaderFix.ZIndex = 91
PlayerPanelHeaderFix.Parent = PlayerPanelHeader

local PlayerPanelHeaderRule = Instance.new("Frame")
PlayerPanelHeaderRule.Size = UDim2.new(1, -20, 0, 1)
PlayerPanelHeaderRule.Position = UDim2.new(0, 10, 1, -1)
PlayerPanelHeaderRule.BackgroundColor3 = UIColors.BORDER
PlayerPanelHeaderRule.BackgroundTransparency = 0.4
PlayerPanelHeaderRule.BorderSizePixel = 0
PlayerPanelHeaderRule.ZIndex = 92
PlayerPanelHeaderRule.Parent = PlayerPanelHeader

local PlayerPanelTitle = Instance.new("TextLabel")
PlayerPanelTitle.Size = UDim2.new(1, -56, 0, 22)
PlayerPanelTitle.Position = UDim2.fromOffset(14, 11)
PlayerPanelTitle.ZIndex = 92
PlayerPanelTitle.Active = true
PlayerPanelTitle.BackgroundTransparency = 1
PlayerPanelTitle.Text = "Players in server"
PlayerPanelTitle.TextColor3 = UIColors.TEXT
PlayerPanelTitle.TextSize = 16
PlayerPanelTitle.Font = Enum.Font.GothamBold
PlayerPanelTitle.TextXAlignment = Enum.TextXAlignment.Left
PlayerPanelTitle.Parent = PlayerPanelHeader

local PlayerPanelClose = Instance.new("TextButton")
PlayerPanelClose.Size = UDim2.fromOffset(32, 32)
PlayerPanelClose.Position = UDim2.new(1, -40, 0, 6)
PlayerPanelClose.ZIndex = 92
PlayerPanelClose.BackgroundColor3 = UIColors.INPUT
PlayerPanelClose.BorderSizePixel = 0
PlayerPanelClose.Text = "×"
PlayerPanelClose.TextColor3 = UIColors.TEXT
PlayerPanelClose.TextSize = 19
PlayerPanelClose.Font = Enum.Font.GothamBold
PlayerPanelClose.Parent = PlayerPanelHeader
Instance.new("UICorner", PlayerPanelClose).CornerRadius = UDim.new(0, 6)

local PlayerScroll = Instance.new("ScrollingFrame")
PlayerScroll.Size = UDim2.new(1, -20, 1, -56)
PlayerScroll.Position = UDim2.fromOffset(10, 50)
PlayerScroll.ZIndex = 91
PlayerScroll.BackgroundTransparency = 1
PlayerScroll.BorderSizePixel = 0
PlayerScroll.ScrollBarThickness = 3
PlayerScroll.ScrollBarImageColor3 = UIColors.MUTED
PlayerScroll.CanvasSize = UDim2.new()
PlayerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
PlayerScroll.ScrollingDirection = Enum.ScrollingDirection.Y
PlayerScroll.Parent = PlayerPanel

local PlayerScrollPad = Instance.new("UIPadding")
PlayerScrollPad.PaddingTop = UDim.new(0, 4)
PlayerScrollPad.PaddingBottom = UDim.new(0, 8)
PlayerScrollPad.PaddingLeft = UDim.new(0, 2)
PlayerScrollPad.PaddingRight = UDim.new(0, 2)
PlayerScrollPad.Parent = PlayerScroll

local PlayerScrollLayout = Instance.new("UIListLayout", PlayerScroll)
PlayerScrollLayout.Padding = UDim.new(0, 10)
PlayerScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
PlayerScrollLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

function configurations.SetPlayerPanelCardLayout(enabled)
	local resizeHandle = PlayerPanel:FindFirstChild("PlayerPanelResizeHandle")
	if enabled then
		if not configurations.PlayerPanelCardMode then
			configurations.PlayerPanelSavedSize = PlayerPanel.Size
			configurations.PlayerPanelSavedPosition = PlayerPanel.Position
			configurations.PlayerPanelSavedAnchorPoint = PlayerPanel.AnchorPoint
		end
		configurations.PlayerPanelCardMode = true
		PlayerPanel.AnchorPoint = Vector2.new(0.5, 0)
		PlayerPanel.Size = UDim2.fromOffset(configurations.PlayerPanelWidthPx or 340, 244)
		PlayerPanel.Position = UDim2.new(0.5, 0, 0.03, 0)
		if resizeHandle then resizeHandle.Visible = false end
		return
	end

	if not configurations.PlayerPanelCardMode then return end
	PlayerPanel.Size = configurations.PlayerPanelSavedSize or UDim2.fromOffset(configurations.PlayerPanelWidthPx or 340, configurations.PlayerPanelHeightPx or 420)
	PlayerPanel.Position = configurations.PlayerPanelSavedPosition or UDim2.fromScale(0.52, 0.19)
	PlayerPanel.AnchorPoint = configurations.PlayerPanelSavedAnchorPoint or Vector2.new(0, 0)
	configurations.PlayerPanelCardMode = false
	configurations.PlayerPanelSavedSize = nil
	configurations.PlayerPanelSavedPosition = nil
	configurations.PlayerPanelSavedAnchorPoint = nil
	if resizeHandle then resizeHandle.Visible = true end
end

PlayerListButton.MouseButton1Click:Connect(function()
	local wasShowingCard = configurations.PlayerPanelMode == "card"
	if wasShowingCard then configurations.SetPlayerPanelCardLayout(false) end
	configurations.PlayerPanelMode = "server"
	configurations.PlayerPanelTargetUserId = nil
	PlayerPanelTitle.Text = "Players in server"
	PlayerPanel.Visible = wasShowingCard or not PlayerPanel.Visible
	configurations.SetActionVisual(PlayerListButton, PlayerPanel.Visible and "Close list" or "Player list", PlayerPanel.Visible)
	if PlayerPanel.Visible then configurations.ApplyTextScale(PlayerPanel) end
end)
PlayerPanelClose.MouseButton1Click:Connect(function()
	PlayerPanel.Visible = false
	configurations.SetPlayerPanelCardLayout(false)
	configurations.PlayerPanelMode = "server"
	configurations.PlayerPanelTargetUserId = nil
	PlayerPanelTitle.Text = "Players in server"
	configurations.SetActionVisual(PlayerListButton, "Player list", false)
end)

function configurations.OpenPlayerCardByUserId(userId)
	local target = Players:GetPlayerByUserId(tonumber(userId) or 0)
	if not target then return false end
	configurations.SetPlayerPanelCardLayout(true)
	configurations.PlayerPanelMode = "card"
	configurations.PlayerPanelTargetUserId = tostring(target.UserId)
	PlayerPanelTitle.Text = "Player card · @" .. target.Name
	PlayerPanel.Visible = true
	configurations.SetActionVisual(PlayerListButton, "Player list", false)
	return true
end

function configurations.FilterPlayerPanelListing(panelPlayers)
	if configurations.PlayerPanelMode == "card" then
		table.clear(panelPlayers)
		local target = Players:GetPlayerByUserId(tonumber(configurations.PlayerPanelTargetUserId) or 0)
		if target then table.insert(panelPlayers, target) end
	end
	return panelPlayers
end

FollowSelectButton.MouseButton1Click:Connect(function()
	configurations.SetPlayerPanelCardLayout(false)
	configurations.PlayerPanelMode = "follow"
	configurations.PlayerPanelTargetUserId = nil
	PlayerPanelTitle.Text = "Choose player to follow"
	PlayerPanel.Visible = true
	configurations.SetActionVisual(PlayerListButton, "Player list", false)
end)

FollowToggleButton.MouseButton1Click:Connect(function()
	if not configurations.SelectedFollowUserId then
		configurations.SetPlayerPanelCardLayout(false)
		configurations.PlayerPanelMode = "follow"
		configurations.PlayerPanelTargetUserId = nil
		PlayerPanelTitle.Text = "Choose player to follow"
		PlayerPanel.Visible = true
		return
	end
	configurations.SetFollowEnabled(not configurations.FollowEnabled)
end)

configurations.WhitelistPanel = Instance.new("Frame")
configurations.WhitelistPanel.Name = "WhitelistPanel"
configurations.WhitelistPanel.Size = UDim2.fromOffset(configurations.WhitelistPanelWidthPx or 300, configurations.WhitelistPanelHeightPx or 360)
configurations.WhitelistPanel.Position = UDim2.fromOffset(40, 80)
configurations.WhitelistPanel.ZIndex = 90
configurations.WhitelistPanel.BackgroundColor3 = UIColors.BG
configurations.WhitelistPanel.BorderSizePixel = 0
configurations.WhitelistPanel.Visible = false
configurations.WhitelistPanel.Parent = ScreenGui
Instance.new("UICorner", configurations.WhitelistPanel).CornerRadius = UDim.new(0, 12)
configurations.RegisterScaledRoot(configurations.WhitelistPanel)
configurations.WhitelistPanelStroke = Instance.new("UIStroke", configurations.WhitelistPanel)
configurations.WhitelistPanelStroke.Color = UIColors.BORDER
configurations.WhitelistPanelStroke.Thickness = 1
configurations.WhitelistPanelStroke.Transparency = 0.35

configurations.WhitelistHeader = Instance.new("Frame")
configurations.WhitelistHeader.Name = "Header"
configurations.WhitelistHeader.Size = UDim2.new(1, 0, 0, 44)
configurations.WhitelistHeader.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
configurations.WhitelistHeader.BorderSizePixel = 0
configurations.WhitelistHeader.ZIndex = 91
configurations.WhitelistHeader.Parent = configurations.WhitelistPanel
Instance.new("UICorner", configurations.WhitelistHeader).CornerRadius = UDim.new(0, 12)

configurations.WhitelistHeaderFix = Instance.new("Frame")
configurations.WhitelistHeaderFix.Size = UDim2.new(1, 0, 0, 16)
configurations.WhitelistHeaderFix.Position = UDim2.new(0, 0, 1, -16)
configurations.WhitelistHeaderFix.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
configurations.WhitelistHeaderFix.BorderSizePixel = 0
configurations.WhitelistHeaderFix.ZIndex = 91
configurations.WhitelistHeaderFix.Parent = configurations.WhitelistHeader

configurations.WhitelistHeaderRule = Instance.new("Frame")
configurations.WhitelistHeaderRule.Size = UDim2.new(1, -20, 0, 1)
configurations.WhitelistHeaderRule.Position = UDim2.new(0, 10, 1, -1)
configurations.WhitelistHeaderRule.BackgroundColor3 = UIColors.BORDER
configurations.WhitelistHeaderRule.BackgroundTransparency = 0.4
configurations.WhitelistHeaderRule.BorderSizePixel = 0
configurations.WhitelistHeaderRule.ZIndex = 92
configurations.WhitelistHeaderRule.Parent = configurations.WhitelistHeader

configurations.WhitelistTitle = Instance.new("TextLabel")
configurations.WhitelistTitle.Size = UDim2.new(1, -164, 0, 24)
configurations.WhitelistTitle.Position = UDim2.fromOffset(14, 11)
configurations.WhitelistTitle.ZIndex = 92
configurations.WhitelistTitle.Active = true
configurations.WhitelistTitle.BackgroundTransparency = 1
configurations.WhitelistTitle.Text = "Whitelist"
configurations.WhitelistTitle.TextColor3 = UIColors.TEXT
configurations.WhitelistTitle.TextSize = 16
configurations.WhitelistTitle.Font = Enum.Font.GothamBold
configurations.WhitelistTitle.TextXAlignment = Enum.TextXAlignment.Left
configurations.WhitelistTitle.Parent = configurations.WhitelistHeader

configurations.AddAllWhitelistButton = Instance.new("TextButton")
configurations.AddAllWhitelistButton.Size = UDim2.fromOffset(72, 28)
configurations.AddAllWhitelistButton.Position = UDim2.new(1, -118, 0, 8)
configurations.AddAllWhitelistButton.ZIndex = 92
configurations.AddAllWhitelistButton.BackgroundColor3 = UIColors.ACCENT_DIM
configurations.AddAllWhitelistButton.BorderSizePixel = 0
configurations.AddAllWhitelistButton.Text = "Add all"
configurations.AddAllWhitelistButton.TextColor3 = UIColors.ACCENT
configurations.AddAllWhitelistButton.TextSize = 12
configurations.AddAllWhitelistButton.Font = Enum.Font.GothamBold
configurations.AddAllWhitelistButton.Parent = configurations.WhitelistHeader
Instance.new("UICorner", configurations.AddAllWhitelistButton).CornerRadius = UDim.new(0, 6)

configurations.WhitelistCloseButton = Instance.new("TextButton")
configurations.WhitelistCloseButton.Name = "CloseButton"
configurations.WhitelistCloseButton.Size = UDim2.fromOffset(32, 32)
configurations.WhitelistCloseButton.Position = UDim2.new(1, -40, 0, 6)
configurations.WhitelistCloseButton.ZIndex = 92
configurations.WhitelistCloseButton.BackgroundColor3 = UIColors.INPUT
configurations.WhitelistCloseButton.BorderSizePixel = 0
configurations.WhitelistCloseButton.Text = "×"
configurations.WhitelistCloseButton.TextColor3 = UIColors.TEXT
configurations.WhitelistCloseButton.TextSize = 19
configurations.WhitelistCloseButton.Font = Enum.Font.GothamBold
configurations.WhitelistCloseButton.Parent = configurations.WhitelistHeader
Instance.new("UICorner", configurations.WhitelistCloseButton).CornerRadius = UDim.new(0, 6)

configurations.WhitelistInput = Instance.new("TextBox")
configurations.WhitelistInput.Size = UDim2.new(1, -112, 0, 34)
configurations.WhitelistInput.Position = UDim2.fromOffset(12, 54)
configurations.WhitelistInput.ZIndex = 91
configurations.WhitelistInput.BackgroundColor3 = UIColors.INPUT
configurations.WhitelistInput.BorderSizePixel = 0
configurations.WhitelistInput.PlaceholderText = "Enter Player UserId"
configurations.WhitelistInput.Text = ""
configurations.WhitelistInput.TextColor3 = UIColors.TEXT
configurations.WhitelistInput.PlaceholderColor3 = UIColors.MUTED
configurations.WhitelistInput.TextSize = 14
configurations.WhitelistInput.Font = Enum.Font.Gotham
configurations.WhitelistInput.ClearTextOnFocus = false
configurations.WhitelistInput.Parent = configurations.WhitelistPanel
Instance.new("UICorner", configurations.WhitelistInput).CornerRadius = UDim.new(0, 8)

configurations.AddWhitelistButton = Instance.new("TextButton")
configurations.AddWhitelistButton.Size = UDim2.fromOffset(88, 34)
configurations.AddWhitelistButton.Position = UDim2.new(1, -100, 0, 54)
configurations.AddWhitelistButton.ZIndex = 91
configurations.AddWhitelistButton.BackgroundColor3 = UIColors.ACCENT_DIM
configurations.AddWhitelistButton.BorderSizePixel = 0
configurations.AddWhitelistButton.Text = "Add ID"
configurations.AddWhitelistButton.TextColor3 = UIColors.ACCENT
configurations.AddWhitelistButton.TextSize = 14
configurations.AddWhitelistButton.Font = Enum.Font.GothamBold
configurations.AddWhitelistButton.Parent = configurations.WhitelistPanel
Instance.new("UICorner", configurations.AddWhitelistButton).CornerRadius = UDim.new(0, 8)

configurations.WhitelistScroll = Instance.new("ScrollingFrame")
configurations.WhitelistScroll.Size = UDim2.new(1, -20, 1, -102)
configurations.WhitelistScroll.Position = UDim2.fromOffset(10, 96)
configurations.WhitelistScroll.ZIndex = 91
configurations.WhitelistScroll.BackgroundTransparency = 1
configurations.WhitelistScroll.BorderSizePixel = 0
configurations.WhitelistScroll.ScrollBarThickness = 3
configurations.WhitelistScroll.ScrollBarImageColor3 = UIColors.MUTED
configurations.WhitelistScroll.CanvasSize = UDim2.new()
configurations.WhitelistScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
configurations.WhitelistScroll.ScrollingDirection = Enum.ScrollingDirection.Y
configurations.WhitelistScroll.Parent = configurations.WhitelistPanel

configurations.WhitelistLayout = Instance.new("UIListLayout", configurations.WhitelistScroll)
configurations.WhitelistLayout.Padding = UDim.new(0, 6)
configurations.WhitelistLayout.SortOrder = Enum.SortOrder.LayoutOrder
configurations.WhitelistLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

configurations.JoinLogPanel = Instance.new("Frame")
configurations.JoinLogPanel.Name = "PlayerJoinLogPanel"
configurations.JoinLogPanel.Size = UDim2.fromOffset(configurations.JoinLogWidthPx or 320, configurations.JoinLogHeightPx or 360)
configurations.JoinLogPanel.Position = UDim2.fromOffset(40, 100)
configurations.JoinLogPanel.ZIndex = 90
configurations.JoinLogPanel.BackgroundColor3 = UIColors.BG
configurations.JoinLogPanel.BorderSizePixel = 0
configurations.JoinLogPanel.Visible = false
configurations.JoinLogPanel.Parent = ScreenGui
Instance.new("UICorner", configurations.JoinLogPanel).CornerRadius = UDim.new(0, 12)
configurations.RegisterScaledRoot(configurations.JoinLogPanel)
configurations.JoinLogPanelStroke = Instance.new("UIStroke", configurations.JoinLogPanel)
configurations.JoinLogPanelStroke.Color = UIColors.BORDER
configurations.JoinLogPanelStroke.Thickness = 1
configurations.JoinLogPanelStroke.Transparency = 0.35

configurations.JoinLogHeader = Instance.new("Frame")
configurations.JoinLogHeader.Name = "Header"
configurations.JoinLogHeader.Size = UDim2.new(1, 0, 0, 44)
configurations.JoinLogHeader.ZIndex = 91
configurations.JoinLogHeader.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
configurations.JoinLogHeader.BorderSizePixel = 0
configurations.JoinLogHeader.Parent = configurations.JoinLogPanel
Instance.new("UICorner", configurations.JoinLogHeader).CornerRadius = UDim.new(0, 12)

configurations.JoinLogHeaderFix = Instance.new("Frame")
configurations.JoinLogHeaderFix.Size = UDim2.new(1, 0, 0, 16)
configurations.JoinLogHeaderFix.Position = UDim2.new(0, 0, 1, -16)
configurations.JoinLogHeaderFix.ZIndex = 91
configurations.JoinLogHeaderFix.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
configurations.JoinLogHeaderFix.BorderSizePixel = 0
configurations.JoinLogHeaderFix.Parent = configurations.JoinLogHeader

configurations.JoinLogTitle = Instance.new("TextLabel")
configurations.JoinLogTitle.Size = UDim2.new(1, -56, 0, 22)
configurations.JoinLogTitle.Position = UDim2.fromOffset(14, 11)
configurations.JoinLogTitle.ZIndex = 92
configurations.JoinLogTitle.BackgroundTransparency = 1
configurations.JoinLogTitle.Text = "Join Log"
configurations.JoinLogTitle.TextColor3 = UIColors.TEXT
configurations.JoinLogTitle.TextSize = 16
configurations.JoinLogTitle.Font = Enum.Font.GothamBold
configurations.JoinLogTitle.TextXAlignment = Enum.TextXAlignment.Left
configurations.JoinLogTitle.Parent = configurations.JoinLogHeader

configurations.JoinLogCloseButton = Instance.new("TextButton")
configurations.JoinLogCloseButton.Size = UDim2.fromOffset(32, 32)
configurations.JoinLogCloseButton.Position = UDim2.new(1, -40, 0, 6)
configurations.JoinLogCloseButton.ZIndex = 92
configurations.JoinLogCloseButton.BackgroundColor3 = UIColors.INPUT
configurations.JoinLogCloseButton.BorderSizePixel = 0
configurations.JoinLogCloseButton.Text = "×"
configurations.JoinLogCloseButton.TextColor3 = UIColors.TEXT
configurations.JoinLogCloseButton.TextSize = 19
configurations.JoinLogCloseButton.Font = Enum.Font.GothamBold
configurations.JoinLogCloseButton.Parent = configurations.JoinLogHeader
Instance.new("UICorner", configurations.JoinLogCloseButton).CornerRadius = UDim.new(0, 6)

configurations.JoinLogScroll = Instance.new("ScrollingFrame")
configurations.JoinLogScroll.Size = UDim2.new(1, -20, 1, -58)
configurations.JoinLogScroll.Position = UDim2.fromOffset(10, 50)
configurations.JoinLogScroll.ZIndex = 91
configurations.JoinLogScroll.BackgroundTransparency = 1
configurations.JoinLogScroll.BorderSizePixel = 0
configurations.JoinLogScroll.ScrollBarThickness = 3
configurations.JoinLogScroll.ScrollBarImageColor3 = UIColors.MUTED
configurations.JoinLogScroll.CanvasSize = UDim2.new()
configurations.JoinLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
configurations.JoinLogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
configurations.JoinLogScroll.Parent = configurations.JoinLogPanel
configurations.JoinLogLayout = Instance.new("UIListLayout", configurations.JoinLogScroll)
configurations.JoinLogLayout.Padding = UDim.new(0, 6)
configurations.JoinLogLayout.SortOrder = Enum.SortOrder.LayoutOrder
configurations.JoinLogLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

function configurations.RefreshJoinLog()
	for _, child in ipairs(configurations.JoinLogScroll:GetChildren()) do
		if child.Name:match("^JoinLogRow_") then child:Destroy() end
	end
	for order = #configurations.PlayerJoinLog, 1, -1 do
		local entry = configurations.PlayerJoinLog[order]
		local selectedEntry = entry
		local row = Instance.new("Frame")
		row.Name = "JoinLogRow_" .. tostring(order)
		row.Size = UDim2.new(1, -6, 0, 34)
		row.LayoutOrder = #configurations.PlayerJoinLog - order + 1
		row.ZIndex = 92
		row.BackgroundColor3 = UIColors.CARD
		row.BorderSizePixel = 0
		row.Parent = configurations.JoinLogScroll
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
		local stroke = Instance.new("UIStroke", row)
		stroke.Color = UIColors.BORDER
		stroke.Transparency = 0.55
		stroke.Thickness = 1

		local eventName = entry.Event == "joined" and "JOINED"
			or (entry.Event == "left" and "LEFT" or "HERE")
		local currentlyWhitelisted = configurations.WhitelistIds[entry.UserId] == true
		local isDanger = entry.SpecialThreat and not currentlyWhitelisted
		local eventColor = isDanger and UIColors.RED
			or (entry.Event == "left" and UIColors.RED
			or (entry.Event == "present" and UIColors.MUTED or UIColors.GREEN))

		local timeBadge = Instance.new("TextLabel")
		timeBadge.Size = UDim2.fromOffset(58, 20)
		timeBadge.Position = UDim2.fromOffset(8, 7)
		timeBadge.ZIndex = 93
		timeBadge.BackgroundColor3 = UIColors.INPUT
		timeBadge.BorderSizePixel = 0
		timeBadge.Text = entry.Time
		timeBadge.TextColor3 = UIColors.MUTED
		timeBadge.TextSize = 11
		timeBadge.Font = Enum.Font.GothamBold
		timeBadge.Parent = row
		Instance.new("UICorner", timeBadge).CornerRadius = UDim.new(0, 6)

		local eventBadge = Instance.new("TextLabel")
		local eventBadgeWidth = isDanger and 88 or 62
		eventBadge.Size = UDim2.fromOffset(eventBadgeWidth, 20)
		eventBadge.Position = UDim2.fromOffset(72, 7)
		eventBadge.ZIndex = 93
		eventBadge.BackgroundColor3 = isDanger and UIColors.RED_DIM
			or (entry.Event == "left" and UIColors.RED_DIM
			or (entry.Event == "joined" and UIColors.GREEN_DIM or UIColors.INPUT))
		eventBadge.BorderSizePixel = 0
		eventBadge.Text = isDanger and "DANGER" or eventName
		eventBadge.TextColor3 = eventColor
		eventBadge.TextSize = 11
		eventBadge.Font = Enum.Font.GothamBold
		eventBadge.Parent = row
		Instance.new("UICorner", eventBadge).CornerRadius = UDim.new(0, 6)

		local nameLabel = Instance.new("TextButton")
		local nameStart = 72 + eventBadgeWidth + 8
		nameLabel.Size = UDim2.new(1, -(nameStart + 8), 0, 18)
		nameLabel.Position = UDim2.fromOffset(nameStart, 8)
		nameLabel.ZIndex = 93
		nameLabel.BackgroundTransparency = 1
		nameLabel.AutoButtonColor = false
		local whitelistTag = (entry.Whitelisted or currentlyWhitelisted) and "  ·  WL" or ""
		nameLabel.Text = "@" .. entry.Username .. whitelistTag
		nameLabel.TextColor3 = isDanger and UIColors.RED or UIColors.TEXT
		nameLabel.TextSize = 13
		nameLabel.Font = Enum.Font.GothamMedium
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Parent = row
		nameLabel.MouseButton1Click:Connect(function()
			configurations.OpenPlayerCardByUserId(selectedEntry.UserId)
		end)
	end
	configurations.ApplyTextScale(configurations.JoinLogPanel)
end

configurations.JoinLogButton.MouseButton1Click:Connect(function()
	local isOpen = not configurations.JoinLogPanel.Visible
	configurations.JoinLogPanel.Visible = isOpen
	configurations.SetActionVisual(configurations.JoinLogButton, isOpen and "Close log" or "Join Log", isOpen)
	if isOpen then configurations.RefreshJoinLog() end
end)
configurations.JoinLogCloseButton.MouseButton1Click:Connect(function()
	configurations.JoinLogPanel.Visible = false
	configurations.SetActionVisual(configurations.JoinLogButton, "Join Log", false)
end)

configurations.CreditLogPanel = Instance.new("Frame")
configurations.CreditLogPanel.Name = "CreditLogPanel"
configurations.CreditLogPanel.Size = UDim2.fromOffset(configurations.CreditLogWidthPx or 340, configurations.CreditLogHeightPx or 380)
configurations.CreditLogPanel.Position = UDim2.fromOffset(100, 90)
configurations.CreditLogPanel.ZIndex = 90
configurations.CreditLogPanel.BackgroundColor3 = UIColors.BG
configurations.CreditLogPanel.BorderSizePixel = 0
configurations.CreditLogPanel.Visible = false
configurations.CreditLogPanel.Parent = ScreenGui
Instance.new("UICorner", configurations.CreditLogPanel).CornerRadius = UDim.new(0, 12)
configurations.RegisterScaledRoot(configurations.CreditLogPanel)
configurations.CreditLogPanelStroke = Instance.new("UIStroke", configurations.CreditLogPanel)
configurations.CreditLogPanelStroke.Color = UIColors.BORDER
configurations.CreditLogPanelStroke.Thickness = 1
configurations.CreditLogPanelStroke.Transparency = 0.35

configurations.CreditLogHeader = Instance.new("Frame")
configurations.CreditLogHeader.Name = "Header"
configurations.CreditLogHeader.Size = UDim2.new(1, 0, 0, 44)
configurations.CreditLogHeader.ZIndex = 91
configurations.CreditLogHeader.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
configurations.CreditLogHeader.BorderSizePixel = 0
configurations.CreditLogHeader.Parent = configurations.CreditLogPanel
Instance.new("UICorner", configurations.CreditLogHeader).CornerRadius = UDim.new(0, 12)

configurations.CreditLogHeaderFix = Instance.new("Frame")
configurations.CreditLogHeaderFix.Size = UDim2.new(1, 0, 0, 16)
configurations.CreditLogHeaderFix.Position = UDim2.new(0, 0, 1, -16)
configurations.CreditLogHeaderFix.ZIndex = 91
configurations.CreditLogHeaderFix.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
configurations.CreditLogHeaderFix.BorderSizePixel = 0
configurations.CreditLogHeaderFix.Parent = configurations.CreditLogHeader

configurations.CreditLogTitle = Instance.new("TextLabel")
configurations.CreditLogTitle.Size = UDim2.new(1, -56, 0, 22)
configurations.CreditLogTitle.Position = UDim2.fromOffset(14, 11)
configurations.CreditLogTitle.ZIndex = 92
configurations.CreditLogTitle.BackgroundTransparency = 1
configurations.CreditLogTitle.Text = "Credit Log"
configurations.CreditLogTitle.TextColor3 = UIColors.TEXT
configurations.CreditLogTitle.TextSize = 16
configurations.CreditLogTitle.Font = Enum.Font.GothamBold
configurations.CreditLogTitle.TextXAlignment = Enum.TextXAlignment.Left
configurations.CreditLogTitle.Parent = configurations.CreditLogHeader

configurations.CreditLogCloseButton = Instance.new("TextButton")
configurations.CreditLogCloseButton.Size = UDim2.fromOffset(32, 32)
configurations.CreditLogCloseButton.Position = UDim2.new(1, -40, 0, 6)
configurations.CreditLogCloseButton.ZIndex = 92
configurations.CreditLogCloseButton.BackgroundColor3 = UIColors.INPUT
configurations.CreditLogCloseButton.BorderSizePixel = 0
configurations.CreditLogCloseButton.Text = "×"
configurations.CreditLogCloseButton.TextColor3 = UIColors.TEXT
configurations.CreditLogCloseButton.TextSize = 19
configurations.CreditLogCloseButton.Font = Enum.Font.GothamBold
configurations.CreditLogCloseButton.Parent = configurations.CreditLogHeader
Instance.new("UICorner", configurations.CreditLogCloseButton).CornerRadius = UDim.new(0, 6)

configurations.CreditLogFilterScroll = Instance.new("ScrollingFrame")
configurations.CreditLogFilterScroll.Name = "PlayerFilters"
configurations.CreditLogFilterScroll.Size = UDim2.new(1, -20, 0, 32)
configurations.CreditLogFilterScroll.Position = UDim2.fromOffset(10, 48)
configurations.CreditLogFilterScroll.ZIndex = 91
configurations.CreditLogFilterScroll.BackgroundTransparency = 1
configurations.CreditLogFilterScroll.BorderSizePixel = 0
configurations.CreditLogFilterScroll.ScrollBarThickness = 2
configurations.CreditLogFilterScroll.ScrollBarImageColor3 = UIColors.MUTED
configurations.CreditLogFilterScroll.CanvasSize = UDim2.new()
configurations.CreditLogFilterScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
configurations.CreditLogFilterScroll.ScrollingDirection = Enum.ScrollingDirection.X
configurations.CreditLogFilterScroll.Parent = configurations.CreditLogPanel
configurations.CreditLogFilterLayout = Instance.new("UIListLayout", configurations.CreditLogFilterScroll)
configurations.CreditLogFilterLayout.FillDirection = Enum.FillDirection.Horizontal
configurations.CreditLogFilterLayout.Padding = UDim.new(0, 4)
configurations.CreditLogFilterLayout.SortOrder = Enum.SortOrder.LayoutOrder

configurations.CreditLogScroll = Instance.new("ScrollingFrame")
configurations.CreditLogScroll.Name = "Credits"
configurations.CreditLogScroll.Size = UDim2.new(1, -16, 1, -90)
configurations.CreditLogScroll.Position = UDim2.fromOffset(8, 84)
configurations.CreditLogScroll.ZIndex = 91
configurations.CreditLogScroll.BackgroundTransparency = 1
configurations.CreditLogScroll.BorderSizePixel = 0
configurations.CreditLogScroll.ScrollBarThickness = 3
configurations.CreditLogScroll.ScrollBarImageColor3 = UIColors.MUTED
configurations.CreditLogScroll.CanvasSize = UDim2.new()
configurations.CreditLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
configurations.CreditLogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
configurations.CreditLogScroll.Parent = configurations.CreditLogPanel

-- Grid: name + timer cells only
configurations.CreditLogLayout = Instance.new("UIGridLayout")
configurations.CreditLogLayout.Name = "CreditGrid"
configurations.CreditLogLayout.CellSize = UDim2.fromOffset(150, 40)
configurations.CreditLogLayout.CellPadding = UDim2.fromOffset(6, 6)
configurations.CreditLogLayout.FillDirection = Enum.FillDirection.Horizontal
configurations.CreditLogLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
configurations.CreditLogLayout.SortOrder = Enum.SortOrder.LayoutOrder
configurations.CreditLogLayout.Parent = configurations.CreditLogScroll

local CreditLogGridPad = Instance.new("UIPadding")
CreditLogGridPad.PaddingTop = UDim.new(0, 2)
CreditLogGridPad.PaddingLeft = UDim.new(0, 2)
CreditLogGridPad.PaddingRight = UDim.new(0, 2)
CreditLogGridPad.PaddingBottom = UDim.new(0, 2)
CreditLogGridPad.Parent = configurations.CreditLogScroll

function configurations.RefreshCreditLog()
	for _, entry in pairs(configurations.CreditLogEntries) do
		entry.NameButton = nil
		entry.CountdownLabel = nil
	end
	for _, child in ipairs(configurations.CreditLogFilterScroll:GetChildren()) do
		if child.Name:match("^CreditLogFilter_") then child:Destroy() end
	end
	for _, child in ipairs(configurations.CreditLogScroll:GetChildren()) do
		if child.Name:match("^CreditLogRow_") or child.Name == "CreditLogEmpty" then child:Destroy() end
	end

	local userIds = {}
	for userId in pairs(configurations.CreditLogKnownPlayers) do table.insert(userIds, userId) end
	table.sort(userIds, function(a, b)
		return string.lower(configurations.CreditLogKnownPlayers[a]) < string.lower(configurations.CreditLogKnownPlayers[b])
	end)
	for order, userId in ipairs(userIds) do
		local filterUserId = userId
		local hidden = configurations.CreditLogHiddenUsers[userId] == true
		local filterButton = Instance.new("TextButton")
		filterButton.Name = "CreditLogFilter_" .. userId
		filterButton.Size = UDim2.fromOffset(96, 26)
		filterButton.LayoutOrder = order
		filterButton.ZIndex = 92
		filterButton.BackgroundColor3 = hidden and UIColors.INPUT or UIColors.GREEN_DIM
		filterButton.BorderSizePixel = 0
		filterButton.AutoButtonColor = false
		filterButton.Text = (hidden and "@" or "✓ @") .. configurations.CreditLogKnownPlayers[userId]
		filterButton.TextColor3 = hidden and UIColors.MUTED or UIColors.GREEN
		filterButton.TextSize = 11
		filterButton.Font = Enum.Font.GothamBold
		filterButton.TextTruncate = Enum.TextTruncate.AtEnd
		filterButton.Parent = configurations.CreditLogFilterScroll
		Instance.new("UICorner", filterButton).CornerRadius = UDim.new(0, 6)
		filterButton.MouseButton1Click:Connect(function()
			configurations.CreditLogHiddenUsers[filterUserId] = not (configurations.CreditLogHiddenUsers[filterUserId] == true)
			configurations.CreditLogDirty = true
			configurations.SaveConfig()
			configurations.RefreshCreditLog()
		end)
	end

	local rows = {}
	for _, entry in pairs(configurations.CreditLogEntries) do
		if configurations.CreditLogHiddenUsers[entry.UserId] ~= true
			and (not entry.ExpireAt or entry.ExpireAt > os.clock()) then
			table.insert(rows, entry)
		end
	end
	table.sort(rows, function(a, b)
		return (a.ExpireAt or math.huge) < (b.ExpireAt or math.huge)
	end)
	for order, entry in ipairs(rows) do
		local creditedUserId = entry.UserId
		local row = Instance.new("Frame")
		row.Name = "CreditLogRow_" .. tostring(order)
		row.LayoutOrder = order
		row.ZIndex = 92
		row.BackgroundColor3 = UIColors.CARD
		row.BorderSizePixel = 0
		row.Parent = configurations.CreditLogScroll
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
		local rowStroke = Instance.new("UIStroke", row)
		rowStroke.Color = UIColors.BORDER
		rowStroke.Transparency = 0.55
		rowStroke.Thickness = 1

		local nameButton = Instance.new("TextButton")
		nameButton.Name = "CreditedPlayer"
		nameButton.Size = UDim2.new(1, -8, 0, 18)
		nameButton.Position = UDim2.fromOffset(6, 3)
		nameButton.ZIndex = 93
		nameButton.BackgroundTransparency = 1
		nameButton.AutoButtonColor = false
		nameButton.Text = "@" .. entry.Username
		nameButton.TextColor3 = UIColors.TEXT
		nameButton.TextSize = 12
		nameButton.Font = Enum.Font.GothamBold
		nameButton.TextXAlignment = Enum.TextXAlignment.Left
		nameButton.TextTruncate = Enum.TextTruncate.AtEnd
		nameButton.Parent = row
		entry.NameButton = nameButton
		nameButton.MouseButton1Click:Connect(function()
			configurations.OpenPlayerCardByUserId(creditedUserId)
		end)

		local countdown = Instance.new("TextLabel")
		countdown.Name = "Countdown"
		countdown.Size = UDim2.new(1, -8, 0, 14)
		countdown.Position = UDim2.fromOffset(6, 22)
		countdown.ZIndex = 93
		countdown.BackgroundTransparency = 1
		countdown.TextColor3 = UIColors.GREEN
		countdown.TextSize = 11
		countdown.Font = Enum.Font.GothamBold
		countdown.TextXAlignment = Enum.TextXAlignment.Left
		countdown.Parent = row
		entry.CountdownLabel = countdown
	end
	if #rows == 0 then
		-- Full-width empty state (span grid by using a tall label)
		local empty = Instance.new("TextLabel")
		empty.Name = "CreditLogEmpty"
		empty.Size = UDim2.fromOffset(300, 40)
		empty.LayoutOrder = 1
		empty.ZIndex = 92
		empty.BackgroundTransparency = 1
		empty.Text = "No credits yet"
		empty.TextColor3 = UIColors.MUTED
		empty.TextSize = 12
		empty.Font = Enum.Font.Gotham
		empty.Parent = configurations.CreditLogScroll
	end
	configurations.CreditLogDirty = false
	configurations.ApplyTextScale(configurations.CreditLogPanel)
end

configurations.CreditLogButton.MouseButton1Click:Connect(function()
	local isOpen = not configurations.CreditLogPanel.Visible
	configurations.CreditLogPanel.Visible = isOpen
	configurations.SetActionVisual(configurations.CreditLogButton, isOpen and "Close log" or "Credit Log", isOpen)
	if isOpen then
		configurations.CreditLogDirty = true
		configurations.RefreshCreditLog()
	end
end)
configurations.CreditLogCloseButton.MouseButton1Click:Connect(function()
	configurations.CreditLogPanel.Visible = false
	configurations.SetActionVisual(configurations.CreditLogButton, "Credit Log", false)
end)

function configurations.MakeDraggable(panel, handle)
	local dragging = false
	local dragStart
	local startAbs
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startAbs = panel.AbsolutePosition
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
			if not viewport or viewport.X < 1 or viewport.Y < 1 then return end
			local delta = input.Position - dragStart
			local w = panel.AbsoluteSize.X
			local h = panel.AbsoluteSize.Y
			local x = math.clamp(startAbs.X + delta.X, 8, math.max(8, viewport.X - w - 8))
			local y = math.clamp(startAbs.Y + delta.Y, 8, math.max(8, viewport.Y - h - 8))
			panel.Position = UDim2.fromOffset(x, y)
		end
	end)
end

configurations.MakeDraggable(PlayerPanel, PlayerPanelHeader)
configurations.MakeDraggable(configurations.WhitelistPanel, configurations.WhitelistHeader)
configurations.MakeDraggable(configurations.JoinLogPanel, configurations.JoinLogHeader)
configurations.MakeDraggable(configurations.CreditLogPanel, configurations.CreditLogHeader)

function configurations.MakeResizable(panel, name, minWidthPx, minHeightPx, onReleased, maxWidthPx, maxHeightPx)
	local handle = Instance.new("TextButton")
	handle.Name = name .. "ResizeHandle"
	handle.Size = UDim2.fromOffset(28, 28)
	handle.AnchorPoint = Vector2.new(1, 1)
	handle.Position = UDim2.new(1, -6, 1, -6)
	handle.ZIndex = 95
	handle.BackgroundColor3 = UIColors.INPUT
	handle.BackgroundTransparency = 0.05
	handle.BorderSizePixel = 0
	handle.Text = "↘"
	handle.TextColor3 = UIColors.ACCENT
	handle.TextSize = 16
	handle.Font = Enum.Font.GothamBold
	handle.Parent = panel
	Instance.new("UICorner", handle).CornerRadius = UDim.new(0, 8)
	local handleStroke = Instance.new("UIStroke", handle)
	handleStroke.Color = UIColors.BORDER
	handleStroke.Transparency = 0.15
	handleStroke.Thickness = 1
	handle.MouseEnter:Connect(function()
		handle.BackgroundColor3 = UIColors.ACCENT_DIM
		handle.TextColor3 = UIColors.ACCENT_SEL
	end)
	handle.MouseLeave:Connect(function()
		handle.BackgroundColor3 = UIColors.INPUT
		handle.TextColor3 = UIColors.ACCENT
	end)

	local resizing = false
	local startPoint
	local startW, startH
	handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		resizing = true
		startPoint = input.Position
		startW = panel.Size.X.Offset > 0 and panel.Size.X.Offset or minWidthPx
		startH = panel.Size.Y.Offset > 0 and panel.Size.Y.Offset or minHeightPx
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				resizing = false
				if onReleased then onReleased(panel.Size.X.Offset, panel.Size.Y.Offset) end
			end
		end)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing or (input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch) then return end
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		if not viewport then return end
		local uiScale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale()
			or math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
		local delta = input.Position - startPoint
		local maxW = math.max(minWidthPx, math.min(maxWidthPx or 560, math.floor((viewport.X - panel.AbsolutePosition.X - 8) / uiScale)))
		local maxH = math.max(minHeightPx, math.min(maxHeightPx or 700, math.floor((viewport.Y - panel.AbsolutePosition.Y - 8) / uiScale)))
		panel.Size = UDim2.fromOffset(
			math.clamp(math.floor(startW + delta.X / uiScale + 0.5), minWidthPx, maxW),
			math.clamp(math.floor(startH + delta.Y / uiScale + 0.5), minHeightPx, maxH)
		)
	end)
end

configurations.MakeResizable(PlayerPanel, "PlayerPanel", 280, 300, function(width, height)
	configurations.PlayerPanelWidthPx, configurations.PlayerPanelHeightPx = width, height
	configurations.SaveConfig()
end, 560, 700)
configurations.MakeResizable(configurations.WhitelistPanel, "WhitelistPanel", 240, 260, function(width, height)
	configurations.WhitelistPanelWidthPx, configurations.WhitelistPanelHeightPx = width, height
	configurations.SaveConfig()
end, 520, 640)
configurations.MakeResizable(configurations.JoinLogPanel, "JoinLogPanel", 260, 260, function(width, height)
	configurations.JoinLogWidthPx, configurations.JoinLogHeightPx = width, height
	configurations.SaveConfig()
end, 560, 640)
configurations.MakeResizable(configurations.CreditLogPanel, "CreditLogPanel", 280, 280, function(width, height)
	configurations.CreditLogWidthPx, configurations.CreditLogHeightPx = width, height
	configurations.SaveConfig()
end, 560, 700)

function configurations.ApplyResponsiveOverlaySizes()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize
	if not viewport or viewport.X < 1 or viewport.Y < 1 then return end
	local uiScale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale()
		or math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)

	configurations.ClampOverlaySize = function(panel, widthPx, heightPx, maxW, maxH)
		if not panel or not panel.Parent then return end
		local wantW = math.floor(tonumber(widthPx) or panel.Size.X.Offset or 320)
		local wantH = math.floor(tonumber(heightPx) or panel.Size.Y.Offset or 360)
		local fitW = math.max(240, math.floor((viewport.X - 24) / uiScale))
		local fitH = math.max(200, math.floor((viewport.Y - 24) / uiScale))
		local w = math.clamp(wantW, 240, math.min(maxW or 560, fitW))
		local h = math.clamp(wantH, 200, math.min(maxH or 700, fitH))

		local abs = panel.AbsolutePosition
		local px = (panel.AbsoluteSize.X > 0) and abs.X or 40
		local py = (panel.AbsoluteSize.Y > 0) and abs.Y or 80
		px = math.clamp(px, 8, math.max(8, viewport.X - w * uiScale - 8))
		py = math.clamp(py, 8, math.max(8, viewport.Y - h * uiScale - 8))
		panel.Size = UDim2.fromOffset(w, h)
		panel.Position = UDim2.fromOffset(px, py)
	end

	if not configurations.PlayerPanelCardMode then
		configurations.ClampOverlaySize(PlayerPanel, configurations.PlayerPanelWidthPx, configurations.PlayerPanelHeightPx, 560, 700)
	end
	configurations.ClampOverlaySize(configurations.WhitelistPanel, configurations.WhitelistPanelWidthPx, configurations.WhitelistPanelHeightPx, 520, 640)
	configurations.ClampOverlaySize(configurations.JoinLogPanel, configurations.JoinLogWidthPx, configurations.JoinLogHeightPx, 560, 640)
	configurations.ClampOverlaySize(configurations.CreditLogPanel, configurations.CreditLogWidthPx, configurations.CreditLogHeightPx, 560, 700)
end
configurations.ApplyResponsiveOverlaySizes()

function configurations.RefreshWhitelist()
	for _, child in ipairs(configurations.WhitelistScroll:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	local ids = {}
	for userId in pairs(configurations.WhitelistIds) do table.insert(ids, userId) end
	table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
	for order, userId in ipairs(ids) do
		local playerName = nil
		local online = false
		for _, onlinePlayer in ipairs(Players:GetPlayers()) do
			if tostring(onlinePlayer.UserId) == userId then
				playerName = onlinePlayer.Name
				online = true
				break
			end
		end

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -8, 0, 52)
		row.LayoutOrder = order
		row.ZIndex = 92
		row.BackgroundColor3 = UIColors.CARD
		row.BorderSizePixel = 0
		row.Parent = configurations.WhitelistScroll
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
		local stroke = Instance.new("UIStroke", row)
		stroke.Color = UIColors.BORDER
		stroke.Transparency = 0.55
		stroke.Thickness = 1

		local idLabel = Instance.new("TextLabel")
		idLabel.Size = UDim2.new(1, -56, 0, 18)
		idLabel.Position = UDim2.fromOffset(12, 8)
		idLabel.ZIndex = 93
		idLabel.BackgroundTransparency = 1
		idLabel.Text = userId
		idLabel.TextColor3 = UIColors.MUTED
		idLabel.TextSize = 12
		idLabel.Font = Enum.Font.Gotham
		idLabel.TextXAlignment = Enum.TextXAlignment.Left
		idLabel.TextTruncate = Enum.TextTruncate.AtEnd
		idLabel.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -56, 0, 18)
		nameLabel.Position = UDim2.fromOffset(12, 28)
		nameLabel.ZIndex = 93
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = playerName and ("@" .. playerName) or "Offline"
		nameLabel.TextColor3 = online and UIColors.TEXT or UIColors.MUTED
		nameLabel.TextSize = 13
		nameLabel.Font = Enum.Font.GothamMedium
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Parent = row

		local removeButton = Instance.new("TextButton")
		removeButton.Size = UDim2.fromOffset(36, 36)
		removeButton.Position = UDim2.new(1, -46, 0.5, -18)
		removeButton.ZIndex = 93
		removeButton.BackgroundColor3 = UIColors.RED_DIM
		removeButton.BorderSizePixel = 0
		removeButton.Text = "×"
		removeButton.TextColor3 = UIColors.RED
		removeButton.TextSize = 18
		removeButton.Font = Enum.Font.GothamBold
		removeButton.Parent = row
		Instance.new("UICorner", removeButton).CornerRadius = UDim.new(0, 8)
		removeButton.MouseButton1Click:Connect(function()
			configurations.WhitelistIds[userId] = nil
			configurations.SaveConfig()
			configurations.RefreshWhitelist()
			configurations.OnWhitelistChanged(userId)
		end)
	end
	configurations.ApplyTextScale(configurations.WhitelistPanel)
end

WhitelistButton.MouseButton1Click:Connect(function()
	configurations.WhitelistPanel.Visible = not configurations.WhitelistPanel.Visible
	if configurations.WhitelistPanel.Visible then configurations.RefreshWhitelist() end
end)
configurations.WhitelistCloseButton.MouseButton1Click:Connect(function()
	configurations.WhitelistPanel.Visible = false
end)

function configurations.AddWhitelistId()
	local idText = configurations.WhitelistInput.Text:match("^%s*(%d+)%s*$")
	if not idText then
		configurations.WhitelistInput.Text = ""
		configurations.WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	local userId = idText:gsub("^0+", "")
	if userId == "" then
		configurations.WhitelistInput.Text = ""
		configurations.WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	configurations.WhitelistIds[userId] = true
	configurations.WhitelistInput.Text = ""
	configurations.WhitelistInput.PlaceholderText = "Enter Player UserId"
	configurations.SaveConfig()
	configurations.RefreshWhitelist()
	configurations.OnWhitelistChanged(userId)
end

function configurations.AddAllServerPlayersToWhitelist()
	local added = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= Player then
			local userId = tostring(player.UserId)
			if not configurations.WhitelistIds[userId] then
				configurations.WhitelistIds[userId] = true
				added += 1
			end
		end
	end
	if added > 0 then
		configurations.SaveConfig()
		configurations.RefreshWhitelist()
		configurations.OnWhitelistChanged()
	end
	configurations.NotifyUser("Whitelist", added > 0 and ("Added " .. added .. " player(s).") or "All players are already whitelisted.")
	return added
end

configurations.AddWhitelistButton.MouseButton1Click:Connect(configurations.AddWhitelistId)
configurations.AddAllWhitelistButton.MouseButton1Click:Connect(configurations.AddAllServerPlayersToWhitelist)
configurations.WhitelistInput.FocusLost:Connect(function(enterPressed)
	if enterPressed then configurations.AddWhitelistId() end
end)

AlarmOverlay = Instance.new("Frame")
AlarmOverlay.Name = "FullScreenAlarm"
AlarmOverlay.Size = UDim2.fromScale(1, 1)
AlarmOverlay.BackgroundColor3 = UIColors.RED
AlarmOverlay.BackgroundTransparency = 0.35
AlarmOverlay.BorderSizePixel = 0
AlarmOverlay.Visible = false
AlarmOverlay.Active = false
AlarmOverlay.ZIndex = 100
AlarmOverlay.Parent = ScreenGui

configurations.AlarmText = Instance.new("TextLabel")
configurations.AlarmText.Size = UDim2.new(1, 0, 0, 72)
configurations.AlarmText.Position = UDim2.new(0, 0, 0.5, -36)
configurations.AlarmText.BackgroundTransparency = 1
configurations.AlarmText.Text = ""
configurations.AlarmText.TextColor3 = Color3.new(1, 1, 1)
configurations.AlarmText.TextStrokeTransparency = 0.15
configurations.AlarmText.TextSize = 30
configurations.AlarmText.Font = Enum.Font.GothamBlack
configurations.AlarmText.ZIndex = 101
configurations.AlarmText.Parent = AlarmOverlay

configurations.ExpHitFeedbackLabel = Instance.new("TextLabel")
configurations.ExpHitFeedbackLabel.Name = "ExpHitFeedback"
configurations.ExpHitFeedbackLabel.AnchorPoint = Vector2.new(0.5, 0.5)
configurations.ExpHitFeedbackLabel.Size = UDim2.new(0.82, 0, 0, 92)
configurations.ExpHitFeedbackLabel.Position = UDim2.fromScale(0.5, 0.5)
configurations.ExpHitFeedbackLabel.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
configurations.ExpHitFeedbackLabel.BackgroundTransparency = 0.18
configurations.ExpHitFeedbackLabel.BorderSizePixel = 0
configurations.ExpHitFeedbackLabel.Text = "ตีถืกแล้วเด้อ"
configurations.ExpHitFeedbackLabel.TextColor3 = Color3.fromRGB(255, 226, 104)
configurations.ExpHitFeedbackLabel.TextStrokeColor3 = Color3.fromRGB(16, 17, 22)
configurations.ExpHitFeedbackLabel.TextStrokeTransparency = 0.12
configurations.ExpHitFeedbackLabel.TextScaled = true
configurations.ExpHitFeedbackLabel.Font = Enum.Font.GothamBlack
configurations.ExpHitFeedbackLabel.Visible = false
configurations.ExpHitFeedbackLabel.ZIndex = 110
configurations.ExpHitFeedbackLabel.Parent = ScreenGui
Instance.new("UICorner", configurations.ExpHitFeedbackLabel).CornerRadius = UDim.new(0, 12)
configurations.ExpHitFeedbackTextConstraint = Instance.new("UITextSizeConstraint")
configurations.ExpHitFeedbackTextConstraint.MinTextSize = 28
configurations.ExpHitFeedbackTextConstraint.MaxTextSize = 48
configurations.ExpHitFeedbackTextConstraint.Parent = configurations.ExpHitFeedbackLabel

function configurations.ShowExpHitFeedback()
	if not configurations.ExpHitFeedbackEnabled then return end
	local target = configurations.ExpHitWatchTarget
	if not target or not target:IsDescendantOf(MobsFolder) then return end
	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	configurations.ExpHitFeedbackTarget = target
	configurations.UpdateExpHitFeedback()
end

function configurations.UpdateExpHitFeedback()
	local target = configurations.ExpHitFeedbackTarget
	local humanoid = target and target:FindFirstChildOfClass("Humanoid")
	local alive = target ~= nil and target:IsDescendantOf(MobsFolder)
		and humanoid ~= nil and humanoid.Health > 0
	if not alive then configurations.ExpHitFeedbackTarget = nil end
	if configurations.ExpHitFeedbackLabel then
		configurations.ExpHitFeedbackLabel.Visible = configurations.ExpHitFeedbackEnabled and alive == true
	end
end

function configurations.ResetExpHitTagWatch()
	if configurations.ExpHitWatchHumanoidChildAddedConnection then configurations.ExpHitWatchHumanoidChildAddedConnection:Disconnect() end
	if configurations.ExpHitWatchHumanoidChildRemovedConnection then configurations.ExpHitWatchHumanoidChildRemovedConnection:Disconnect() end
	if configurations.ExpHitWatchTagChildAddedConnection then configurations.ExpHitWatchTagChildAddedConnection:Disconnect() end
	if configurations.ExpHitWatchHitsConnection then configurations.ExpHitWatchHitsConnection:Disconnect() end
	configurations.ExpHitWatchHumanoidChildAddedConnection = nil
	configurations.ExpHitWatchHumanoidChildRemovedConnection = nil
	configurations.ExpHitWatchTagChildAddedConnection = nil
	configurations.ExpHitWatchHitsConnection = nil
	configurations.ExpHitWatchDamageTag = nil
	configurations.ExpHitWatchHits = nil
	configurations.ExpHitLastHits = nil
	configurations.ExpHitDamageTagWasAdded = false
end

function configurations.BindExpHitDamageHits(tag)
	-- This per-player creator tag is written by the mob's damage handler; Hits is the hit confirmation.
	if not tag or configurations.ExpHitWatchDamageTag ~= tag then return false end
	local hits = tag:FindFirstChild("Hits")
	if hits and not (hits:IsA("IntValue") or hits:IsA("NumberValue")) then hits = nil end
	if configurations.ExpHitWatchHits == hits then return true end
	if configurations.ExpHitWatchHitsConnection then configurations.ExpHitWatchHitsConnection:Disconnect() end
	configurations.ExpHitWatchHits = hits
	configurations.ExpHitWatchHitsConnection = nil
	configurations.ExpHitLastHits = hits and tonumber(hits.Value) or nil
	if hits then
		if configurations.ExpHitDamageTagWasAdded and configurations.ExpHitLastHits and configurations.ExpHitLastHits > 0 then
			configurations.ShowExpHitFeedback()
		end
		configurations.ExpHitDamageTagWasAdded = false
		configurations.ExpHitWatchHitsConnection = hits:GetPropertyChangedSignal("Value"):Connect(function()
			local currentHits = tonumber(hits.Value)
			local previousHits = configurations.ExpHitLastHits
			configurations.ExpHitLastHits = currentHits
			if currentHits and previousHits and currentHits > previousHits then
				configurations.ShowExpHitFeedback()
			end
		end)
	end
	return true
end

function configurations.BindExpHitDamageTag(tag, wasJustAdded)
	if configurations.ExpHitWatchDamageTag == tag then return true end
	if configurations.ExpHitWatchTagChildAddedConnection then configurations.ExpHitWatchTagChildAddedConnection:Disconnect() end
	if configurations.ExpHitWatchHitsConnection then configurations.ExpHitWatchHitsConnection:Disconnect() end
	configurations.ExpHitWatchTagChildAddedConnection = nil
	configurations.ExpHitWatchHitsConnection = nil
	configurations.ExpHitWatchDamageTag = nil
	configurations.ExpHitWatchHits = nil
	configurations.ExpHitLastHits = nil
	configurations.ExpHitDamageTagWasAdded = false
	if not tag or not tag:IsA("StringValue")
		or string.sub(tag.Name, 1, 8) ~= "creator_" or tag.Value ~= Player.Name then
		return false
	end
	configurations.ExpHitWatchDamageTag = tag
	configurations.ExpHitDamageTagWasAdded = wasJustAdded == true
	configurations.ExpHitWatchTagChildAddedConnection = tag.ChildAdded:Connect(function(child)
		if child.Name == "Hits" then configurations.BindExpHitDamageHits(tag) end
	end)
	configurations.BindExpHitDamageHits(tag)
	return true
end

function configurations.WatchExpTargetForHit(target)
	if not target or not target:IsDescendantOf(MobsFolder) then target = nil end
	local humanoid = target and target:FindFirstChildOfClass("Humanoid")
	if configurations.ExpHitWatchTarget == target and configurations.ExpHitWatchHumanoid == humanoid then return end
	configurations.ResetExpHitTagWatch()
	configurations.ExpHitWatchTarget = target
	configurations.ExpHitWatchHumanoid = humanoid
	if not humanoid then return end

	local tagPrefix = "creator_"
	configurations.ExpHitWatchHumanoidChildAddedConnection = humanoid.ChildAdded:Connect(function(child)
		if child:IsA("StringValue") and string.sub(child.Name, 1, #tagPrefix) == tagPrefix
			and child.Value == Player.Name then
			configurations.BindExpHitDamageTag(child, true)
		end
	end)
	configurations.ExpHitWatchHumanoidChildRemovedConnection = humanoid.ChildRemoved:Connect(function(child)
		if child == configurations.ExpHitWatchDamageTag then configurations.BindExpHitDamageTag(nil, false) end
	end)
	for _, child in ipairs(humanoid:GetChildren()) do
		if child:IsA("StringValue") and string.sub(child.Name, 1, #tagPrefix) == tagPrefix
			and child.Value == Player.Name then
			configurations.BindExpHitDamageTag(child, false)
			break
		end
	end
end

function configurations.RemoveCreditLogEntry(tag)
	local entry = configurations.CreditLogEntries[tag]
	if not entry then return false end
	configurations.CreditLogEntries[tag] = nil
	configurations.CreditLogDirty = true
	return true
end

function configurations.TrackCreditLogTag(tag)
	if not tag or not tag:IsA("StringValue") then return false end
	local userId = string.match(tag.Name, "^creator_(%d+)$")
	if not userId then return false end
	local entry = configurations.CreditLogEntries[tag]
	if not entry then
		entry = { Tag = tag, UserId = userId, Username = tag.Value, CreatedAt = os.clock(), ExpireAt = nil }
		configurations.CreditLogEntries[tag] = entry
		configurations.CreditLogDirty = true
	end
	local previousUsername = entry.Username
	entry.Username = tag.Value ~= "" and tag.Value or entry.Username
	configurations.CreditLogKnownPlayers[userId] = entry.Username
	if previousUsername ~= entry.Username then configurations.CreditLogDirty = true end
	return true
end

function configurations.WatchCreditLogTarget(target)
	if not target or not target:IsDescendantOf(MobsFolder) then target = nil end
	local humanoid = target and target:FindFirstChildOfClass("Humanoid")
	if configurations.CreditLogTarget == target and configurations.CreditLogHumanoid == humanoid then return end
	if configurations.CreditLogChildAddedConnection then configurations.CreditLogChildAddedConnection:Disconnect() end
	if configurations.CreditLogChildRemovedConnection then configurations.CreditLogChildRemovedConnection:Disconnect() end
	configurations.CreditLogChildAddedConnection = nil
	configurations.CreditLogChildRemovedConnection = nil
	for tag in pairs(configurations.CreditLogEntries) do
		configurations.RemoveCreditLogEntry(tag)
	end
	configurations.CreditLogTarget = target
	configurations.CreditLogHumanoid = humanoid
	if not humanoid then return end
	configurations.CreditLogChildAddedConnection = humanoid.ChildAdded:Connect(function(child)
		if child:IsA("StringValue") then configurations.TrackCreditLogTag(child) end
	end)
	configurations.CreditLogChildRemovedConnection = humanoid.ChildRemoved:Connect(function(child)
		configurations.RemoveCreditLogEntry(child)
	end)
	for _, child in ipairs(humanoid:GetChildren()) do
		if child:IsA("StringValue") then configurations.TrackCreditLogTag(child) end
	end
end

function configurations.UpdateCreditLog()
	local now = os.clock()
	for tag, entry in pairs(configurations.CreditLogEntries) do
		if not tag.Parent or tag.Parent ~= configurations.CreditLogHumanoid
			or (tag.Value == "" and (entry.Username ~= "" or now - (entry.CreatedAt or now) > 1)) then
			configurations.RemoveCreditLogEntry(tag)
		else
			local previousUsername = entry.Username
			entry.Username = tag.Value ~= "" and tag.Value or entry.Username
			configurations.CreditLogKnownPlayers[entry.UserId] = entry.Username
			if previousUsername ~= entry.Username then configurations.CreditLogDirty = true end
			local startObject = tag:FindFirstChild("StartTime")
			local endObject = tag:FindFirstChild("EndTime")
			local startTime = startObject and tonumber(startObject.Value)
			local endTime = endObject and tonumber(endObject.Value)
			if startTime ~= entry.LastStartTime or endTime ~= entry.LastEndTime then
				entry.LastStartTime = startTime
				entry.LastEndTime = endTime
				-- The tag's StartTime/EndTime delta is the credit lifetime requested for this log.
				entry.ExpireAt = startTime and endTime and now + math.max(0, endTime - startTime) or nil
				configurations.CreditLogDirty = true
			end
			if entry.NameButton and entry.NameButton.Parent and entry.NameButton.Text ~= "HIT · @" .. entry.Username then
				entry.NameButton.Text = "HIT · @" .. entry.Username
			end
			if entry.CountdownLabel and entry.CountdownLabel.Parent then
				local remaining = entry.ExpireAt and math.max(0, math.ceil(entry.ExpireAt - now)) or nil
				entry.CountdownLabel.Text = remaining and string.format("CREDIT · %02d:%02d", math.floor(remaining / 60), remaining % 60) or "CREDIT · WAITING"
			end
			if entry.ExpireAt and now >= entry.ExpireAt then
				configurations.RemoveCreditLogEntry(tag)
			end
		end
	end
	if configurations.CreditLogPanel and configurations.CreditLogPanel.Visible and configurations.CreditLogDirty then
		configurations.RefreshCreditLog()
	end
end

configurations.PlayerEspLayer = Instance.new("Frame")
configurations.PlayerEspLayer.Name = "PlayerESPLayer"
configurations.PlayerEspLayer.Size = UDim2.fromScale(1, 1)
configurations.PlayerEspLayer.BackgroundTransparency = 1
configurations.PlayerEspLayer.Active = false
configurations.PlayerEspLayer.ZIndex = 0
configurations.PlayerEspLayer.Parent = ScreenGui

configurations.ResizeHandle = Instance.new("TextButton")
configurations.ResizeHandle.Name = "ResizeHandle"
configurations.ResizeHandle.Visible = not configurations.IsMinimized
configurations.ResizeHandle.Size = UDim2.fromOffset(24, 24)
configurations.ResizeHandle.AnchorPoint = Vector2.new(1, 1)
configurations.ResizeHandle.Position = UDim2.new(1, -8, 1, -8)
configurations.ResizeHandle.ZIndex = 95
configurations.ResizeHandle.BackgroundColor3 = UIColors.INPUT
configurations.ResizeHandle.BackgroundTransparency = 0.05
configurations.ResizeHandle.BorderSizePixel = 0
configurations.ResizeHandle.AutoButtonColor = false
configurations.ResizeHandle.Text = "↘"
configurations.ResizeHandle.TextColor3 = UIColors.ACCENT
configurations.ResizeHandle.TextSize = 15
configurations.ResizeHandle.Font = Enum.Font.GothamBold
configurations.ResizeHandle.Parent = Main
Instance.new("UICorner", configurations.ResizeHandle).CornerRadius = UDim.new(0, 8)
local mainResizeStroke = Instance.new("UIStroke", configurations.ResizeHandle)
mainResizeStroke.Color = UIColors.BORDER
mainResizeStroke.Transparency = 0.15
mainResizeStroke.Thickness = 1
configurations.ResizeHandle.MouseEnter:Connect(function()
	configurations.ResizeHandle.BackgroundColor3 = UIColors.ACCENT_DIM
	configurations.ResizeHandle.TextColor3 = UIColors.ACCENT_SEL
end)
configurations.ResizeHandle.MouseLeave:Connect(function()
	configurations.ResizeHandle.BackgroundColor3 = UIColors.INPUT
	configurations.ResizeHandle.TextColor3 = UIColors.ACCENT
end)

configurations.Resizing, configurations.ResizeStart, configurations.ResizeStartSize = false, nil, nil
configurations.ResizeHandle.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		configurations.Resizing = true
		configurations.ResizeStart = input.Position
		configurations.ResizeStartSize = Vector2.new(
			Main.Size.X.Offset > 0 and Main.Size.X.Offset or configurations.MainWidthPx,
			Main.Size.Y.Offset > 0 and Main.Size.Y.Offset or configurations.MainHeightPx
		)
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				configurations.Resizing = false
				configurations.MainWidthPx = Main.Size.X.Offset
				configurations.MainHeightPx = Main.Size.Y.Offset
				configurations.SaveConfig()
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not configurations.Resizing then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local viewport = camera.ViewportSize
	local delta = input.Position - configurations.ResizeStart
	local uiScale = configurations.GetEffectiveGuiScale and configurations.GetEffectiveGuiScale()
		or math.clamp(tonumber(configurations.GuiScale) or 1, 0.20, 2.50)
	local maxW = math.max(360, math.floor((viewport.X - Main.AbsolutePosition.X - 16) / uiScale))
	local maxH = math.max(320, math.floor((viewport.Y - Main.AbsolutePosition.Y - 16) / uiScale))
	local w = math.clamp(math.floor(configurations.ResizeStartSize.X + delta.X / uiScale + 0.5), 360, math.min(900, maxW))
	local h = configurations.IsMinimized and configurations.ResizeStartSize.Y
		or math.clamp(math.floor(configurations.ResizeStartSize.Y + delta.Y / uiScale + 0.5), 320, math.min(900, maxH))
	configurations.MainWidthPx = w
	configurations.MainHeightPx = h
	Main.Size = UDim2.fromOffset(w, h)
end)


--==================================================
-- STATUS HELPERS
--==================================================
function configurations.PauseTimer()
	if not configurations.IsPaused and configurations.LastTarget then
		configurations.AccumulatedTime = configurations.AccumulatedTime + (os.clock() - configurations.TargetStartTime)
		configurations.IsPaused = true
	end
end

function configurations.SetIdle(finishCurrentExpTarget)
	local finishTarget = configurations.AutoExecuteEnabled and finishCurrentExpTarget and configurations.CurrentTarget
	if finishTarget and configurations.Combat.IsLivingMob(finishTarget) then
		configurations.ExpFinishTarget = finishTarget
	else
		configurations.ExpFinishTarget = nil
	end
	if not configurations.AlertCombatPending then
		configurations.ExpRetaliationTarget = nil
	end
	configurations.Farming = false
	if configurations.StopExpMovement then configurations.StopExpMovement() end
	configurations.PauseTimer()
	StartBtn.Text = "Start"
	StartBtn.BackgroundColor3 = UIColors.ACCENT
	Status.Text = "OFF"
	Status.TextColor3 = UIColors.RED
	Status.BackgroundColor3 = UIColors.RED_DIM
	StateLabel.Text = configurations.ExpFinishTarget and "Finishing EXP target" or "Stopped"
	MiniState.Text = configurations.ExpFinishTarget and "EXP paused — killing the locked target" or "Stopped"
	TimeLabel.Text = configurations.FormatTime(configurations.AccumulatedTime)
	MiniTime.Text = TimeLabel.Text
end

function configurations.SetRunning()
	if configurations.AlertCombatPending or configurations.AlertCombatHold or configurations.AlertCombatBlockReady then return end
	configurations.AlertResumeRequired = false
	configurations.AlertWasFarming = false
	configurations.AlertBlockPromptShown = false
	configurations.ExpLastShotTarget = nil
	configurations.EmergencyStopActive = false
	if configurations.UpdateEmergencyStopButton then configurations.UpdateEmergencyStopButton() end
	configurations.Farming = true
	configurations.ExpMaxCombatTarget = nil
	configurations.ExpFinishTarget = nil
	configurations.IsPaused = false
	configurations.SessionExpGained = 0
	configurations.SessionFarmSeconds = 0
	configurations.NoProgressCycles = 0
	SessionLabel.Text = "Session: +0 EXP / 00:00:00 / 0 EXP/h"
	configurations.RecentCycle = "รอบล่าสุด  -"
	RecentCycleLabel.Text = configurations.RecentCycle
	if configurations.LastTarget then
		configurations.TargetStartTime = os.clock()
	end
	StartBtn.Text = "Stop"
	StartBtn.BackgroundColor3 = UIColors.RED
	Status.Text = "ON"
	Status.TextColor3 = UIColors.GREEN
	Status.BackgroundColor3 = UIColors.GREEN_DIM
	StateLabel.Text = "Searching..."
	MiniState.Text = "Searching..."
end

function configurations.HandleExpMax(target)
	local living = configurations.Combat.IsLivingMob(target)
	configurations.ExpMaxCombatTarget = configurations.AutoExecuteEnabled and living and target or nil
	configurations.PauseTimer()
	if configurations.AutoExecuteEnabled and living then
		StateLabel.Text = "EXP max - finishing target"
		MiniState.Text = "Auto Execute: attacking this EXP target until it dies"
	else
		if living and configurations.CurrentTarget == target then
			configurations.CurrentTarget = nil
			if configurations.ExpLastShotTarget == target then configurations.ExpLastShotTarget = nil end
			configurations.ClearBillboard()
		end
		StateLabel.Text = "EXP max - finding another mob"
		MiniState.Text = "Auto Execute is off; skipping the capped mob and continuing EXP farm"
	end
	-- Keep the farm loop alive at the cap. With Auto Execute off, drop the capped
	-- target so the search can pick another mob or wait for a fresh spawn.
	return true
end

StartBtn.MouseButton1Click:Connect(function()
	if configurations.Farming then
		configurations.SetIdle(true)
	else
		configurations.SetRunning()
	end
end)

Status.MouseButton1Click:Connect(function()
	if configurations.Farming then
		configurations.SetIdle(true)
	else
		configurations.SetRunning()
	end
end)

--==================================================
-- FIND TARGET
--==================================================
function configurations.FindTarget()
	local char = Player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	MobCache_Rebuild(false)
	local best, bestDist, bestRemaining = nil, math.huge, math.huge
	for _, entry in ipairs(MobCache.List) do
		local mob, exp, mroot = entry.Mob, entry.EXP, entry.Root
		if not entry.HasEXP or not exp then
			continue
		end
		if exp.Value >= configurations.ExpGoal then
			continue
		end
		local humanoid = entry.Humanoid
		if not humanoid or not humanoid.Parent then
			humanoid = mob:FindFirstChildOfClass("Humanoid")
			entry.Humanoid = humanoid
		end
		if humanoid and humanoid.Health <= 0 then
			continue
		end
		if not mroot or not mroot.Parent then
			mroot = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
			entry.Root = mroot
		end
		if not mroot or not mroot:IsA("BasePart") then
			continue
		end
		local d = (root.Position - mroot.Position).Magnitude
		if d > configurations.MaxDistance then
			continue
		end
		local remaining = configurations.ExpGoal - exp.Value
		-- Prefer closer targets; break distance ties with less remaining EXP (finishes faster).
		if d < bestDist - 0.5 or (math.abs(d - bestDist) <= 0.5 and remaining < bestRemaining) then
			bestDist = d
			bestRemaining = remaining
			best = mob
		end
	end
	return best
end

function configurations.Combat.IsLivingMob(mob)
	if not mob or not mob:IsDescendantOf(MobsFolder) then return false end
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health > 0
end

function configurations.Combat.IsActiveExpTarget(mob, exp)
	return mob ~= nil
		and configurations.CurrentTarget == mob
		and mob:IsDescendantOf(MobsFolder)
		and configurations.Combat.IsLivingMob(mob)
		and exp ~= nil
		and exp.Parent ~= nil
		and exp:IsDescendantOf(mob)
end

function configurations.Combat.GetExpExecutionTarget()
	local candidates = {}
	if configurations.ExpLastShotTarget then table.insert(candidates, configurations.ExpLastShotTarget) end
	if configurations.CurrentTarget then table.insert(candidates, configurations.CurrentTarget) end
	if configurations.LastTarget then table.insert(candidates, configurations.LastTarget) end
	for _, mob in ipairs(candidates) do
		if configurations.Combat.IsLivingMob(mob) then
			local cfg = mob:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			if exp and (exp:IsA("IntValue") or exp:IsA("NumberValue")) then
				return mob
			end
		end
	end
	return nil
end

function configurations.Combat.GetWeaponEquipState(character)
	if not character then return false, false end
	-- F8's character layout stores the weapon as Character.Sword/MainWeld
	-- and waits for PlayerStats before using this state.
	local playerStats = Player:FindFirstChild("PlayerStats")	
	if not playerStats then return false, false end
	-- UpperTorso means the sword is stowed; another Part1 means it is in hand.
	local sword = character:FindFirstChild("Sword")
	local mainWeld = sword and sword:FindFirstChild("MainWeld", true)
	if not sword or not mainWeld then return false, false end
	if mainWeld then
		local ok, part1 = pcall(function() return mainWeld.Part1 end)
		if ok then
			if part1 and part1.Name == "UpperTorso" then return false, true end
			if part1 then return true, false end
			return false, true
		end
	end

	return false, false
end

function configurations.Combat.StowWeaponAfterMobDeath(mob)
	if not mob or configurations.Combat.IsLivingMob(mob)
		or configurations.LastWeaponStowMob == mob then
		return false
	end
	local now = os.clock()
	if configurations.LastWeaponStowAttemptMob == mob
		and now - (configurations.LastWeaponStowAttemptAt or 0) < 0.75 then
		return false
	end
	configurations.LastWeaponStowAttemptMob = mob
	configurations.LastWeaponStowAttemptAt = now
	local character = Player.Character
	local hasWeapon, needsEquip = configurations.Combat.GetWeaponEquipState(character)
	if needsEquip then
		configurations.LastWeaponStowMob = mob
		return true
	end
	if not hasWeapon then return false end
	local playerGui = Player:FindFirstChildOfClass("PlayerGui")
	local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
	if not inputFunction or not inputFunction:IsA("BindableFunction") then return false end
	local ok = pcall(function()
		inputFunction:Invoke("EquipButton", Enum.UserInputState.Begin)
	end)
	if ok then
		configurations.LastWeaponStowMob = mob
		return true
	end
	return false
end

function configurations.Combat.GetSelectedCombatMob(localRoot)
	if not localRoot then return nil end
	local function horizontalDistance(a, b)
		local offset = b - a
		return Vector3.new(offset.X, 0, offset.Z).Magnitude
	end
	local function resolve(mob, maxDistance)
		if not configurations.Combat.IsLivingMob(mob) or not mob:IsDescendantOf(MobsFolder) then return nil end
		local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then return nil end
		local distance = horizontalDistance(localRoot.Position, root.Position)
		if maxDistance and distance > maxDistance then return nil end
		return mob, root, distance
	end
	-- A deferred post-Block kill must stay locked even when Auto Execute is off.
	if configurations.PendingServerHop then
		local mob, root, distance = resolve(configurations.ServerHopKillTarget)
		if mob then return mob, root, distance end
		return nil
	end
	-- Auto Execute takes priority over list selection and locks the EXP mob to finish.
	if configurations.AutoExecuteEnabled then
		if configurations.AlertCombatPending then
			local mob, root, distance = resolve(configurations.AlertCombatTarget)
			if mob then return mob, root, distance end
			return nil
		end
		if configurations.ExpMaxCombatTarget then
			local mob, root, distance = resolve(configurations.ExpMaxCombatTarget)
			if mob then return mob, root, distance end
			configurations.ExpMaxCombatTarget = nil
			return nil
		end
		if configurations.ExpFinishTarget then
			local mob, root, distance = resolve(configurations.ExpFinishTarget)
			if mob then return mob, root, distance end
			configurations.ExpFinishTarget = nil
			return nil
		end
	end
	local retaliationMob, retaliationRoot, retaliationDistance = resolve(configurations.ExpRetaliationTarget)
	if retaliationMob then return retaliationMob, retaliationRoot, retaliationDistance end
	if configurations.AutoBossTargetEnabled or configurations.AutoMiniBossTargetEnabled then
		MobCache_Rebuild(false)
		local nearestMob, nearestRoot, nearestDistance
		for _, entry in ipairs(MobCache.List) do
			local mob = entry.Mob
			local matchesBoss = configurations.AutoBossTargetEnabled and mob:FindFirstChild("IsBoss") ~= nil
			local matchesMiniBoss = configurations.AutoMiniBossTargetEnabled and mob:FindFirstChild("IsMiniBoss") ~= nil
			if matchesBoss or matchesMiniBoss then
				local candidate, root, distance = resolve(mob, configurations.AutoAttackSearchRange)
				if candidate and (not nearestDistance or distance < nearestDistance) then
					nearestMob, nearestRoot, nearestDistance = candidate, root, distance
				end
			end
		end
		if nearestMob then return nearestMob, nearestRoot, nearestDistance end
		return nil
	end
	local selectedMob = configurations.SelectedCombatMob
	if not selectedMob or not selectedMob:IsDescendantOf(MobsFolder) then
		configurations.SelectedCombatMob = nil
		return nil
	end
	return resolve(selectedMob, configurations.AutoAttackSearchRange)
end

function configurations.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, currentExp)
	local elapsed = math.max(os.clock() - cycleStartTime, 0.001)
	local gained = currentExp - cycleStartExp
	configurations.RecentCycle = string.format("Last: +%s EXP / %.2fs / %d calls", configurations.FormatNumber(gained), elapsed, callsSent)
	RecentCycleLabel.Text = configurations.RecentCycle
	configurations.SessionExpGained += math.max(gained, 0)
	configurations.SessionFarmSeconds += elapsed
	local sessionRate = configurations.SessionFarmSeconds > 0 and (configurations.SessionExpGained / configurations.SessionFarmSeconds) * 3600 or 0
	SessionLabel.Text = string.format("Session: +%s EXP / %s / %s EXP/h", configurations.FormatNumber(configurations.SessionExpGained), configurations.FormatTime(configurations.SessionFarmSeconds), configurations.FormatNumber(sessionRate))
	if callsSent > 0 and gained <= 0 then
		configurations.NoProgressCycles += 1
	else
		configurations.NoProgressCycles = 0
	end
end

--==================================================
-- FARM LOOP (ยิงไม่เกิน Max)
--==================================================
task.spawn(function()
	local expMoveState = { Active = false, Goal = nil, LastMoveAt = 0 }
	local chasingExpTarget = nil
	configurations.StopExpMovement = function()
		local character = Player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and root then humanoid:MoveTo(root.Position) end
		chasingExpTarget = nil
		expMoveState.Active = false
		expMoveState.Goal = nil
	end
	local watchedTarget = nil
	local lastObservedExp = nil
	local lastExpProgressAt = 0
	local adaptiveYield = 0
	local lastCycleGain = 0
	local lastCycleCalls = 0
	-- Must close in once per target before the first shot; after that, keep firing while walking back.
	local engagedFireTarget = nil
	while true do
		if not configurations.Farming or configurations.EmergencyStopActive then
			if watchedTarget then
				local watchedConfig = watchedTarget:FindFirstChild("Config")
				local watchedExp = watchedConfig and watchedConfig:FindFirstChild("EXP")
				if watchedExp then lastObservedExp = watchedExp.Value end
				lastExpProgressAt = os.clock()
			end
			if chasingExpTarget or expMoveState.Active then
				local character = Player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
				expMoveState.Active = false
				expMoveState.Goal = nil
			end
			task.wait(0.12)
			continue
		end

		local target = configurations.CurrentTarget
		local retaliationTarget = configurations.ExpRetaliationTarget
		if retaliationTarget then
			if configurations.Combat.IsLivingMob(retaliationTarget) then
				StateLabel.Text = "EXP target hit"
				MiniState.Text = "Attacking the damaged EXP target until it dies"
				task.wait(0.1)
				continue
			end
			configurations.ExpRetaliationTarget = nil
		end

		if target and configurations.Combat.IsLivingMob(target) then
			-- ยึดตัวเดิม
		else
			if target and not configurations.Combat.IsLivingMob(target) then
				configurations.Combat.StowWeaponAfterMobDeath(target)
			end
			if chasingExpTarget or expMoveState.Active then
				local character = Player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
				expMoveState.Active = false
				expMoveState.Goal = nil
			end
			if configurations.ExpMaxCombatTarget == target then
				configurations.ExpMaxCombatTarget = nil
			end
			if configurations.ExpLastShotTarget == target and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpLastShotTarget = nil
			end
			configurations.ClearBillboard()
			configurations.CurrentTarget = nil
			engagedFireTarget = nil
			target = configurations.FindTarget()
			configurations.CurrentTarget = target

			if not target then
				TargetLabel.Text = "No target"
				ExpLabel.Text = "-"
				MiniExp.Text = "-"
				DistLabel.Text = "Dist  -"
				StateLabel.Text = "Searching..."
				MiniState.Text = "Searching within the configured radius"
				RateLabel.Text = "Rate -"
				configurations.PauseTimer()
				task.wait(0.5)
				continue
			end

			local cfg = target:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			configurations.AttachBillboard(target, exp and tonumber(exp.Value) or 0)

			-- เริ่มจับเวลา rate ของมอนตัวนี้
			configurations.SessionStartEXP = exp and tonumber(exp.Value) or 0
			configurations.SessionStartTime = os.clock()
		end

		local cfg = target:FindFirstChild("Config")
		local exp = cfg and cfg:FindFirstChild("EXP")
		if not exp then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for target EXP data"
			task.wait(0.25)
			continue
		end

		local now = os.clock()
		if watchedTarget ~= target then
			watchedTarget = target
			lastObservedExp = exp.Value
			lastExpProgressAt = now
		elseif exp.Value ~= lastObservedExp then
			lastObservedExp = exp.Value
			lastExpProgressAt = now
		end

		if exp.Value < configurations.ExpGoal and now - lastExpProgressAt >= 20 then
			local character = Player.Character
			local playerGui = Player:FindFirstChildOfClass("PlayerGui")
			local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
			local _, needsEquip = configurations.Combat.GetWeaponEquipState(character)
			StateLabel.Text = needsEquip and "Checking weapon" or "EXP stalled"
			MiniState.Text = needsEquip and "No EXP change; checking weapon and keeping target" or "No EXP change; retrying same target"
			if needsEquip and inputFunction and inputFunction:IsA("BindableFunction") then
				pcall(function()
					inputFunction:Invoke("EquipButton", Enum.UserInputState.Begin)
				end)
			end
			lastExpProgressAt = now
			local recoveryEndsAt = now + 3
			while configurations.Farming and not configurations.EmergencyStopActive and os.clock() < recoveryEndsAt do
				task.wait(0.1)
			end
			continue
		end

		local char = Player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local mroot = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
		local dist = (root and mroot) and (root.Position - mroot.Position).Magnitude or 0

		local expNow = tonumber(exp.Value) or 0
		TargetLabel.Text = target.Name
		ExpLabel.Text = configurations.FormatNumber(expNow)
		MaxLabel.Text = "/ " .. configurations.FormatNumber(configurations.ExpGoal)
		DistLabel.Text = "Dist  " .. string.format("%.1f", dist)
		-- Keep marker alive/updated even if the host part respawned.
		if not configurations.CurrentBillboard or not configurations.CurrentBillboard.Parent then
			configurations.AttachBillboard(target, expNow)
		else
			configurations.UpdateBillboardText(expNow, expNow >= configurations.ExpGoal)
		end

		-- Move only when outside firing range. Holding still inside range avoids orbiting away from the mob.
		if configurations.ExpAutoApproachEnabled and exp.Value < configurations.ExpGoal and root and mroot
			and configurations.ExpRetaliationTarget ~= target
			and configurations.ExpMaxCombatTarget ~= target
			and not (configurations.PendingServerHop and configurations.ServerHopKillTarget == target)
			and not (configurations.AlertCombatPending and configurations.AlertCombatTarget == target) then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local standoff = configurations.ExpApproachDistance
			if dist > standoff + 0.75 then
				local goal = OrbitApproachPoint(root, mroot, standoff)
				SmoothMoveTo(humanoid, root, goal, expMoveState, dist > 60 and 0.18 or 0.28, 1.8)
				chasingExpTarget = target
			elseif expMoveState.Active then
				if humanoid then humanoid:MoveTo(root.Position) end
				expMoveState.Active = false
				expMoveState.Goal = nil
				chasingExpTarget = nil
			else
				chasingExpTarget = nil
			end
		elseif chasingExpTarget or expMoveState.Active then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			if humanoid and root then humanoid:MoveTo(root.Position) end
			chasingExpTarget = nil
			expMoveState.Active = false
			expMoveState.Goal = nil
		end

		-- เมื่อถึง Max ให้คงเป้าหมายเดิมไว้จนกว่ามอนจะตาย
		if exp.Value >= configurations.ExpGoal then
			if not configurations.HandleExpMax(target) then
				task.wait(0.2)
				continue
			end
			configurations.UpdateBillboardText(exp.Value, true)
			Bar.Size = UDim2.fromScale(1, 1)
			PercentLabel.Text = "100%"
			task.wait(0.2)
			continue
		end

		if configurations.ExpAutoApproachEnabled and dist > configurations.ExpApproachDistance + 1 then
			StateLabel.Text = "Moving"
			MiniState.Text = "Walking to locked EXP target"
		elseif configurations.NoProgressCycles >= 2 then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for EXP to update on this target"
		else
			StateLabel.Text = "Firing"
			MiniState.Text = "Sending EXP to locked target"
		end
		configurations.UpdateBillboardText(exp.Value, false)

		-- Adaptive fire: scale batch + yield from recent progress.
		local remaining = configurations.ExpGoal - exp.Value
		local baseAmount = configurations.Amount
		if configurations.NoProgressCycles >= 2 then
			baseAmount = math.max(200, math.floor(baseAmount * 0.35))
		elseif lastCycleCalls > 0 and lastCycleGain <= 0 then
			baseAmount = math.max(300, math.floor(baseAmount * 0.55))
		elseif lastCycleCalls > 0 and lastCycleGain >= lastCycleCalls * 0.6 then
			baseAmount = math.min(configurations.Amount, math.floor(baseAmount * 1.15))
		end
		local toFire = math.min(baseAmount, math.max(0, remaining))
		local cycleStartExp = exp.Value
		local cycleStartTime = os.clock()
		local callsSent = 0
		local batchYieldEvery = 40
		if adaptiveYield > 0.008 then
			batchYieldEvery = 25
		elseif lastCycleGain > 0 and lastCycleCalls > 0 and (lastCycleGain / lastCycleCalls) > 0.8 then
			batchYieldEvery = 60
		end

		while callsSent < toFire do
			if not configurations.Farming or configurations.EmergencyStopActive then break end
			if not configurations.Combat.IsActiveExpTarget(target, exp) then break end
			if configurations.ExpRetaliationTarget == target
				or configurations.ExpMaxCombatTarget == target
				or (configurations.PendingServerHop and configurations.ServerHopKillTarget == target)
				or (configurations.AlertCombatPending and configurations.AlertCombatTarget == target) then
				break
			end
			if exp.Value >= configurations.ExpGoal then break end
			local firingCharacter = Player.Character
			local firingRoot = firingCharacter and firingCharacter:FindFirstChild("HumanoidRootPart")
			local firingMobRoot = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
			local firingDistance = firingRoot and firingMobRoot
				and (firingRoot.Position - firingMobRoot.Position).Magnitude or math.huge
			local inApproach = not configurations.ExpAutoApproachEnabled
				or firingDistance <= configurations.ExpApproachDistance + 0.75
			local hasEngaged = engagedFireTarget == target

			-- EXP target movement is opt-in; Combat can still approach the target
			-- separately for Alert or Max handling.
			if configurations.ExpAutoApproachEnabled and firingRoot and firingMobRoot and not inApproach then
				local moveHumanoid = firingCharacter and firingCharacter:FindFirstChildOfClass("Humanoid")
				if moveHumanoid then
					local goal = OrbitApproachPoint(firingRoot, firingMobRoot, configurations.ExpApproachDistance)
					SmoothMoveTo(moveHumanoid, firingRoot, goal, expMoveState, 0.22, 1.6)
					chasingExpTarget = target
				end
			elseif firingRoot and expMoveState.Active then
				local moveHumanoid = firingCharacter and firingCharacter:FindFirstChildOfClass("Humanoid")
				if moveHumanoid then moveHumanoid:MoveTo(firingRoot.Position) end
				expMoveState.Active = false
				expMoveState.Goal = nil
				chasingExpTarget = nil
			end

			-- First contact: must enter approach range once before any shots on this target.
			if not hasEngaged then
				if not inApproach then
					StateLabel.Text = "Moving"
					MiniState.Text = string.format("Approach target once (%.0f / %.0f studs)", firingDistance, configurations.ExpApproachDistance)
					task.wait(0.08)
					continue
				end
				engagedFireTarget = target
				hasEngaged = true
			end

			-- After engaged: keep firing even if range is briefly lost; only bail if way outside search radius.
			if firingDistance > configurations.MaxDistance + 25 then
				StateLabel.Text = configurations.ExpAutoApproachEnabled and "Moving" or "Waiting"
				MiniState.Text = configurations.ExpAutoApproachEnabled
					and string.format("Too far (%.0f); walking back into %.0f studs", firingDistance, configurations.MaxDistance)
				or string.format("Target too far (%.0f); Auto approach OFF (limit %.0f)", firingDistance, configurations.MaxDistance)
				task.wait(0.08)
				continue
			end

			if inApproach then
				StateLabel.Text = "Firing"
				MiniState.Text = "Sending EXP to locked target"
			else
				StateLabel.Text = "Moving + Firing"
				MiniState.Text = string.format("Out of standoff (%.0f); firing while closing in", firingDistance)
			end

			configurations.ExpLastShotTarget = target
			InitClashing:FireServer(2, exp)
			callsSent += 1

			-- Adaptive throttle near max / after stalled cycles / periodic yield for replicate.
			if exp.Value >= configurations.ExpGoal - 200 then
				task.wait(0.025 + adaptiveYield)
			elseif configurations.NoProgressCycles >= 2 and callsSent % 15 == 0 then
				task.wait(0.03 + adaptiveYield)
			elseif callsSent % batchYieldEvery == 0 then
				task.wait(math.max(0, adaptiveYield))
			end
		end

		if not configurations.Farming or configurations.EmergencyStopActive then continue end

		if not configurations.Combat.IsActiveExpTarget(target, exp) then
			if configurations.CurrentTarget == target then
				configurations.ClearBillboard()
				configurations.CurrentTarget = nil
			end
			if configurations.ExpLastShotTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpLastShotTarget = nil
			end
			if configurations.ExpRetaliationTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpRetaliationTarget = nil
			end
			if configurations.ExpMaxCombatTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpMaxCombatTarget = nil
			end
			if configurations.ExpFinishTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpFinishTarget = nil
			end
			if engagedFireTarget == target then engagedFireTarget = nil end
			task.wait(0.05)
			continue
		end

		if exp.Value >= configurations.ExpGoal then
			configurations.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, exp.Value)
			lastCycleGain = math.max(0, exp.Value - cycleStartExp)
			lastCycleCalls = callsSent
			adaptiveYield = math.max(0, adaptiveYield - 0.004)
			if not configurations.HandleExpMax(target) then
				task.wait(0.2)
				continue
			end
			configurations.UpdateBillboardText(exp.Value, true)
			Bar.Size = UDim2.fromScale(1, 1)
			PercentLabel.Text = "100%"
			task.wait(0.2)
			continue
		end

		-- รอ EXP ขึ้น (timeout สั้นลงเมื่อใกล้ Max)
		if configurations.Combat.IsActiveExpTarget(target, exp)
			and configurations.ExpRetaliationTarget ~= target
			and configurations.ExpMaxCombatTarget ~= target
			and not (configurations.PendingServerHop and configurations.ServerHopKillTarget == target)
			and not (configurations.AlertCombatPending and configurations.AlertCombatTarget == target) then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for EXP update on locked target"
			local expected = math.min(cycleStartExp + callsSent, configurations.ExpGoal)
			local startWait = os.clock()
			local maxWait = (exp.Value >= configurations.ExpGoal - 500) and 2 or 5

			while configurations.Farming and not configurations.EmergencyStopActive
				and configurations.Combat.IsActiveExpTarget(target, exp)
				and configurations.ExpRetaliationTarget ~= target
				and configurations.ExpMaxCombatTarget ~= target
				and not (configurations.PendingServerHop and configurations.ServerHopKillTarget == target)
				and not (configurations.AlertCombatPending and configurations.AlertCombatTarget == target)
				and exp.Value < expected do
				if exp.Value >= configurations.ExpGoal then break end
				if os.clock() - startWait > maxWait then break end
				task.wait(0.05)
			end
		end

		if configurations.Farming and not configurations.EmergencyStopActive
			and not configurations.Combat.IsActiveExpTarget(target, exp) then
			if configurations.CurrentTarget == target then
				configurations.ClearBillboard()
				configurations.CurrentTarget = nil
			end
			if configurations.ExpLastShotTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpLastShotTarget = nil
			end
			if configurations.ExpRetaliationTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpRetaliationTarget = nil
			end
			if configurations.ExpMaxCombatTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpMaxCombatTarget = nil
			end
			if configurations.ExpFinishTarget == target
				and not configurations.Combat.IsLivingMob(target) then
				configurations.ExpFinishTarget = nil
			end
			if engagedFireTarget == target then engagedFireTarget = nil end
			task.wait(0.05)
			continue
		end

		configurations.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, exp.Value)
		lastCycleGain = math.max(0, exp.Value - cycleStartExp)
		lastCycleCalls = callsSent
		if callsSent > 0 and lastCycleGain <= 0 then
			adaptiveYield = math.min(0.04, adaptiveYield + 0.008)
		elseif lastCycleGain > 0 then
			adaptiveYield = math.max(0, adaptiveYield - 0.006)
		end

		if configurations.Farming then
			if not configurations.Combat.IsActiveExpTarget(target, exp) then
				if configurations.CurrentTarget == target then
					configurations.ClearBillboard()
					configurations.CurrentTarget = nil
				end
				if configurations.ExpLastShotTarget == target
					and not configurations.Combat.IsLivingMob(target) then
					configurations.ExpLastShotTarget = nil
				end
				if configurations.ExpRetaliationTarget == target
					and not configurations.Combat.IsLivingMob(target) then
					configurations.ExpRetaliationTarget = nil
				end
				if configurations.ExpMaxCombatTarget == target
					and not configurations.Combat.IsLivingMob(target) then
					configurations.ExpMaxCombatTarget = nil
				end
				if configurations.ExpFinishTarget == target
					and not configurations.Combat.IsLivingMob(target) then
					configurations.ExpFinishTarget = nil
				end
				if engagedFireTarget == target then engagedFireTarget = nil end
				task.wait(0.05)
				continue
			end
			if exp.Value >= configurations.ExpGoal then
				configurations.PauseTimer()
				continue
			end
			if configurations.ExpRetaliationTarget == target
				or configurations.ExpMaxCombatTarget == target
				or (configurations.PendingServerHop and configurations.ServerHopKillTarget == target)
				or (configurations.AlertCombatPending and configurations.AlertCombatTarget == target) then
				continue
			end
			StateLabel.Text = configurations.NoProgressCycles >= 2 and "Waiting" or "Interval"
			MiniState.Text = configurations.NoProgressCycles >= 2
				and "EXP did not update; keeping the same target"
				or ("Waiting " .. tostring(configurations.Interval) .. "s before next cycle")
			task.wait(configurations.Interval)
		end
	end
end)

--==================================================
-- AUTO FARM / AUTO SKILL (uses the game's input bindable)
--==================================================
task.spawn(function()
	local lastAttackAt = 0
	local lastSkillAt = 0
	local lastEquipAt = 0
	local attackMoveState = { Active = false, Goal = nil, LastMoveAt = 0, Target = nil }
	local chasingMob = false
	local lastFinishHandoffTarget = nil
	local lastRetaliationAttackTarget = nil
	while true do
		local combatTargetPresent = false
		local autoMarkedTarget = configurations.AutoBossTargetEnabled or configurations.AutoMiniBossTargetEnabled
		local canCombatDuringExp = configurations.Farming
			and (configurations.ExpMaxCombatTarget ~= nil or configurations.ExpRetaliationTarget ~= nil
				or configurations.PendingServerHop or configurations.ExpFinishTarget ~= nil)
		local forceFinishExp = configurations.PendingServerHop and configurations.ServerHopKillTarget ~= nil
		local priorityCombat = configurations.AlertCombatPending or configurations.ExpMaxCombatTarget ~= nil
			or configurations.ExpRetaliationTarget ~= nil or configurations.PendingServerHop
			or (configurations.AutoExecuteEnabled and configurations.ExpFinishTarget ~= nil)
		if not configurations.EmergencyStopActive
			and (configurations.AutoAttackEnabled or configurations.AutoSkillEnabled or priorityCombat or autoMarkedTarget)
			and not configurations.AlertCombatHold
			and (not configurations.Farming or canCombatDuringExp or forceFinishExp)
			and not configurations.AlertCombatBlockReady then
			local character = Player.Character
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			local target, targetRoot, distance
			if localRoot then
				local selectedMob, selectedRoot, selectedDistance = configurations.Combat.GetSelectedCombatMob(localRoot)
				target, targetRoot, distance = selectedMob, selectedRoot, selectedDistance
			end
			if target == configurations.ExpRetaliationTarget and target then
				if lastRetaliationAttackTarget ~= target then
					lastAttackAt = os.clock() - configurations.AutoAttackInterval
					lastRetaliationAttackTarget = target
				end
			else
				lastRetaliationAttackTarget = nil
			end
			if target and targetRoot then
				combatTargetPresent = true
				if target == configurations.ExpFinishTarget and target ~= lastFinishHandoffTarget then
					configurations.CombatSystem.ResetNavigationState(attackMoveState)
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					attackMoveState.LastMoveAt = 0
					attackMoveState.Target = nil
					chasingMob = false
					lastFinishHandoffTarget = target
				elseif target ~= configurations.ExpFinishTarget then
					lastFinishHandoffTarget = nil
				end
				local attackRange = math.min(
					configurations.AutoAttackRange,
					math.max(7, configurations.AutoAttackStandoff + 3)
				)
				if attackMoveState.Target ~= target then
					if attackMoveState.Target and not configurations.Combat.IsLivingMob(attackMoveState.Target) then
						configurations.Combat.StowWeaponAfterMobDeath(attackMoveState.Target)
					end
					if attackMoveState.Target ~= nil and attackMoveState.Active then
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					end
					configurations.CombatSystem.ResetNavigationState(attackMoveState)
					attackMoveState.Target = target
				end
				-- Keep steering toward the selected mob while attacking, including at close range.
				local forcedExpCombat = target == configurations.AlertCombatTarget and configurations.AlertCombatPending
					or target == configurations.ExpMaxCombatTarget
					or target == configurations.ExpFinishTarget and configurations.AutoExecuteEnabled
					or target == configurations.ExpRetaliationTarget
					or target == configurations.ServerHopKillTarget and configurations.PendingServerHop
				if localRoot and (configurations.AutoAttackEnabled or forcedExpCombat or autoMarkedTarget) then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					ClaimMovement("Combat", humanoid, localRoot)
					local approachPoint = configurations.CombatSystem.SelectApproachPoint(
						localRoot, targetRoot, configurations.AutoAttackStandoff, target, attackMoveState, attackRange
					)
					approachPoint = configurations.CombatSystem.GroundAlignGoal(localRoot, approachPoint, target)
					local interval = (distance or 0) > 40 and 0.24 or 0.14
					local stopRadius = 1.8
					local arrived, navigationState = configurations.CombatSystem.NavigateMoveTo(
						humanoid, localRoot, approachPoint, target, attackMoveState, interval, stopRadius, true
					)
					attackMoveState.NavigationMode = navigationState
					chasingMob = not arrived
					local finishingExpTarget = target == configurations.ExpFinishTarget
						or target == configurations.ExpMaxCombatTarget
						or configurations.AlertCombatPending and target == configurations.AlertCombatTarget
					StateLabel.Text = navigationState == "detouring" and "Going around obstacle"
						or (finishingExpTarget and "Finishing EXP target" or "Moving to target")
					MiniState.Text = navigationState == "detouring" and "Steering around the obstacle"
						or (finishingExpTarget and "Moving to the locked EXP target"
							or (distance > attackRange and "Moving into attack range" or "Moving around target while attacking"))
				elseif chasingMob or attackMoveState.Active then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					configurations.CombatSystem.ResetNavigationState(attackMoveState)
					chasingMob = false
					attackMoveState.Target = nil
					ReleaseMovement("Combat", humanoid, localRoot)
				else
					attackMoveState.Target = nil
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					ReleaseMovement("Combat", humanoid, localRoot)
				end

				if distance <= attackRange or chasingMob then
					local playerGui = Player:FindFirstChildOfClass("PlayerGui")
					local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
					if inputFunction and inputFunction:IsA("BindableFunction") then
						local now = os.clock()
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						local hasWeapon, needsEquip = configurations.Combat.GetWeaponEquipState(character)
						local canAttack = humanoid and humanoid.Health > 0 and hasWeapon
						if not canAttack then
							configurations.CombatInfo.Text = needsEquip and "Waiting for Sword; trying EquipButton before attacking." or "Waiting for PlayerStats and Sword/MainWeld."
							if not configurations.Farming or configurations.AlertCombatPending or configurations.ExpMaxCombatTarget then
								StateLabel.Text = needsEquip and "Equipping" or "Waiting"
								MiniState.Text = needsEquip and "Auto Attack is equipping the Sword" or "Waiting for Sword and PlayerStats"
							end
							-- Match F8: an un-equipped or UpperTorso-stowed weapon needs EquipButton.
							if needsEquip and now - lastEquipAt >= 1 then
								local ok, err = pcall(function()
									inputFunction:Invoke("EquipButton", Enum.UserInputState.Begin)
								end)
								lastEquipAt = now
								if not ok then warn("Auto Equip failed:", err) end
							end
						else
							configurations.CombatInfo.Text = configurations.AlertCombatPending and "Alert response: attacking only the locked EXP target." or "Weapon ready; Auto Attack can engage the selected target."
							if configurations.AlertCombatPending and target == configurations.AlertCombatTarget then
								StateLabel.Text = "Alert execute"
								MiniState.Text = distance > attackRange
									and "EXP paused — closing in on the locked target"
									or "EXP paused — attacking the locked target before Block"
							elseif target == configurations.ExpFinishTarget or target == configurations.ExpMaxCombatTarget then
								StateLabel.Text = distance > attackRange and "Moving and finishing target" or "Finishing target"
								MiniState.Text = distance > attackRange and "Attacking while moving to the locked EXP target" or "Attacking the locked EXP target until it dies"
							elseif not configurations.Farming or configurations.AlertCombatPending or configurations.ExpRetaliationTarget == target then
								StateLabel.Text = distance > attackRange and "Moving and attacking" or "Attacking"
								MiniState.Text = distance > attackRange and "Attacking while closing distance" or "In range — attacking target"
							end
							if (configurations.AutoAttackEnabled or forcedExpCombat or autoMarkedTarget)
								and now - lastAttackAt >= configurations.AutoAttackInterval then
								if distance <= attackRange and (target == configurations.CurrentTarget
									or target == configurations.ExpMaxCombatTarget
									or target == configurations.ExpFinishTarget
									or target == configurations.AlertCombatTarget
									or target == configurations.ExpRetaliationTarget
									or target == configurations.ServerHopKillTarget
									or target == configurations.ExpLastShotTarget) then
									configurations.WatchExpTargetForHit(target)
								end
								local ok, err = pcall(function()
									inputFunction:Invoke("AttackButton", Enum.UserInputState.Begin)
								end)
								if ok then
									lastAttackAt = now
									attackMoveState.LastAttackTarget = target
									attackMoveState.LastAttackSentAt = now
								else
									warn("Auto Attack failed:", err)
								end
							end
							if configurations.AutoSkillEnabled and distance <= attackRange and now - lastSkillAt >= configurations.AutoSkillInterval then
								local ok, err = pcall(function()
									inputFunction:Invoke("SkillButton", Enum.UserInputState.Begin)
								end)
								if ok then
									lastSkillAt = now
								else
									warn("Auto Skill failed:", err)
								end
							end
						end
					end
				end
				if not configurations.Farming or configurations.AlertCombatPending
					or target == configurations.ExpRetaliationTarget or target == configurations.ExpMaxCombatTarget
					or target == configurations.ExpFinishTarget
					or target == configurations.ServerHopKillTarget then
					configurations.UpdateCombatStatus(target, targetRoot, distance, attackMoveState.NavigationMode, attackMoveState)
				end
			else
				if attackMoveState.Target and not configurations.Combat.IsLivingMob(attackMoveState.Target) then
					configurations.Combat.StowWeaponAfterMobDeath(attackMoveState.Target)
				end
				if chasingMob or attackMoveState.Active then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					configurations.CombatSystem.ResetNavigationState(attackMoveState)
					chasingMob = false
				end
				attackMoveState.Target = nil
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				ReleaseMovement("Combat", humanoid, localRoot)
				if configurations.AlertCombatHold then
					if configurations.AlertCombatBlockReady then
						StateLabel.Text = "Block"
						MiniState.Text = "Waiting to open Block prompt"
					elseif configurations.AlertBlockPromptShown then
						StateLabel.Text = "Block prompt"
						MiniState.Text = "Block prompt opened; waiting for the Alert player to leave"
					else
						StateLabel.Text = "Alert hold"
						MiniState.Text = "Waiting for the Alert player to leave"
					end
				elseif not configurations.Farming then
					if configurations.AlertResumeRequired then
						StateLabel.Text = "Stopped"
						MiniState.Text = "Alert cleared — press Start to resume EXP"
					elseif configurations.AutoAttackEnabled or configurations.AutoSkillEnabled or autoMarkedTarget then
						StateLabel.Text = "Searching..."
						MiniState.Text = "Searching for a valid combat target"
					elseif not configurations.EmergencyStopActive then
						StateLabel.Text = "Stopped"
						MiniState.Text = "Stopped"
					end
				end
				configurations.UpdateCombatStatus(nil, nil, nil, "searching", attackMoveState)
			end
		else
			if chasingMob or attackMoveState.Active then
				local character = Player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local localRoot = character and character:FindFirstChild("HumanoidRootPart")
				if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
				attackMoveState.Active = false
				attackMoveState.Goal = nil
				configurations.CombatSystem.ResetNavigationState(attackMoveState)
				chasingMob = false
			end
			attackMoveState.Target = nil
			local character = Player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			ReleaseMovement("Combat", humanoid, localRoot)
			configurations.UpdateCombatStatus(nil, nil, nil, "paused", attackMoveState)
		end
		local combatBusy = not configurations.EmergencyStopActive and not configurations.AlertCombatHold and (
			combatTargetPresent or configurations.AlertCombatPending or configurations.ExpMaxCombatTarget ~= nil
				or configurations.ExpRetaliationTarget ~= nil or configurations.ExpFinishTarget ~= nil
				or configurations.PendingServerHop
		)
		local combatWait = configurations.FPSBoostEnabled and not combatBusy and 0.3 or 0.08
		task.wait(combatWait)
	end
end)

-- Return to the pinned position when no higher-priority combat/EXP movement owns the character.
task.spawn(function()
	while true do
		local character = Player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local point = configurations.WaypointPosition
		configurations.RefreshPartyWaypointState()
		local paused = configurations.EmergencyStopActive
			or configurations.FollowEnabled
			or configurations.PartyWaypointSuspended
			or configurations.AlertCombatPending
			or configurations.AlertCombatHold
			or configurations.ExpMaxCombatTarget ~= nil
			or configurations.ExpRetaliationTarget ~= nil
			or configurations.ExpFinishTarget ~= nil
			or configurations.PendingServerHop
		if not paused and root and (configurations.AutoAttackEnabled or configurations.AutoBossTargetEnabled
			or configurations.AutoMiniBossTargetEnabled) and not configurations.Farming then
			local selectedMob = configurations.Combat.GetSelectedCombatMob(root)
			paused = selectedMob ~= nil
		end
		if configurations.Farming and configurations.ExpAutoApproachEnabled then
			paused = true
		end

		-- Combat has exclusive ownership of Humanoid movement while attacking.
		-- Never let waypoint-return navigation issue MoveTo calls over combat pursuit.
		if MovementOwner == "Combat" then
			configurations.WaypointNavigator.Reset()
		elseif configurations.WaypointReturnEnabled and point and root
			and (root.Position - point).Magnitude > 1500 then
			if humanoid then ReleaseMovement("Waypoint", humanoid, root) end
			configurations.WaypointNavigator.Reset()
		else
			if configurations.WaypointReturnEnabled and point and root and humanoid and not paused then
				if configurations.WaypointNavigator.IsHoldingPosition(root, point) then
					ReleaseMovement("Waypoint", humanoid, root)
				else
					ClaimMovement("Waypoint", humanoid, root)
					if configurations.WaypointNavigator.Update(humanoid, root, point) then
						ReleaseMovement("Waypoint", humanoid, root)
					end
				end
			else
				if humanoid and root then ReleaseMovement("Waypoint", humanoid, root) end
				configurations.WaypointNavigator.Reset()
			end
		end
		local waypointBusy = MovementOwner == "Combat"
			or (configurations.WaypointReturnEnabled and point and root and humanoid and not paused
				and (root.Position - point).Magnitude <= 1500
				and not configurations.WaypointNavigator.IsHoldingPosition(root, point))
		local waypointWait = configurations.FPSBoostEnabled and not waypointBusy and 0.35 or 0.12
		task.wait(waypointWait)
	end
end)

--==================================================
-- LIVE UI + TIMER + RATE
--==================================================
task.spawn(function()
	while true do
		configurations.WatchCreditLogTarget(configurations.CurrentTarget)
		configurations.UpdateCreditLog()
		configurations.WatchExpTargetForHit(configurations.ExpMaxCombatTarget or configurations.ExpFinishTarget
			or configurations.AlertCombatTarget
			or configurations.ExpRetaliationTarget or configurations.CurrentTarget
			or configurations.ExpLastShotTarget)
		configurations.UpdateExpHitFeedback()
		if configurations.Farming and configurations.CurrentTarget and configurations.CurrentTarget:IsDescendantOf(MobsFolder) then
			local cfg = configurations.CurrentTarget:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			local reachedMax = exp and exp.Value >= configurations.ExpGoal

			if configurations.CurrentTarget ~= configurations.LastTarget then
				configurations.LastTarget = configurations.CurrentTarget
				configurations.TargetStartTime = os.clock()
				configurations.AccumulatedTime = 0
				configurations.IsPaused = false
				if exp then
					configurations.SessionStartEXP = exp.Value
					configurations.SessionStartTime = os.clock()
				end
			end

			if not reachedMax then
				if configurations.IsPaused then
					configurations.TargetStartTime = os.clock()
					configurations.IsPaused = false
				end
				TimeLabel.Text = configurations.FormatTime(configurations.AccumulatedTime + (os.clock() - configurations.TargetStartTime))
				MiniTime.Text = TimeLabel.Text
			else
				configurations.PauseTimer()
				TimeLabel.Text = configurations.FormatTime(configurations.AccumulatedTime)
				MiniTime.Text = TimeLabel.Text
			end

			-- EXP / Hour
			if exp and configurations.SessionStartTime > 0 then
				local elapsed = os.clock() - configurations.SessionStartTime
				if elapsed > 1 then
					local gained = exp.Value - configurations.SessionStartEXP
					local perHour = (gained / elapsed) * 3600
					RateLabel.Text = configurations.FormatNumber(perHour) .. "/h"
				end
			end
		else
			if configurations.LastTarget then
				TimeLabel.Text = configurations.FormatTime(configurations.AccumulatedTime)
				MiniTime.Text = TimeLabel.Text
			end
		end

		if configurations.CurrentTarget and configurations.CurrentTarget:IsDescendantOf(MobsFolder) then
			local cfg = configurations.CurrentTarget:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			if exp then
				local ratio = math.clamp(exp.Value / configurations.ExpGoal, 0, 1)
				if math.floor(ratio * 1000) ~= math.floor((Bar.Size.X.Scale or 0) * 1000) then
					Bar.Size = UDim2.fromScale(ratio, 1)
				end
				if math.floor(ratio * 1000) ~= math.floor((MiniBarFill.Size.X.Scale or 0) * 1000) then
					MiniBarFill.Size = UDim2.fromScale(ratio, 1)
					MiniBarFill.BackgroundColor3 = ratio >= 1 and UIColors.GREEN or (ratio >= 0.6 and UIColors.ACCENT or UIColors.GREEN)
				end
				local expText = configurations.FormatNumber(exp.Value)
				if ExpLabel.Text ~= expText then ExpLabel.Text = expText end
				if MiniExp.Text ~= expText then MiniExp.Text = expText end
				local maxText = "/ " .. configurations.FormatNumber(configurations.ExpGoal)
				if MaxLabel.Text ~= maxText then MaxLabel.Text = maxText end
				if MiniMax.Text ~= maxText then MiniMax.Text = maxText end
				local percentText = string.format("%.1f%%", ratio * 100)
				if PercentLabel.Text ~= percentText then PercentLabel.Text = percentText end
				configurations.UpdateBillboardText(exp.Value, exp.Value >= configurations.ExpGoal)
			end

			local char = Player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local mroot = configurations.CurrentTarget.PrimaryPart or configurations.CurrentTarget:FindFirstChild("HumanoidRootPart")
			if root and mroot then
				local distText = "Dist  " .. string.format("%.1f", (root.Position - mroot.Position).Magnitude)
				if DistLabel.Text ~= distText then DistLabel.Text = distText end
			end
		else
			if configurations.CurrentTarget and not configurations.CurrentTarget:IsDescendantOf(MobsFolder) then
				configurations.ClearBillboard()
				configurations.CurrentTarget = nil
			end
		end

		-- Player level + Exp current/max from PlayerStats.Level / PlayerStats.EXP
		do
			local level, pExp, pMax = configurations.GetLocalLevelProgress()
			local levelText = (type(level) == "number") and ("Lv " .. tostring(math.floor(level + 0))) or "Lv —"
			local expLine
			if type(pExp) == "number" and type(pMax) == "number" then
				expLine = string.format("Exp %s/%s", configurations.FormatNumber(pExp), configurations.FormatNumber(pMax))
			elseif type(pExp) == "number" then
				expLine = "Exp " .. configurations.FormatNumber(pExp)
			else
				expLine = "Exp —/—"
			end
			if LevelLabel and LevelLabel.Text ~= levelText then LevelLabel.Text = levelText end
			if MiniLevel and MiniLevel.Text ~= levelText then MiniLevel.Text = levelText end
			if LevelExpText and LevelExpText.Text ~= expLine then LevelExpText.Text = expLine end
			if MiniLevelExpLabel and MiniLevelExpLabel.Text ~= expLine then MiniLevelExpLabel.Text = expLine end
		end

		-- Faster while farming/combat feedback matters; slower when idle to cut CPU.
		local uiBusy = configurations.Farming or configurations.AutoAttackEnabled or configurations.AlertCombatPending
		local uiWait = uiBusy and 0.12 or 0.28
		if configurations.FPSBoostEnabled then uiWait = uiBusy and 0.2 or 0.45 end
		task.wait(uiWait)
	end
end)

--==================================================
-- PLAYER LIST + FULL-SCREEN ALERTS
--==================================================
function configurations.DestroyPlayerESPVisual(visual)
	if not visual then return end
	if visual.Highlight then visual.Highlight:Destroy() end
	if visual.NameTag then visual.NameTag:Destroy() end
	if visual.Tracer then visual.Tracer:Destroy() end
end

function configurations.UpdatePlayerESPVisual(otherPlayer, otherCharacter, otherRoot, localRoot, camera, viewport, playerVisuals)
	local visual = playerVisuals[otherPlayer]
	local enabled = configurations.ESPEnabled and configurations.IsPlayerESPEnabled(otherPlayer)
	if not enabled or not otherCharacter or not otherRoot then
		if visual then
			configurations.DestroyPlayerESPVisual(visual)
			playerVisuals[otherPlayer] = nil
		end
		return
	end
	if not visual then
		local highlight = Instance.new("Highlight")
		highlight.Name = "PlayerESPOutline"
		highlight.FillTransparency = 1
		highlight.OutlineColor = UIColors.RED
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = workspace

		local nameTag = Instance.new("Frame")
		nameTag.Name = "PlayerESPName"
		nameTag.Size = UDim2.fromOffset(210, 86)
		nameTag.AnchorPoint = Vector2.new(0.5, 1)
		nameTag.BackgroundTransparency = 1
		nameTag.BorderSizePixel = 0
		nameTag.Visible = false
		nameTag.ZIndex = 80
		nameTag.Parent = configurations.PlayerEspLayer

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, 0, 0, 26)
		nameLabel.ZIndex = 81
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.TextStrokeTransparency = 0.2
		nameLabel.TextSize = 13
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextWrapped = true
		nameLabel.Parent = nameTag

		local distanceLabel = Instance.new("TextLabel")
		distanceLabel.Name = "Distance"
		distanceLabel.Size = UDim2.new(1, 0, 0, 20)
		distanceLabel.Position = UDim2.fromOffset(0, 27)
		distanceLabel.ZIndex = 81
		distanceLabel.BackgroundTransparency = 1
		distanceLabel.TextColor3 = Color3.fromRGB(225, 230, 240)
		distanceLabel.TextStrokeTransparency = 0.25
		distanceLabel.TextSize = 12
		distanceLabel.Font = Enum.Font.Gotham
		distanceLabel.Parent = nameTag

		local healthLabel = Instance.new("TextLabel")
		healthLabel.Name = "Health"
		healthLabel.Size = UDim2.new(1, 0, 0, 18)
		healthLabel.Position = UDim2.fromOffset(0, 48)
		healthLabel.ZIndex = 81
		healthLabel.BackgroundTransparency = 1
		healthLabel.TextColor3 = Color3.fromRGB(225, 230, 240)
		healthLabel.TextStrokeTransparency = 0.25
		healthLabel.TextSize = 12
		healthLabel.Font = Enum.Font.Gotham
		healthLabel.Parent = nameTag

		local statsLabel = Instance.new("TextLabel")
		statsLabel.Name = "Stats"
		statsLabel.Size = UDim2.new(1, 0, 0, 18)
		statsLabel.Position = UDim2.fromOffset(0, 66)
		statsLabel.ZIndex = 81
		statsLabel.BackgroundTransparency = 1
		statsLabel.TextColor3 = Color3.fromRGB(225, 230, 240)
		statsLabel.TextStrokeTransparency = 0.25
		statsLabel.TextSize = 12
		statsLabel.Font = Enum.Font.Gotham
		statsLabel.Parent = nameTag

		local tracer = Instance.new("Frame")
		tracer.Name = "PlayerESPLine"
		tracer.AnchorPoint = Vector2.new(0.5, 0.5)
		tracer.Size = UDim2.fromScale(0, 0)
		tracer.BackgroundColor3 = UIColors.RED
		tracer.BorderSizePixel = 0
		tracer.Visible = false
		tracer.ZIndex = 0
		tracer.Parent = configurations.PlayerEspLayer
		visual = { Highlight = highlight, NameTag = nameTag, NameLabel = nameLabel, DistanceLabel = distanceLabel, HealthLabel = healthLabel, StatsLabel = statsLabel, Tracer = tracer }
		playerVisuals[otherPlayer] = visual
	end

	visual.Highlight.Adornee = otherCharacter
	visual.Highlight.Enabled = configurations.ESPBoxEnabled
	visual.NameLabel.Text = otherPlayer.DisplayName .. "  (@" .. otherPlayer.Name .. ")"
	if localRoot then
		visual.DistanceLabel.Text = string.format("%.0f studs", (localRoot.Position - otherRoot.Position).Magnitude)
	else
		visual.DistanceLabel.Text = "Distance unavailable"
	end
	local currentHP, maximumHP = configurations.GetPlayerHealth(otherPlayer)
	visual.HealthLabel.Text = currentHP and string.format("HP %d / %d", currentHP, maximumHP) or "HP unavailable"
	visual.HealthLabel.TextColor3 = configurations.GetHealthColor(currentHP, maximumHP)
	visual.StatsLabel.Text = configurations.FormatPlayerStats(otherPlayer)
	visual.NameTag.Visible = false
	visual.Tracer.Visible = false
	if camera and viewport then
		local point, onScreen = camera:WorldToViewportPoint(otherRoot.Position)
		if point.Z > 0 and onScreen then
			visual.NameTag.Position = UDim2.fromScale(point.X / viewport.X, (point.Y - 8) / viewport.Y)
			visual.NameTag.Visible = true
			if configurations.ESPLineEnabled then
				local startPoint = Vector2.new(viewport.X * 0.5, viewport.Y - 8)
				local endPoint = Vector2.new(point.X, point.Y)
				local delta = endPoint - startPoint
				local midpoint = (startPoint + endPoint) * 0.5
				visual.Tracer.Position = UDim2.fromScale(midpoint.X / viewport.X, midpoint.Y / viewport.Y)
				visual.Tracer.Size = UDim2.fromScale(delta.Magnitude / viewport.X, 2 / viewport.Y)
				visual.Tracer.Rotation = math.deg(math.atan2(delta.Y, delta.X))
				visual.Tracer.Visible = true
			end
		end
	end
end

task.spawn(function()
	local lastPlayerRefresh = 0
	local lastAutoBlockCheck = 0
	local nextAutoBlockPromptAt = 0
	local autoBlockTeleporting = false
	local deferredAutoBlockMob = nil
	local flashOn = false
	local lastFlashToggle = 0
	local PlayerVisuals = {}
	local ThumbnailCache = {}
	local PlayerPanelBuildSignature = nil

	while true do
		local char = Player.Character
		local localRoot = char and char:FindFirstChild("HumanoidRootPart")
		local playerSnapshots = nil
		if localRoot and not configurations.EmergencyStopActive
			and (configurations.AlertsEnabled or configurations.FollowEnabled) then
			playerSnapshots = {}
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= Player then
					local otherCharacter = otherPlayer.Character
					local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						table.insert(playerSnapshots, { Player = otherPlayer, Root = otherRoot })
					end
				end
			end
		end
		local nearbyPlayer = nil
		local nearbyDistance = math.huge
		if configurations.AlertsEnabled and not configurations.EmergencyStopActive and localRoot then
			for _, snapshot in ipairs(playerSnapshots or {}) do
				local otherPlayer = snapshot.Player
				if otherPlayer ~= Player and not configurations.IsWhitelisted(otherPlayer) then
					local otherRoot = snapshot.Root
					if otherRoot.Parent then
						local distance = (localRoot.Position - otherRoot.Position).Magnitude
						if distance <= configurations.AlertsDistance and distance < nearbyDistance then
							nearbyPlayer = otherPlayer
							nearbyDistance = distance
						end
					end
				end
			end
		end

		local trackedAlertId = tonumber(configurations.LastAlertCombatUserId)
		local trackedAlertPlayer = trackedAlertId and Players:GetPlayerByUserId(trackedAlertId)
		local trackedCharacter = trackedAlertPlayer and trackedAlertPlayer.Character
		local trackedRoot = trackedCharacter and trackedCharacter:FindFirstChild("HumanoidRootPart")
		local trackedPlayerInRange = configurations.AlertsEnabled and localRoot and trackedRoot
			and (localRoot.Position - trackedRoot.Position).Magnitude <= configurations.AlertsDistance
		if not trackedPlayerInRange and not configurations.AlertCombatPending then
			local shouldResume = configurations.AlertWasFarming and configurations.AlertCombatHold and configurations.AutoResumeAfterAlert
				and not configurations.EmergencyStopActive
			local mustResumeManually = configurations.AlertWasFarming and configurations.AlertCombatHold and not configurations.AutoResumeAfterAlert
				and not configurations.EmergencyStopActive
			configurations.LastAlertCombatUserId = nil
			configurations.AlertCombatHold = false
			configurations.AlertCombatBlockReady = false
			configurations.AlertBlockTarget = nil
			configurations.AlertBlockPromptShown = false
			configurations.AlertResumeRequired = mustResumeManually
			configurations.AlertWasFarming = false
			if shouldResume then configurations.SetRunning() end
		end

		if nearbyPlayer then
			local alertUserId = tostring(nearbyPlayer.UserId)
			if not configurations.AlertCombatPending and not configurations.AlertCombatBlockReady
				and configurations.LastAlertCombatUserId ~= alertUserId then
				configurations.LastAlertCombatUserId = alertUserId
				configurations.AlertResumeRequired = false
				configurations.AlertWasFarming = configurations.Farming
				configurations.AlertBlockPromptShown = false
				configurations.AutoBlockPostTarget = nil
				configurations.AutoBlockPostUserId = nil
				configurations.AlertCombatPending = true
				configurations.AlertBlockTarget = nearbyPlayer
				local mob = (configurations.AutoExecuteEnabled
					or (configurations.AutoBlockEnabled and configurations.FinishExpAfterBlockEnabled))
					and configurations.Combat.GetExpExecutionTarget() or nil
				if not configurations.Combat.IsLivingMob(mob) then mob = nil end
				configurations.AlertCombatTarget = mob
				if mob and configurations.AutoBlockEnabled and configurations.FinishExpAfterBlockEnabled then
					-- When enabled, present Block first and preserve this EXP target for the post-Block finish.
					configurations.AutoBlockPostTarget = mob
					configurations.AutoBlockPostUserId = nearbyPlayer.UserId
					configurations.AlertCombatPending = false
					configurations.AlertCombatTarget = nil
					configurations.AlertCombatHold = true
					configurations.AlertCombatBlockReady = true
					StateLabel.Text = "Block"
					MiniState.Text = "Confirm Block first; then finishing the locked EXP target before hop"
				elseif mob then
					StateLabel.Text = "Alert"
					MiniState.Text = "Attacking locked EXP target before Block"
				else
					-- Never substitute a nearby mob when there is no active EXP target.
					configurations.AlertCombatPending = false
					configurations.AlertCombatHold = true
					configurations.AlertCombatBlockReady = configurations.AutoBlockEnabled
					StateLabel.Text = configurations.AutoBlockEnabled and "Block" or "Alert hold"
					if not configurations.AutoExecuteEnabled then
						MiniState.Text = "Auto Execute is off; waiting for player to leave"
					else
						MiniState.Text = configurations.AutoBlockEnabled
							and "No live EXP target; opening Block prompt"
							or "No live EXP target; waiting for player to leave"
					end
					if not configurations.AutoBlockEnabled then
						configurations.AlertBlockTarget = nil
					end
				end
				if configurations.Farming then configurations.SetIdle(false) end
				if configurations.AlertCombatPending then
					StateLabel.Text = "Alert"
					MiniState.Text = "Attacking locked EXP target before Block"
				elseif configurations.AlertCombatBlockReady then
					StateLabel.Text = "Block"
					MiniState.Text = configurations.AutoBlockPostTarget
						and "Confirm Block; then finishing the locked EXP target"
						or "No EXP target; opening Block prompt"
				elseif configurations.AlertCombatHold then
					StateLabel.Text = "Alert hold"
					MiniState.Text = "No EXP target; waiting for player to leave"
				end
			end
		else
			if not configurations.AlertCombatPending and not configurations.AlertCombatBlockReady then
				configurations.AlertCombatHold = false
				configurations.LastAlertCombatUserId = nil
			end
		end

		if configurations.AlertCombatPending then
			local alertMob = configurations.AlertCombatTarget
			if alertMob then
				if not configurations.Combat.IsLivingMob(alertMob) then
					configurations.AlertCombatPending = false
					configurations.AlertCombatTarget = nil
					configurations.AlertCombatHold = true
					configurations.AlertCombatBlockReady = configurations.AutoBlockEnabled
					StateLabel.Text = configurations.AutoBlockEnabled and "Block" or "Alert hold"
					MiniState.Text = configurations.AutoBlockEnabled and "EXP target defeated; opening Block prompt" or "EXP target defeated; waiting for player to leave"
				end
			end
		end

		local followedPlayer = configurations.FollowEnabled and configurations.SelectedFollowUserId
			and Players:GetPlayerByUserId(tonumber(configurations.SelectedFollowUserId))
		-- Pause Follow while Auto Attack is pursuing a valid target; resume when the target clears.
		local interruptFollow = configurations.AlertCombatPending == true
		if not interruptFollow and (configurations.AutoAttackEnabled or configurations.AutoBossTargetEnabled
			or configurations.AutoMiniBossTargetEnabled or configurations.ExpFinishTarget ~= nil)
			and not configurations.Farming and localRoot then
			local selectedMob = configurations.Combat.GetSelectedCombatMob(localRoot)
			if selectedMob then
				interruptFollow = true
			end
		end
		local followHumanoid = char and char:FindFirstChildOfClass("Humanoid")
		if configurations.FollowEnabled and not configurations.EmergencyStopActive and not configurations.Farming
			and followedPlayer and char and not interruptFollow then
			configurations.FollowSystem.Update(localRoot, followHumanoid, followedPlayer, playerSnapshots)
		else
			configurations.FollowSystem.Reset(followHumanoid, localRoot)
		end

		if configurations.AutoBlockEnabled and not configurations.EmergencyStopActive and not configurations.AlertCombatPending
			and os.clock() - lastAutoBlockCheck >= 1 then
			lastAutoBlockCheck = os.clock()
			local blockedUsers = configurations.GetBlockedUserSet()
			if configurations.AutoBlockPostUserId and not trackedPlayerInRange
				and not (blockedUsers and blockedUsers[tostring(configurations.AutoBlockPostUserId)]) then
				configurations.AutoBlockPostTarget = nil
				configurations.AutoBlockPostUserId = nil
			end
			local hasNonWhitelistedPlayer = false
			local blockedNonWhitelistedPlayer = false
			local nextPlayerToPrompt = nil
			if not configurations.Farming then
				deferredAutoBlockMob = nil
			elseif not deferredAutoBlockMob then
				local activeExpMob = configurations.CurrentTarget
				if not configurations.Combat.IsLivingMob(activeExpMob) then
					activeExpMob = configurations.ExpMaxCombatTarget
				end
				if configurations.Combat.IsLivingMob(activeExpMob) then
					deferredAutoBlockMob = activeExpMob
				end
			end
			local deferPromptForExp = not configurations.FinishExpAfterBlockEnabled
				and deferredAutoBlockMob ~= nil
				and configurations.Combat.IsLivingMob(deferredAutoBlockMob)
			if deferredAutoBlockMob and not configurations.Combat.IsLivingMob(deferredAutoBlockMob) then
				deferredAutoBlockMob = nil
			end

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= Player and not configurations.IsWhitelisted(otherPlayer) then
					hasNonWhitelistedPlayer = true
					if blockedUsers and blockedUsers[tostring(otherPlayer.UserId)] then
						blockedNonWhitelistedPlayer = true
						break
					elseif not nextPlayerToPrompt then
						nextPlayerToPrompt = otherPlayer
					end
				end
			end

			local alertTarget = configurations.AlertCombatBlockReady and configurations.AlertBlockTarget
			if alertTarget and alertTarget.Parent == Players
				and not configurations.IsWhitelisted(alertTarget)
				and not (blockedUsers and blockedUsers[tostring(alertTarget.UserId)]) then
				nextPlayerToPrompt = alertTarget
			end

			if not hasNonWhitelistedPlayer then
				-- A server containing only whitelisted players never triggers block or teleport.
				nextAutoBlockPromptAt = 0
				configurations.AlertCombatBlockReady = false
				configurations.AlertBlockTarget = nil
				configurations.AlertBlockPromptShown = false
				configurations.AutoBlockPostTarget = nil
				configurations.AutoBlockPostUserId = nil
			elseif blockedNonWhitelistedPlayer and not autoBlockTeleporting then
				configurations.AlertCombatBlockReady = false
				configurations.AlertBlockTarget = nil
				configurations.AlertBlockPromptShown = false
				-- Prefer finishing the active EXP mob before hopping.
				local killMob = deferredAutoBlockMob
				if not configurations.Combat.IsLivingMob(killMob) then
					killMob = configurations.CurrentTarget
				end
				if not configurations.Combat.IsLivingMob(killMob) then
					killMob = configurations.ExpMaxCombatTarget
				end
				if configurations.FinishExpAfterBlockEnabled
					and configurations.AutoBlockPostTarget
					and configurations.AutoBlockPostUserId
					and blockedUsers
					and blockedUsers[tostring(configurations.AutoBlockPostUserId)]
					and configurations.Combat.IsLivingMob(configurations.AutoBlockPostTarget) then
					killMob = configurations.AutoBlockPostTarget
				end
				if configurations.Combat.IsLivingMob(killMob) then
					configurations.PendingServerHop = true
					configurations.ServerHopKillTarget = killMob
					configurations.ExpMaxCombatTarget = killMob
					configurations.AlertCombatPending = false
					configurations.AlertCombatHold = false
					configurations.AlertCombatBlockReady = false
					configurations.AutoBlockPostTarget = nil
					configurations.AutoBlockPostUserId = nil
					-- Stop EXP firing; focus on killing, then hop.
					if configurations.Farming then
						configurations.Farming = false
						configurations.PauseTimer()
						StartBtn.Text = "Start"
						StartBtn.BackgroundColor3 = UIColors.ACCENT
						Status.Text = "OFF"
						Status.TextColor3 = UIColors.RED
						Status.BackgroundColor3 = UIColors.RED_DIM
					end
					StateLabel.Text = "Finish EXP"
					MiniState.Text = "Blocked player in server — killing EXP mob before hop"
				else
					configurations.PendingServerHop = false
					configurations.ServerHopKillTarget = nil
					configurations.AutoBlockPostTarget = nil
					configurations.AutoBlockPostUserId = nil
					StateLabel.Text = "Server hop"
					MiniState.Text = "A non-Whitelisted player is already blocked"
					autoBlockTeleporting = true
					task.spawn(function()
						local ok, err = pcall(function()
							TeleportService:Teleport(game.PlaceId, Player)
						end)
						if not ok then
							autoBlockTeleporting = false
							warn("Auto Block teleport failed:", err)
						else
							task.delay(15, function() autoBlockTeleporting = false end)
						end
					end)
				end
			elseif nextPlayerToPrompt and deferPromptForExp then
				StateLabel.Text = "Waiting"
				MiniState.Text = "Waiting for current EXP mob to die before Block prompt"
			elseif nextPlayerToPrompt and os.clock() >= nextAutoBlockPromptAt then
				nextAutoBlockPromptAt = os.clock() + 4
				local ok, err = pcall(function()
					StarterGui:SetCore("PromptBlockPlayer", nextPlayerToPrompt)
				end)
				if ok and configurations.AlertCombatBlockReady and nextPlayerToPrompt == alertTarget then
					configurations.AlertCombatBlockReady = false
					configurations.AlertBlockTarget = nil
					configurations.AlertBlockPromptShown = true
					StateLabel.Text = "Block prompt"
					MiniState.Text = "Block prompt opened; waiting for the Alert player to leave"
				elseif not ok then
					warn("Auto Block prompt failed:", err)
				end
			end
		elseif not configurations.AutoBlockEnabled then
			nextAutoBlockPromptAt = 0
			configurations.PendingServerHop = false
			configurations.ServerHopKillTarget = nil
		end

		-- Complete deferred hop once the locked EXP mob is dead (or gone).
		if configurations.PendingServerHop and not autoBlockTeleporting and not configurations.EmergencyStopActive then
			local hopMob = configurations.ServerHopKillTarget
			local stillAlive = configurations.Combat.IsLivingMob(hopMob)
			if stillAlive then
				StateLabel.Text = "Finish EXP"
				MiniState.Text = "Killing EXP mob before server hop"
			else
				configurations.PendingServerHop = false
				configurations.ServerHopKillTarget = nil
				configurations.ExpMaxCombatTarget = nil
				StateLabel.Text = "Server hop"
				MiniState.Text = "EXP mob down — hopping away from blocked player"
				autoBlockTeleporting = true
				task.spawn(function()
					local ok, err = pcall(function()
						TeleportService:Teleport(game.PlaceId, Player)
					end)
					if not ok then
						autoBlockTeleporting = false
						warn("Auto Block teleport failed:", err)
					else
						task.delay(15, function() autoBlockTeleporting = false end)
					end
				end)
			end
		end

		if PlayerPanel.Visible and os.clock() - lastPlayerRefresh >= 0.5 then
			lastPlayerRefresh = os.clock()
			local panelPlayers = configurations.FilterPlayerPanelListing(Players:GetPlayers())
			if configurations.PlayerPanelMode == "server" or configurations.PlayerPanelMode == "card" then
				table.sort(panelPlayers, function(a, b)
					if a == Player then return b ~= Player end
					if b == Player then return false end
					local aPinned = configurations.PinnedPlayerIds[tostring(a.UserId)] == true
					local bPinned = configurations.PinnedPlayerIds[tostring(b.UserId)] == true
					if aPinned ~= bPinned then return aPinned end
					return string.lower(a.Name) < string.lower(b.Name)
				end)
			end
			local signatureParts = { configurations.PlayerPanelMode }
			for _, listedPlayer in ipairs(panelPlayers) do
				table.insert(signatureParts, table.concat({
					tostring(listedPlayer.UserId),
					configurations.IsWhitelisted(listedPlayer) and "w" or "-",
					configurations.IsPlayerESPEnabled(listedPlayer) and "e" or "-",
					configurations.SelectedFollowUserId == tostring(listedPlayer.UserId) and "f" or "-",
					configurations.PinnedPlayerIds[tostring(listedPlayer.UserId)] and "p" or "-",
				}, ":"))
			end
			local panelSignature = table.concat(signatureParts, "|")
			local rebuildPlayerRows = panelSignature ~= PlayerPanelBuildSignature
			if rebuildPlayerRows then
				PlayerPanelBuildSignature = panelSignature
				for _, child in ipairs(PlayerScroll:GetChildren()) do
					if child.Name:match("^PlayerRow_") then
						child:Destroy()
					end
				end
			end

			if rebuildPlayerRows then
				for order, otherPlayer in ipairs(panelPlayers) do
					if configurations.PlayerPanelMode == "follow" then
						if otherPlayer == Player then continue end
						local selectedPlayer = otherPlayer
						local row = Instance.new("TextButton")
						row.Name = "PlayerRow_" .. selectedPlayer.UserId
						row.Size = UDim2.new(1, -4, 0, 44)
						row.LayoutOrder = order
						row.ZIndex = 92
						local isFollowSelected = configurations.SelectedFollowUserId == tostring(selectedPlayer.UserId)
						row.BackgroundColor3 = isFollowSelected and UIColors.SEL_BG or UIColors.CARD
						row.BorderSizePixel = 0
						row.Text = "  @" .. selectedPlayer.Name
						row.TextColor3 = isFollowSelected and UIColors.SEL_TEXT or UIColors.TEXT
						row.TextSize = 13
						row.Font = Enum.Font.GothamBold
						row.TextXAlignment = Enum.TextXAlignment.Left
						row.TextTruncate = Enum.TextTruncate.AtEnd
						row.Parent = PlayerScroll
						Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
						row.MouseButton1Click:Connect(function()
							configurations.SelectedFollowUserId = tostring(selectedPlayer.UserId)
							configurations.SaveConfig()
							configurations.UpdateFollowButtons()
							PlayerPanel.Visible = false
							configurations.PlayerPanelMode = "server"
							configurations.PlayerPanelTargetUserId = nil
							PlayerPanelTitle.Text = "Players in server"
							lastPlayerRefresh = 0
						end)
						continue
					end

					local otherCharacter = otherPlayer.Character
					local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
					local distanceText = otherPlayer == Player and "You" or "Distance unavailable"
					if localRoot and otherRoot then
						local distance = (localRoot.Position - otherRoot.Position).Magnitude
						if otherPlayer ~= Player then
							distanceText = string.format("%.0f studs away", distance)
						end
					end

					local row = Instance.new("Frame")
					row.Name = "PlayerRow_" .. otherPlayer.UserId
					row.Size = UDim2.new(1, -6, 0, 168)
					row.LayoutOrder = order
					row.ZIndex = 92
					row.BackgroundColor3 = UIColors.CARD
					row.BorderSizePixel = 0
					row.Parent = PlayerScroll
					Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
					local rowStroke = Instance.new("UIStroke", row)
					rowStroke.Color = UIColors.BORDER
					rowStroke.Thickness = 1
					rowStroke.Transparency = 0.5

					local avatar = Instance.new("ImageLabel")
					avatar.Name = "Avatar"
					avatar.Size = UDim2.fromOffset(48, 48)
					avatar.Position = UDim2.fromOffset(14, 14)
					avatar.ZIndex = 93
					avatar.BackgroundColor3 = UIColors.INPUT
					avatar.BorderSizePixel = 0
					avatar.ScaleType = Enum.ScaleType.Crop
					avatar.Parent = row
					Instance.new("UICorner", avatar).CornerRadius = UDim.new(1, 0)

					if not ThumbnailCache[otherPlayer.UserId] then
						local ok, imageUrl = pcall(function()
							return Players:GetUserThumbnailAsync(otherPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size60x60)
						end)
						if ok then ThumbnailCache[otherPlayer.UserId] = imageUrl end
					end
					avatar.Image = ThumbnailCache[otherPlayer.UserId] or ""

					local textRightPad = (otherPlayer == Player) and 20 or 156

					local displayName = Instance.new("TextLabel")
					displayName.Name = "DisplayName"
					displayName.Size = UDim2.new(1, -(74 + textRightPad), 0, 20)
					displayName.Position = UDim2.fromOffset(74, 12)
					displayName.ZIndex = 93
					displayName.BackgroundTransparency = 1
					displayName.Text = configurations.FormatPlayerDisplayName(otherPlayer)
					displayName.TextColor3 = UIColors.TEXT
					displayName.TextSize = 15
					displayName.Font = Enum.Font.GothamBold
					displayName.TextXAlignment = Enum.TextXAlignment.Left
					displayName.TextTruncate = Enum.TextTruncate.AtEnd
					displayName.Parent = row

					local usernameLabel = Instance.new("TextLabel")
					usernameLabel.Name = "Username"
					usernameLabel.Size = UDim2.new(1, -(74 + textRightPad), 0, 16)
					usernameLabel.Position = UDim2.fromOffset(74, 32)
					usernameLabel.ZIndex = 93
					usernameLabel.BackgroundTransparency = 1
					usernameLabel.Text = "@" .. otherPlayer.Name
					usernameLabel.TextColor3 = UIColors.MUTED
					usernameLabel.TextSize = 12
					usernameLabel.Font = Enum.Font.Gotham
					usernameLabel.TextXAlignment = Enum.TextXAlignment.Left
					usernameLabel.TextTruncate = Enum.TextTruncate.AtEnd
					usernameLabel.Parent = row

					local detail = Instance.new("TextLabel")
					detail.Name = "Distance"
					detail.Size = UDim2.new(1, -(74 + textRightPad), 0, 16)
					detail.Position = UDim2.fromOffset(74, 50)
					detail.ZIndex = 93
					detail.BackgroundTransparency = 1
					detail.Text = distanceText
					detail.TextColor3 = UIColors.MUTED
					detail.TextSize = 12
					detail.Font = Enum.Font.GothamMedium
					detail.TextXAlignment = Enum.TextXAlignment.Left
					detail.TextTruncate = Enum.TextTruncate.AtEnd
					detail.Parent = row

					local currentHP, maximumHP = configurations.GetPlayerHealth(otherPlayer)
					local healthLabel = Instance.new("TextLabel")
					healthLabel.Name = "Health"
					healthLabel.Size = UDim2.new(1, -28, 0, 18)
					healthLabel.Position = UDim2.fromOffset(14, 76)
					healthLabel.ZIndex = 93
					healthLabel.BackgroundTransparency = 1
					healthLabel.Text = currentHP and string.format("HP  %s / %s", configurations.FormatNumber(currentHP), configurations.FormatNumber(maximumHP)) or "HP  —"
					if configurations.IsWhitelisted(otherPlayer) then
						healthLabel.Text ..= "   ·   WHITELIST"
					end
					healthLabel.TextColor3 = configurations.GetHealthColor(currentHP, maximumHP)
					healthLabel.TextSize = 13
					healthLabel.Font = Enum.Font.GothamMedium
					healthLabel.TextXAlignment = Enum.TextXAlignment.Left
					healthLabel.TextTruncate = Enum.TextTruncate.AtEnd
					healthLabel.Parent = row

					local statsLabel = Instance.new("TextLabel")
					statsLabel.Name = "PlayerStats"
					statsLabel.Size = UDim2.new(1, -28, 0, 18)
					statsLabel.Position = UDim2.fromOffset(14, 96)
					statsLabel.ZIndex = 93
					statsLabel.BackgroundTransparency = 1
					statsLabel.Text = configurations.FormatPlayerListStats(otherPlayer)
					statsLabel.TextColor3 = Color3.fromRGB(160, 170, 190)
					statsLabel.TextSize = 12
					statsLabel.Font = Enum.Font.Gotham
					statsLabel.TextXAlignment = Enum.TextXAlignment.Left
					statsLabel.TextTruncate = Enum.TextTruncate.AtEnd
					statsLabel.Parent = row

					local expLevel, expCurrent, expMax, expRatio = configurations.GetPlayerExpProgress(otherPlayer)
					local expLabel = Instance.new("TextLabel")
					expLabel.Name = "PlayerExp"
					expLabel.Size = UDim2.new(1, -28, 0, 16)
					expLabel.Position = UDim2.fromOffset(14, 120)
					expLabel.ZIndex = 93
					expLabel.BackgroundTransparency = 1
					expLabel.Text = expCurrent and expMax and string.format("EXP  %s / %s", configurations.FormatNumber(expCurrent), configurations.FormatNumber(expMax)) or "EXP  —"
					expLabel.TextColor3 = UIColors.ACCENT_SEL
					expLabel.TextSize = 12
					expLabel.Font = Enum.Font.GothamMedium
					expLabel.TextXAlignment = Enum.TextXAlignment.Left
					expLabel.Parent = row

					local expBarBg = Instance.new("Frame")
					expBarBg.Name = "PlayerExpBar"
					expBarBg.Size = UDim2.new(1, -28, 0, 8)
					expBarBg.Position = UDim2.fromOffset(14, 142)
					expBarBg.ZIndex = 93
					expBarBg.BackgroundColor3 = UIColors.INPUT
					expBarBg.BorderSizePixel = 0
					expBarBg.Parent = row
					Instance.new("UICorner", expBarBg).CornerRadius = UDim.new(1, 0)

					local expBarFill = Instance.new("Frame")
					expBarFill.Name = "Fill"
					expBarFill.Size = UDim2.new(expRatio, 0, 1, 0)
					expBarFill.BackgroundColor3 = UIColors.ACCENT
					expBarFill.BorderSizePixel = 0
					expBarFill.Parent = expBarBg
					Instance.new("UICorner", expBarFill).CornerRadius = UDim.new(1, 0)

					if otherPlayer ~= Player then
						local function makeActionBtn(name, label, x, y, bg, fg)
							local b = Instance.new("TextButton")
							b.Name = name
							b.Size = UDim2.fromOffset(68, 26)
							b.Position = UDim2.new(1, x, 0, y)
							b.ZIndex = 93
							b.BackgroundColor3 = bg
							b.BorderSizePixel = 0
							b.Text = label
							b.TextColor3 = fg
							b.TextSize = 11
							b.Font = Enum.Font.GothamBold
							b.Parent = row
							Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
							return b
						end

						local pinOn = configurations.PinnedPlayerIds[tostring(otherPlayer.UserId)] == true
						local pinBtn = makeActionBtn("PlayerPinToggle", pinOn and "PINNED" or "PIN", -148, 12,
							pinOn and Color3.fromRGB(55, 45, 22) or UIColors.INPUT,
							pinOn and UIColors.YELLOW or UIColors.MUTED)
						configurations.PlayerPanelPinButton = pinBtn
						pinBtn.MouseButton1Click:Connect(function()
							local userId = tostring(otherPlayer.UserId)
							local isPinned = configurations.PinnedPlayerIds[userId] == true
							if isPinned then
								configurations.PinnedPlayerIds[userId] = nil
							else
								configurations.PinnedPlayerIds[userId] = true
							end
							configurations.SaveConfig()
							local on = configurations.PinnedPlayerIds[userId] == true
							pinBtn.Text = on and "PINNED" or "PIN"
							pinBtn.TextColor3 = on and UIColors.YELLOW or UIColors.MUTED
							pinBtn.BackgroundColor3 = on and Color3.fromRGB(55, 45, 22) or UIColors.INPUT
							PlayerPanelBuildSignature = nil
						end)

						local espOn = configurations.IsPlayerESPEnabled(otherPlayer)
						local espBtn = makeActionBtn("PlayerESPToggle", espOn and "ESP ON" or "ESP OFF", -74, 12,
							espOn and UIColors.GREEN_DIM or UIColors.INPUT,
							espOn and UIColors.GREEN or UIColors.MUTED)
						espBtn.MouseButton1Click:Connect(function()
							local enabled = not configurations.IsPlayerESPEnabled(otherPlayer)
							configurations.PlayerESPEnabled[tostring(otherPlayer.UserId)] = enabled
							espBtn.Text = enabled and "ESP ON" or "ESP OFF"
							espBtn.TextColor3 = enabled and UIColors.GREEN or UIColors.MUTED
							espBtn.BackgroundColor3 = enabled and UIColors.GREEN_DIM or UIColors.INPUT
						end)

						local wlOn = configurations.IsWhitelisted(otherPlayer)
						local wlBtn = makeActionBtn("WhitelistToggle", wlOn and "WL ON" or "WL ADD", -148, 44,
							wlOn and Color3.fromRGB(55, 45, 22) or UIColors.INPUT,
							wlOn and UIColors.YELLOW or UIColors.MUTED)
						wlBtn.MouseButton1Click:Connect(function()
							local userId = tostring(otherPlayer.UserId)
							if configurations.IsWhitelisted(otherPlayer) then
								configurations.WhitelistIds[userId] = nil
							else
								configurations.WhitelistIds[userId] = true
							end
							configurations.SaveConfig()
							local enabled = configurations.IsWhitelisted(otherPlayer)
							wlBtn.Text = enabled and "WL ON" or "WL ADD"
							wlBtn.TextColor3 = enabled and UIColors.YELLOW or UIColors.MUTED
							wlBtn.BackgroundColor3 = enabled and Color3.fromRGB(55, 45, 22) or UIColors.INPUT
							if configurations.WhitelistPanel.Visible then configurations.RefreshWhitelist() end
							configurations.OnWhitelistChanged(userId)
						end)

						local blockButton = makeActionBtn("BlockButton", "Block", -74, 44, UIColors.RED_DIM, UIColors.RED)
						blockButton.MouseButton1Click:Connect(function()
							if configurations.BlockPromptCache[otherPlayer.UserId] then return end
							configurations.BlockPromptCache[otherPlayer.UserId] = true
							blockButton.Text = "..."
							local ok, err = pcall(function()
								StarterGui:SetCore("PromptBlockPlayer", otherPlayer)
							end)
							if not ok then
								configurations.BlockPromptCache[otherPlayer.UserId] = nil
								blockButton.Text = "Retry"
								warn("PromptBlockPlayer failed:", err)
								return
							end
							blockButton.Text = "Prompted"
							task.delay(3, function()
								configurations.BlockPromptCache[otherPlayer.UserId] = nil
								if blockButton.Parent then blockButton.Text = "Block" end
							end)
						end)
					end
				end
			end

			if rebuildPlayerRows then
				configurations.ApplyTextScale(PlayerPanel)
			end

			-- Refresh changing player data in-place; keep cards and their callbacks alive.
			if configurations.PlayerPanelMode == "server" or configurations.PlayerPanelMode == "card" then
				for _, listedPlayer in ipairs(panelPlayers) do
					local row = PlayerScroll:FindFirstChild("PlayerRow_" .. listedPlayer.UserId)
					if row and row:IsA("Frame") then
						local displayNameLabel = row:FindFirstChild("DisplayName")
						if displayNameLabel then
							if displayNameLabel.Text ~= configurations.FormatPlayerDisplayName(listedPlayer) then
								displayNameLabel.Text = configurations.FormatPlayerDisplayName(listedPlayer)
							end
						end
						local character = listedPlayer.Character
						local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
						local distanceLabel = row:FindFirstChild("Distance")
						if distanceLabel then
							local distanceText = listedPlayer == Player and "You" or "Distance unavailable"
							if listedPlayer ~= Player and localRoot and otherRoot then
								distanceText = string.format("%.0f studs away", (localRoot.Position - otherRoot.Position).Magnitude)
							end
							if distanceLabel.Text ~= distanceText then distanceLabel.Text = distanceText end
						end
						local healthLabel = row:FindFirstChild("Health")
						if healthLabel then
							local currentHP, maximumHP = configurations.GetPlayerHealth(listedPlayer)
							local healthText = currentHP and string.format("HP  %s / %s", configurations.FormatNumber(currentHP), configurations.FormatNumber(maximumHP)) or "HP  —"
							if configurations.IsWhitelisted(listedPlayer) then healthText ..= "   ·   WHITELIST" end
							if healthLabel.Text ~= healthText then healthLabel.Text = healthText end
							local healthColor = configurations.GetHealthColor(currentHP, maximumHP)
							if healthLabel.TextColor3 ~= healthColor then healthLabel.TextColor3 = healthColor end
						end
						local statsLabel = row:FindFirstChild("PlayerStats")
						if statsLabel then
							local statsText = configurations.FormatPlayerListStats(listedPlayer)
							if statsLabel.Text ~= statsText then statsLabel.Text = statsText end
						end
						local expLabel = row:FindFirstChild("PlayerExp")
						local expBar = row:FindFirstChild("PlayerExpBar")
						if expLabel and expBar then
							local _, expCurrent, expMax, expRatio = configurations.GetPlayerExpProgress(listedPlayer)
							local expText = expCurrent and expMax and string.format("EXP  %s / %s", configurations.FormatNumber(expCurrent), configurations.FormatNumber(expMax)) or "EXP  —"
							if expLabel.Text ~= expText then expLabel.Text = expText end
							local fill = expBar:FindFirstChild("Fill")
							if fill then fill.Size = UDim2.new(expRatio, 0, 1, 0) end
						end
					end
				end
			end
		end

		-- Keep markers for every replicated player, regardless of distance.
		local presentPlayers = {}
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= Player then
				presentPlayers[otherPlayer] = true
				local otherCharacter = otherPlayer.Character
				local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
				configurations.UpdatePlayerESPVisual(otherPlayer, otherCharacter, otherRoot, localRoot, camera, viewport, PlayerVisuals)
				if localRoot and otherRoot and not configurations.IsWhitelisted(otherPlayer)
					and (localRoot.Position - otherRoot.Position).Magnitude <= configurations.AlertsDistance
					and (localRoot.Position - otherRoot.Position).Magnitude < nearbyDistance then
					nearbyDistance = (localRoot.Position - otherRoot.Position).Magnitude
					nearbyPlayer = otherPlayer
				end
			end
		end

		for otherPlayer, visual in pairs(PlayerVisuals) do
			if not presentPlayers[otherPlayer] then
				visual.Highlight:Destroy()
				visual.NameTag:Destroy()
				visual.Tracer:Destroy()
				PlayerVisuals[otherPlayer] = nil
			end
		end

		if configurations.AlertsEnabled and not configurations.EmergencyStopActive and configurations.AlertFlashEnabled and nearbyPlayer then
			AlarmOverlay.BackgroundColor3 = UIColors.RED
			configurations.AlarmText.Text = string.format("PLAYER NEARBY  •  %s  •  %.0f studs", nearbyPlayer.Name, nearbyDistance)
			AlarmOverlay.Visible = true
		else
			AlarmOverlay.Visible = false
		end

		if AlarmOverlay.Visible then
			if os.clock() - lastFlashToggle >= 0.25 then
				lastFlashToggle = os.clock()
				flashOn = not flashOn
				AlarmOverlay.BackgroundTransparency = flashOn and 0.32 or 0.72
			end
		else
			flashOn = false
		end

		-- Alert / ESP / follow loop: stay responsive near threats, slower when quiet.
		local followBusy = configurations.FollowEnabled
		local alertBusy = configurations.AlertsEnabled or configurations.AlertCombatPending
			or configurations.AlertCombatHold or AlarmOverlay.Visible
		local alertWait = alertBusy and 0.08 or 0.18
		if configurations.FPSBoostEnabled then
			if followBusy then
				alertWait = 0.08
			elseif alertBusy then
				alertWait = 0.12
			else
				alertWait = 0.4
			end
		end
		task.wait(alertWait)
	end
end)

configurations.ApplyGuiScale()
configurations.ApplyTextScale()

if not configurations.IsStudio and type(getgenv) == "function" then
	getgenv().IamrichLoaded = true
end
print("[Iamrich] Version " .. VERSION .. " loaded successfully.")
