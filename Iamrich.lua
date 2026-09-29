print("[Iamrich] Starting...")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
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
MobCache.SearchCaches = {
	Boss = { LastSearchAt = 0, Range = nil, Mob = nil },
	Mob = { LastSearchAt = 0, Range = nil, Mob = nil },
}

function MobCache.InvalidateSearchCaches()
	for _, cache in pairs(MobCache.SearchCaches) do
		cache.LastSearchAt = 0
		cache.Range = nil
		cache.Mob = nil
	end
end

local CollectionService = game:GetService("CollectionService")
local function ReadIsBossFlag(source)
	if not source or typeof(source) ~= "Instance" then return nil end
	local attribute = source:GetAttribute("IsBoss")
	if type(attribute) == "boolean" then return attribute end
	if type(attribute) == "number" and (attribute == 0 or attribute == 1) then return attribute == 1 end
	if type(attribute) == "string" then
		local normalized = string.lower(attribute)
		if normalized == "true" or normalized == "1" then return true end
		if normalized == "false" or normalized == "0" then return false end
	end
	local value = source:FindFirstChild("IsBoss", true)
	if value and value:IsA("ValueBase") then
		local raw = value.Value
		if type(raw) == "boolean" then return raw end
		if type(raw) == "number" then return raw ~= 0 end
		if type(raw) == "string" then
			local normalized = string.lower(raw)
			if normalized == "true" or normalized == "1" then return true end
			if normalized == "false" or normalized == "0" then return false end
		end
	end
	return nil
end

local function IsBossMob(mob, config)
	local entity = config and config:FindFirstChild("Entity")
	local entityValue = entity and entity.Value
	for _, source in ipairs({ mob, config, typeof(entityValue) == "Instance" and entityValue or nil }) do
		local flag = ReadIsBossFlag(source)
		if flag ~= nil then return flag end
	end
	if mob then
		local ok, tagged = pcall(function()
			return CollectionService:HasTag(mob, "Boss") or CollectionService:HasTag(mob, "IsBoss")
		end)
		if ok and tagged then return true end
	end
	return false
end

local function MobCache_ClearEntry(mob)
	MobCache.InvalidateSearchCaches()
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
		IsBoss = IsBossMob(mob, cfg),
	}
end

local function MobCache_Upsert(mob)
	if not mob or not mob:IsDescendantOf(MobsFolder) then
		MobCache_ClearEntry(mob)
		return
	end
	MobCache.InvalidateSearchCaches()
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
		existing.IsBoss = fresh.IsBoss
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

local function SmoothMoveTo(humanoid, root, goal, state, minInterval, stopRadius, checkVertical)
	if not humanoid or not root or not goal then return false end
	local now = os.clock()
	local flat = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
	local dist = checkVertical and (root.Position - goal).Magnitude or flat.Magnitude
	if dist <= (stopRadius or 1.6) then
		if state.Active then
			humanoid:MoveTo(root.Position)
			state.Active = false
			state.Goal = nil
		end
		return true
	end
	local sameGoal = state.Goal and (state.Goal - goal).Magnitude < 1.25
	local interval = minInterval or 0.22
	if state.Active and sameGoal and (now - (state.LastMoveAt or 0)) < interval then
		return false
	end
	-- Ground-aligned combat goals may intentionally be on a lower floor.
	local point = checkVertical and goal or Vector3.new(goal.X, root.Position.Y, goal.Z)
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

local virtualInputObject = nil
local virtualInputManager = nil
local warnedInteractInputUnavailable = false
local function TapInteractX()
	-- Prefer executor keyboard helpers when present, then Roblox's virtual input APIs.
	if typeof(keypress) == "function" and typeof(keyrelease) == "function" then
		local ok = pcall(function()
			keypress(0x58)
			task.wait(0.05)
			keyrelease(0x58)
		end)
		if ok then return true end
	end

	if not virtualInputObject then
		pcall(function() virtualInputObject = UserInputService:CreateVirtualInput() end)
	end
	if virtualInputObject then
		local ok = pcall(function()
			virtualInputObject:SendKey(true, Enum.KeyCode.X, false)
			task.wait(0.05)
			virtualInputObject:SendKey(false, Enum.KeyCode.X, false)
		end)
		if ok then return true end
	end

	if not virtualInputManager then
		pcall(function() virtualInputManager = game:GetService("VirtualInputManager") end)
	end
	if virtualInputManager then
		local ok = pcall(function()
			virtualInputManager:SendKeyEvent(true, Enum.KeyCode.X, false, game)
			task.wait(0.05)
			virtualInputManager:SendKeyEvent(false, Enum.KeyCode.X, false, game)
		end)
		if ok then return true end
	end

	if not warnedInteractInputUnavailable then
		warnedInteractInputUnavailable = true
		warn("[Iamrich] Could not send the Interact X key in this client environment.")
	end
	return false
end

--==================================================
-- CONFIG
--==================================================
local configuration: {[string]: any} = {
	Amount = 5000,
	MaxDistance = 250,
	ExpApproachDistance = 30,
	ExpAutoApproachEnabled = false,
	Interval = 1,
	ExpGoal = 2000000,
	AlertsDistance = 1000,
	FollowDistance = 8,
	FollowPlayerUserId = nil,
	PlayerPanelMode = "server",
	AutoAttackTargetUserId = nil,
	AutoAttackPinnedMob = nil,
	SelectedCombatMob = nil,
	WaypointPosition = nil,
	WaypointReturnEnabled = false,
	WaypointReturnRadius = 8,
	WaypointMoveState = { Active = false, Goal = nil, LastMoveAt = 0 },
	MovementBoostEnabled = true,
	AutoAttackEnabled = false,
	AutoAttackBossPriority = false,
	AutoAttackBossesOnly = false,
	AutoAttackUseExpTarget = false,
	ExpTargetRetaliationEnabled = false,
	ExpRetaliationTarget = nil,
	AutoSkillEnabled = false,
	AutoAttackMode = "Mob",
	AutoAttackRange = 25,
	AutoAttackSearchRange = 1000,
	AutoAttackInterval = 1,
	AutoSkillInterval = 3,
	AutoAttackStandoff = 4,
	CombatDiagnosticsEnabled = false,
	CombatTargetMob = nil,
	NearbyLockKind = nil,
	NearbyLockTarget = nil,
	Farming = false,
	CurrentTarget = nil,
	ExpMaxCombatTarget = nil,
	ExpFinishTarget = nil,
	LastTarget = nil,
	TargetStartTime = 0,
	AccumulatedTime = 0,
	IsPaused = false,
	CurrentBillboard = nil,
	SessionStartEXP = 0,
	SessionStartTime = 0,
	RecentCycle = "รอบล่าสุด  -",
	SessionExpGained = 0,
	SessionFarmSeconds = 0,
	NoProgressCycles = 0,
	AutoResumeAfterAlert = true,
	EmergencyStopActive = false,
	AlertsEnabled = true,
	AlertFlashEnabled = true,
	AutoBlockEnabled = true,
	AlertCombatPending = false,
	AlertCombatTarget = nil,
	AlertCombatHold = false,
	AlertCombatBlockReady = false,
	AlertBlockTarget = nil,
	LastAlertCombatUserId = nil,
	PendingServerHop = false,
	ServerHopKillTarget = nil,
	FaceTargetEnabled = true,
	ESPEnabled = true,
	ESPLineEnabled = true,
	ESPBoxEnabled = true,
	AntiAFKEnabled = true,
	WhitelistIds = {},
	PlayerESPEnabled = {},
	BlockPromptCache = {},
	SavedMinimized = false,
	MainWidthScale = 0.72,
	MainHeightScale = 0.84,
	PlayerPanelWidthScale = 0.42,
	PlayerPanelHeightScale = 0.62,
	WhitelistPanelWidthScale = 0.40,
	WhitelistPanelHeightScale = 0.58,
	ConfigFileName = "",
	ConfigSaveWarningShown = false,
	ConfigRootFolder = "Iamrich",
	ConfigUserFolder = "",
	LegacyConfigFileName = "EXPPlus_Config.json",
	LegacyConfigOwnerFileName = "Iamrich_LegacyConfigOwner.txt",
	MigratedLegacyConfig = false,
	IsMinimized = false,
	Combat = {},
}

-- Combat runs from a separate source chunk to keep the main UI/farming chunk
-- below Luau's 200-register limit. Publish CombatSystem.lua beside this file.
configuration.CombatSystem = assert(loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/NameNotFound69/Iambatman/refs/heads/main/CombatSystem.lua"
)))()
configuration.CombatSystem.Initialize(configuration, {
	MobsFolder = MobsFolder,
	PathfindingService = game:GetService("PathfindingService"),
	SmoothMoveTo = SmoothMoveTo,
})

function configuration.PrepareConfigStorage()
	local userId = tostring(Player.UserId)
	configuration.ConfigUserFolder = configuration.ConfigRootFolder .. "/" .. userId
	local nestedPath = configuration.ConfigUserFolder .. "/Config.json"
	local flatPath = configuration.ConfigRootFolder .. "_" .. userId .. ".json"

	if type(makefolder) == "function" then
		pcall(makefolder, configuration.ConfigRootFolder)
		pcall(makefolder, configuration.ConfigUserFolder)
		local folderReady = type(isfolder) ~= "function"
		if type(isfolder) == "function" then
			local ok, exists = pcall(isfolder, configuration.ConfigUserFolder)
			folderReady = ok and exists == true
		end
		if folderReady then
			configuration.ConfigFileName = nestedPath
			return
		end
	end

	-- Keep per-user isolation even on executors without folder APIs.
	configuration.ConfigFileName = flatPath
end


function configuration.LoadConfig()
	if type(readfile) ~= "function" then return end
	configuration.PrepareConfigStorage()
	local function ReadConfig(path)
		local ok, config = pcall(function()
			return HttpService:JSONDecode(readfile(path))
		end)
		return ok and type(config) == "table" and config or nil
	end

	local config = ReadConfig(configuration.ConfigFileName)
	if not config then
		-- Import the old shared config once, assigning it to the first UserId that runs this version.
		local owner = ""
		local ownerOk, ownerValue = pcall(function()
			return readfile(configuration.LegacyConfigOwnerFileName)
		end)
		if ownerOk then
			owner = tostring(ownerValue)
		end
		if owner == "" and type(writefile) == "function" then
			local legacyConfig = ReadConfig(configuration.LegacyConfigFileName)
			if legacyConfig then
				local markerWritten = pcall(function()
					writefile(configuration.LegacyConfigOwnerFileName, tostring(Player.UserId))
				end)
				if markerWritten then
					configuration.MigratedLegacyConfig = true
					config = legacyConfig
				end
			end
		end
	end
	if type(config) ~= "table" then return end

	local function ReadNumber(key, current, minimum, allowZero)
		local value = tonumber(config[key])
		if value and value >= minimum and (allowZero or value > 0) then
			return value
		end
		return current
	end

	configuration.Amount = math.floor(ReadNumber("Amount", configuration.Amount, 0, false))
	configuration.ExpApproachDistance = math.clamp(ReadNumber("ExpApproachDistance", configuration.ExpApproachDistance, 5, false), 5, 100)
	if type(config.ExpAutoApproachEnabled) == "boolean" then
		configuration.ExpAutoApproachEnabled = config.ExpAutoApproachEnabled
	end
	configuration.MaxDistance = math.clamp(ReadNumber("MaxDistance", configuration.MaxDistance, 5, false), 5, 100000)
	configuration.Interval = ReadNumber("Interval", configuration.Interval, 0, true)
	configuration.ExpGoal = ReadNumber("ExpGoal", configuration.ExpGoal, 0, false)
	configuration.AlertsDistance = math.clamp(ReadNumber("AlertsDistance", configuration.AlertsDistance, 0, true), 0, 100000)
	configuration.FollowDistance = math.clamp(ReadNumber("FollowDistance", configuration.FollowDistance, 2, false), 2, 100)
	configuration.AutoAttackRange = math.clamp(ReadNumber("AutoAttackRange", configuration.AutoAttackRange, 5, false), 5, 500)
	local savedMobSearchRange = ReadNumber("AutoAttackSearchRange", configuration.AutoAttackSearchRange, 5, false)
	-- Earlier builds defaulted mob visibility to 100 studs. The intended default
	-- is 1000, so migrate that legacy default instead of silently keeping targets
	-- such as the 955-stud mob outside the eligible-target search.
	if savedMobSearchRange == 100 then savedMobSearchRange = 1000 end
	configuration.AutoAttackSearchRange = math.clamp(savedMobSearchRange, 5, 1000)
	configuration.WaypointReturnRadius = math.clamp(ReadNumber("WaypointReturnRadius", configuration.WaypointReturnRadius, 2, false), 2, 100)
	local waypoint = config.WaypointPosition
	if type(waypoint) == "table" then
		local x, y, z = tonumber(waypoint.X), tonumber(waypoint.Y), tonumber(waypoint.Z)
		if x and y and z then configuration.WaypointPosition = Vector3.new(x, y, z) end
	end
	configuration.AutoAttackInterval = math.clamp(ReadNumber("AutoAttackInterval", configuration.AutoAttackInterval, 1, false), 1, 10)
	configuration.AutoSkillInterval = math.clamp(ReadNumber("AutoSkillInterval", configuration.AutoSkillInterval, 1, false), 1, 30)
	if config.AutoAttackMode == "Mob" or config.AutoAttackMode == "Player" or config.AutoAttackMode == "Nearby" then
		configuration.AutoAttackMode = config.AutoAttackMode
	end
	local attackUserId = tonumber(config.AutoAttackTargetUserId)
	if attackUserId and attackUserId > 0 and attackUserId % 1 == 0 then
		configuration.AutoAttackTargetUserId = tostring(attackUserId)
	end
	local followUserId = tonumber(config.FollowPlayerUserId)
	if followUserId and followUserId > 0 and followUserId % 1 == 0 then
		configuration.FollowPlayerUserId = tostring(followUserId)
	end
	configuration.MainWidthScale = math.clamp(ReadNumber("MainWidthScale", configuration.MainWidthScale, 0.2, false), 0.2, 0.75)
	configuration.MainHeightScale = math.clamp(ReadNumber("MainHeightScale", configuration.MainHeightScale, 0.4, false), 0.4, 0.95)
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1000, 800)
	local legacyWidth = tonumber(config.MainWidth)
	if config.MainWidthScale == nil and legacyWidth then
		configuration.MainWidthScale = math.clamp(legacyWidth / math.max(1, viewport.X), 0.2, 0.75)
	end
	local legacyHeight = tonumber(config.MainHeight)
	if config.MainHeightScale == nil and legacyHeight then
		configuration.MainHeightScale = math.clamp(legacyHeight / math.max(1, viewport.Y), 0.4, 0.95)
	end
	configuration.PlayerPanelWidthScale = math.clamp(ReadNumber("PlayerPanelWidthScale", configuration.PlayerPanelWidthScale, 0.28, false), 0.28, 0.8)
	configuration.PlayerPanelHeightScale = math.clamp(ReadNumber("PlayerPanelHeightScale", configuration.PlayerPanelHeightScale, 0.35, false), 0.35, 0.9)
	configuration.WhitelistPanelWidthScale = math.clamp(ReadNumber("WhitelistPanelWidthScale", configuration.WhitelistPanelWidthScale, 0.26, false), 0.26, 0.8)
	configuration.WhitelistPanelHeightScale = math.clamp(ReadNumber("WhitelistPanelHeightScale", configuration.WhitelistPanelHeightScale, 0.32, false), 0.32, 0.9)
	if type(config.AlertsEnabled) == "boolean" then configuration.AlertsEnabled = config.AlertsEnabled end
	if config.AutoResumeAfterAlertVersion == 1 and type(config.AutoResumeAfterAlert) == "boolean" then
		configuration.AutoResumeAfterAlert = config.AutoResumeAfterAlert
	elseif config.AutoResumeAfterAlertVersion ~= 1 then
		-- Older configs predate the resume setting; migrate them to the new default.
		configuration.AutoResumeAfterAlert = true
		configuration.MigratedLegacyConfig = true
	end
	if type(config.AlertFlashEnabled) == "boolean" then configuration.AlertFlashEnabled = config.AlertFlashEnabled end
	if type(config.AutoBlockEnabled) == "boolean" then configuration.AutoBlockEnabled = config.AutoBlockEnabled end
	if type(config.MovementBoostEnabled) == "boolean" then configuration.MovementBoostEnabled = config.MovementBoostEnabled end
	if type(config.AutoAttackEnabled) == "boolean" then configuration.AutoAttackEnabled = config.AutoAttackEnabled end
	if type(config.WaypointReturnEnabled) == "boolean" then configuration.WaypointReturnEnabled = config.WaypointReturnEnabled end
	if type(config.AutoAttackBossPriority) == "boolean" then configuration.AutoAttackBossPriority = config.AutoAttackBossPriority end
	if type(config.AutoAttackBossesOnly) == "boolean" then configuration.AutoAttackBossesOnly = config.AutoAttackBossesOnly end
	if type(config.AutoAttackUseExpTarget) == "boolean" then configuration.AutoAttackUseExpTarget = config.AutoAttackUseExpTarget end
	if type(config.ExpTargetRetaliationEnabled) == "boolean" then configuration.ExpTargetRetaliationEnabled = config.ExpTargetRetaliationEnabled end
	if type(config.AutoSkillEnabled) == "boolean" then configuration.AutoSkillEnabled = config.AutoSkillEnabled end
	if type(config.ESPEnabled) == "boolean" then configuration.ESPEnabled = config.ESPEnabled end
	if type(config.ESPLineEnabled) == "boolean" then configuration.ESPLineEnabled = config.ESPLineEnabled end
	if type(config.ESPBoxEnabled) == "boolean" then configuration.ESPBoxEnabled = config.ESPBoxEnabled end
	if type(config.AntiAFKEnabled) == "boolean" then configuration.AntiAFKEnabled = config.AntiAFKEnabled end
	configuration.SavedMinimized = config.Minimized == true
	if type(config.WhitelistIds) == "table" then
		for _, userId in ipairs(config.WhitelistIds) do
			local id = tostring(userId)
			if id:match("^%d+$") and tonumber(id) and tonumber(id) > 0 then
				configuration.WhitelistIds[id] = true
			end
		end
	end
end

function configuration.SaveConfig()
	if type(writefile) ~= "function" then
		if not configuration.ConfigSaveWarningShown then
			warn("[Iamrich] Config was not saved: this executor does not provide writefile.")
			configuration.ConfigSaveWarningShown = true
		end
		return false
	end
	configuration.PrepareConfigStorage()
	local ids = {}
	for userId in pairs(configuration.WhitelistIds) do
		table.insert(ids, userId)
	end
	table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)

	local config = {
		Amount = configuration.Amount,
		MaxDistance = configuration.MaxDistance,
		ExpApproachDistance = configuration.ExpApproachDistance,
		ExpAutoApproachEnabled = configuration.ExpAutoApproachEnabled,
		Interval = configuration.Interval,
		ExpGoal = configuration.ExpGoal,
		AlertsDistance = configuration.AlertsDistance,
		FollowDistance = configuration.FollowDistance,
		FollowPlayerUserId = configuration.FollowPlayerUserId,
		AutoAttackTargetUserId = configuration.AutoAttackTargetUserId,
		AutoAttackEnabled = configuration.AutoAttackEnabled,
		AutoAttackBossPriority = configuration.AutoAttackBossPriority,
		AutoAttackBossesOnly = configuration.AutoAttackBossesOnly,
		AutoAttackUseExpTarget = configuration.AutoAttackUseExpTarget,
		ExpTargetRetaliationEnabled = configuration.ExpTargetRetaliationEnabled,
		AutoAttackMode = configuration.AutoAttackMode,
		AutoAttackRange = configuration.AutoAttackRange,
		AutoAttackSearchRange = configuration.AutoAttackSearchRange,
		WaypointPosition = configuration.WaypointPosition and {
			X = configuration.WaypointPosition.X,
			Y = configuration.WaypointPosition.Y,
			Z = configuration.WaypointPosition.Z,
		} or nil,
		WaypointReturnEnabled = configuration.WaypointReturnEnabled,
		WaypointReturnRadius = configuration.WaypointReturnRadius,
		AutoAttackInterval = configuration.AutoAttackInterval,
		AutoSkillEnabled = configuration.AutoSkillEnabled,
		AutoSkillInterval = configuration.AutoSkillInterval,
		MainWidthScale = configuration.MainWidthScale,
		MainHeightScale = configuration.MainHeightScale,
		PlayerPanelWidthScale = configuration.PlayerPanelWidthScale,
		PlayerPanelHeightScale = configuration.PlayerPanelHeightScale,
		WhitelistPanelWidthScale = configuration.WhitelistPanelWidthScale,
		WhitelistPanelHeightScale = configuration.WhitelistPanelHeightScale,
		AlertsEnabled = configuration.AlertsEnabled,
		AutoResumeAfterAlert = configuration.AutoResumeAfterAlert,
		AutoResumeAfterAlertVersion = 1,
		AlertFlashEnabled = configuration.AlertFlashEnabled,
		AutoBlockEnabled = configuration.AutoBlockEnabled,
		MovementBoostEnabled = configuration.MovementBoostEnabled,
		ESPEnabled = configuration.ESPEnabled,
		ESPLineEnabled = configuration.ESPLineEnabled,
		ESPBoxEnabled = configuration.ESPBoxEnabled,
		AntiAFKEnabled = configuration.AntiAFKEnabled,
		WhitelistIds = ids,
		Minimized = configuration.IsMinimized == true,
	}
	local ok, err = pcall(function()
		writefile(configuration.ConfigFileName, HttpService:JSONEncode(config))
	end)
	if not ok then
		warn("[Iamrich] Config save failed:", err)
	end
	return ok
end

configuration.LoadConfig()
if configuration.MigratedLegacyConfig then
	configuration.SaveConfig()
end
if configuration.AutoAttackUseExpTarget then
	configuration.AutoAttackMode = "Mob"
end
if configuration.AutoAttackBossesOnly then
	configuration.AutoAttackMode = "Mob"
	configuration.AutoAttackUseExpTarget = false
end

function configuration.IsWhitelisted(otherPlayer)
	return configuration.WhitelistIds[tostring(otherPlayer.UserId)] == true
end

function configuration.GetBlockedUserSet()
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

function configuration.IsPlayerESPEnabled(otherPlayer)
	return configuration.PlayerESPEnabled[tostring(otherPlayer.UserId)] ~= false
end

function configuration.GetPlayerHealth(otherPlayer)
	local character = otherPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil, nil end
	return math.max(0, math.floor(humanoid.Health + 0.5)), math.max(0, math.floor(humanoid.MaxHealth + 0.5))
end

function configuration.GetPlayerStats(otherPlayer)
	local stats = otherPlayer:FindFirstChild("PlayerStats")
	local level = stats and stats:FindFirstChild("Level")
	local defense = stats and stats:FindFirstChild("Defense")
	local levelValue = level and level.Value
	local defenseValue = defense and defense.Value
	return levelValue, defenseValue
end

function configuration.FormatPlayerStats(otherPlayer)
	local level, defense = configuration.GetPlayerStats(otherPlayer)
	return string.format("Level %s  •  Defense %s", level ~= nil and tostring(level) or "—", defense ~= nil and tostring(defense) or "—")
end

-- Local player level + EXP progress from PlayerStats and/or the game's HUD ("EXP: 58354/59211").
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
		for _, name in ipairs({ "EXP", "Exp", "Experience", "EXPLabel", "ExpLabel", "LevelEXP", "LevelExp" }) do
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
function configuration.NeededExp(lvl)
	lvl = tonumber(lvl)
	if not lvl or lvl < 1 then return 9 end
	lvl = math.floor(lvl) - 1
	local total = 9
	for i = 1, lvl do
		total = total + (6 * (i + 2))
	end
	return total
end

function configuration.GetLocalLevelProgress()
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
			maxExp = configuration.NeededExp(level)
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
		maxExp = configuration.NeededExp(level)
	end

	local ratio = nil
	if exp and maxExp and maxExp > 0 then
		ratio = math.clamp(exp / maxExp, 0, 1)
	end
	return level, exp, maxExp, ratio
end


--==================================================
-- COLORS (Slayers2-inspired dark blue UI)
--==================================================
local BG         = Color3.fromRGB(16, 18, 26)      -- main window
local SIDEBAR_BG = Color3.fromRGB(12, 14, 22)      -- left sidebar
local CARD       = Color3.fromRGB(24, 28, 40)      -- content cards / rows
local INPUT      = Color3.fromRGB(32, 36, 50)      -- inputs
local BORDER     = Color3.fromRGB(42, 48, 64)
local TEXT       = Color3.fromRGB(236, 240, 248)
local MUTED      = Color3.fromRGB(130, 138, 158)
local ACCENT     = Color3.fromRGB(90, 160, 255)    -- switch / accent blue
local ACCENT_SEL = Color3.fromRGB(120, 180, 255)
local GREEN      = Color3.fromRGB(76, 218, 164)
local RED        = Color3.fromRGB(255, 92, 112)
local YELLOW     = Color3.fromRGB(255, 196, 92)
local ACCENT_DIM = Color3.fromRGB(32, 56, 96)
local GREEN_DIM  = Color3.fromRGB(24, 53, 45)
local RED_DIM    = Color3.fromRGB(56, 30, 37)
local SEL_BG     = Color3.fromRGB(48, 78, 130)     -- selected nav (soft blue fill)
local SEL_TEXT   = Color3.fromRGB(220, 235, 255)   -- light text on selected

function configuration.GetHealthColor(current, maximum)
	if not current or not maximum or maximum <= 0 then return MUTED end
	local ratio = current / maximum
	if ratio <= 0.25 then return RED end
	if ratio <= 0.6 then return YELLOW end
	return GREEN
end

--==================================================
-- HELPERS
--==================================================
function configuration.FormatNumber(n)
	n = tonumber(n)
	if not n then return "0" end
	local s = tostring(math.floor(n + 0))
	local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if result:sub(1, 1) == "," then
		result = result:sub(2)
	end
	return result
end

function configuration.FormatTime(sec)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = math.floor(sec % 60)
	return string.format("%02d:%02d:%02d", h, m, s)
end

--==================================================
-- BILLBOARD
--==================================================
function configuration.ClearBillboard()
	if configuration.CurrentBillboard then
		pcall(function() configuration.CurrentBillboard:Destroy() end)
		configuration.CurrentBillboard = nil
	end
	configuration.BillboardAdornee = nil
end

function configuration.BuildBillboardText(expValue, isMax)
	local cur = tonumber(expValue) or 0
	local goal = tonumber(configuration.ExpGoal) or 0
	local curText = configuration.FormatNumber(cur)
	local goalText = configuration.FormatNumber(goal)
	if isMax or (goal > 0 and cur >= goal) then
		return "MAX\n" .. curText .. " / " .. goalText, true
	end
	local pct = goal > 0 and math.clamp(cur / goal, 0, 1) * 100 or 0
	return string.format("FARMING\n%s / %s\n%.1f%%", curText, goalText, pct), false
end

-- Fixed on-screen pixel size (does not grow/shrink with camera distance).
local BILLBOARD_WIDTH = 150
local BILLBOARD_HEIGHT = 52

function configuration.AttachBillboard(mob, expValue)
	configuration.ClearBillboard()
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
	stroke.Color = ACCENT
	stroke.Thickness = 1.5

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -8, 1, -4)
	label.Position = UDim2.fromOffset(4, 2)
	label.BackgroundTransparency = 1
	label.TextColor3 = ACCENT
	label.TextSize = 12
	label.Font = Enum.Font.GothamBold
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextWrapped = true
	label.Parent = frame

	local text, isMax = configuration.BuildBillboardText(expValue, false)
	label.Text = text
	label.TextColor3 = isMax and GREEN or ACCENT
	if isMax then stroke.Color = GREEN end

	configuration.CurrentBillboard = bb
	configuration.BillboardAdornee = root
end

function configuration.UpdateBillboardText(expValue, isMax)
	local bb = configuration.CurrentBillboard
	if not bb or not bb.Parent then
		configuration.CurrentBillboard = nil
		configuration.BillboardAdornee = nil
		return
	end
	-- Keep adornee on the live root if the mob's PrimaryPart changed.
	local target = configuration.CurrentTarget
	if target and target.Parent then
		local root = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and bb.Adornee ~= root then
			bb.Adornee = root
			configuration.BillboardAdornee = root
		end
	end
	-- Re-assert fixed pixel size (prevents any accidental scale mutation).
	if bb.Size.X.Offset ~= BILLBOARD_WIDTH or bb.Size.Y.Offset ~= BILLBOARD_HEIGHT
		or bb.Size.X.Scale ~= 0 or bb.Size.Y.Scale ~= 0 then
		bb.Size = UDim2.fromOffset(BILLBOARD_WIDTH, BILLBOARD_HEIGHT)
	end
	local label = bb:FindFirstChild("Text", true)
	if not label then return end
	local text, maxed = configuration.BuildBillboardText(expValue, isMax)
	if label.Text ~= text then
		label.Text = text
	end
	label.TextColor3 = maxed and GREEN or ACCENT
	local stroke = bb:FindFirstChild("Stroke", true)
	if stroke then
		stroke.Color = maxed and GREEN or ACCENT
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
Main.Size = UDim2.fromScale(configuration.MainWidthScale, configuration.MainHeightScale)
Main.Position = UDim2.fromScale(0.5 - configuration.MainWidthScale / 2, 0.5 - configuration.MainHeightScale / 2)
Main.ZIndex = 90
Main.BackgroundColor3 = BG
Main.BorderSizePixel = 0
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 12)
local MainStroke = Instance.new("UIStroke", Main)
MainStroke.Color = BORDER
MainStroke.Thickness = 1
MainStroke.Transparency = 0.4

function configuration.ApplyResponsiveMainSize()
	if configuration.IsMinimized then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then return end
	local maxWidth = math.max(0.2, math.min(1400 / viewport.X, 1 - 16 / viewport.X))
	local minWidth = math.min(640 / viewport.X, maxWidth)
	local maxHeight = math.max(0.4, math.min(900 / viewport.Y, 1 - 16 / viewport.Y))
	local minHeight = math.min(480 / viewport.Y, maxHeight)
	local width = math.clamp(configuration.MainWidthScale, minWidth, maxWidth)
	local height = math.clamp(configuration.MainHeightScale, minHeight, maxHeight)
	Main.Size = UDim2.fromScale(width, height)
	if not configuration.MainWindowInitialized then
		Main.Position = UDim2.fromScale((1 - width) * 0.5, (1 - height) * 0.5)
		configuration.MainWindowInitialized = true
	else
		Main.Position = UDim2.fromScale(
			math.clamp(Main.Position.X.Scale, 0, 1 - width),
			math.clamp(Main.Position.Y.Scale, 0, 1 - height)
		)
	end
end

configuration.ApplyResponsiveMainSize()
configuration.BindResponsiveViewport = function()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(configuration.ApplyResponsiveMainSize)
	end
end
configuration.BindResponsiveViewport()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(configuration.BindResponsiveViewport)

--==================================================
-- HEADER (compact)
--==================================================
local Content
local ContentPanel
local Sidebar
local InfoCard, StartBtn, ToggleGrid, SettingsCard
local AlarmOverlay
local Header = Instance.new("Frame")
Header.Size = UDim2.fromScale(1, 0.09)
Header.Active = true
Header.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
Header.BorderSizePixel = 0
Header.Parent = Main
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 12)

local HeaderFix = Instance.new("Frame")
HeaderFix.Size = UDim2.fromScale(1, 0.45)
HeaderFix.Position = UDim2.fromScale(0, 0.55)
HeaderFix.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
HeaderFix.BorderSizePixel = 0
HeaderFix.Parent = Header

local HeaderRule = Instance.new("Frame")
HeaderRule.Size = UDim2.new(1, -20, 0, 1)
HeaderRule.Position = UDim2.new(0, 10, 1, -1)
HeaderRule.BackgroundColor3 = BORDER
HeaderRule.BackgroundTransparency = 0.4
HeaderRule.BorderSizePixel = 0
HeaderRule.Parent = Header

local WindowDots = {}
function configuration.MakeWindowDot(x, color)
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromScale(0.018, 0.28)
	dot.Position = UDim2.fromScale(x, 0.36)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Parent = Header
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
	table.insert(WindowDots, dot)
	return dot
end
configuration.MakeWindowDot(0.035, Color3.fromRGB(255, 95, 86))
configuration.MakeWindowDot(0.075, Color3.fromRGB(255, 190, 46))
configuration.MakeWindowDot(0.115, Color3.fromRGB(40, 201, 64))

local Title = Instance.new("TextLabel")
Title.Size = UDim2.fromScale(0.50, 0.42)
Title.Position = UDim2.fromScale(0.155, 0.28)
Title.BackgroundTransparency = 1
Title.Text = "EXP+"
Title.TextColor3 = TEXT
Title.TextSize = 16
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Subtitle = Instance.new("TextLabel")
Subtitle.Size = UDim2.fromScale(0.30, 0.30)
Subtitle.Position = UDim2.fromScale(0.42, 0.35)
Subtitle.BackgroundTransparency = 1
Subtitle.Text = "Primary"
Subtitle.TextColor3 = MUTED
Subtitle.TextSize = 12
Subtitle.Font = Enum.Font.Gotham
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.Parent = Header

-- Order (right edge): [ Status ON/OFF ] [ − / + ]  — same in full + mini
local Status = Instance.new("TextButton")
Status.Size = UDim2.fromOffset(48, 20)
Status.Position = UDim2.new(1, -84, 0, 10)
Status.BackgroundColor3 = RED_DIM
Status.BorderSizePixel = 0
Status.AutoButtonColor = false
Status.Text = "OFF"
Status.TextColor3 = RED
Status.TextSize = 10
Status.Font = Enum.Font.GothamBold
Status.Parent = Header
Instance.new("UICorner", Status).CornerRadius = UDim.new(1, 0)

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Size = UDim2.fromOffset(24, 24)
MinimizeBtn.Position = UDim2.new(1, -32, 0, 8)
MinimizeBtn.BackgroundColor3 = INPUT
MinimizeBtn.BorderSizePixel = 0
MinimizeBtn.Text = "−"
MinimizeBtn.TextColor3 = TEXT
MinimizeBtn.TextSize = 16
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Parent = Header
Instance.new("UICorner", MinimizeBtn).CornerRadius = UDim.new(0, 6)

--==================================================
-- MINI CARD (compact EXP box when minimized)
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
MiniTitle.TextColor3 = TEXT
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
MiniLevel.TextColor3 = ACCENT
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
MiniExp.TextColor3 = GREEN
MiniExp.TextSize = 24
MiniExp.Font = Enum.Font.GothamBlack
MiniExp.TextXAlignment = Enum.TextXAlignment.Left
MiniExp.Parent = MiniBar

local MiniMax = Instance.new("TextLabel")
MiniMax.Size = UDim2.new(0.55, 0, 0, 14)
MiniMax.Position = UDim2.fromOffset(10, 72)
MiniMax.BackgroundTransparency = 1
MiniMax.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
MiniMax.TextColor3 = MUTED
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
MiniTime.TextColor3 = YELLOW
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
MiniState.TextColor3 = MUTED
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
MiniLevelExpLabel.TextColor3 = MUTED
MiniLevelExpLabel.TextSize = 10
MiniLevelExpLabel.Font = Enum.Font.Gotham
MiniLevelExpLabel.TextXAlignment = Enum.TextXAlignment.Left
MiniLevelExpLabel.Parent = MiniBar

-- Farm target EXP progress bar only
local MiniBarBg = Instance.new("Frame")
MiniBarBg.Size = UDim2.new(1, -20, 0, 5)
MiniBarBg.Position = UDim2.fromOffset(10, 96)
MiniBarBg.BackgroundColor3 = INPUT
MiniBarBg.BorderSizePixel = 0
MiniBarBg.Parent = MiniBar
Instance.new("UICorner", MiniBarBg).CornerRadius = UDim.new(1, 0)

local MiniBarFill = Instance.new("Frame")
MiniBarFill.Name = "MiniBarFill"
MiniBarFill.Size = UDim2.fromScale(0, 1)
MiniBarFill.BackgroundColor3 = GREEN
MiniBarFill.BorderSizePixel = 0
MiniBarFill.Parent = MiniBarBg
Instance.new("UICorner", MiniBarFill).CornerRadius = UDim.new(1, 0)

function configuration.ApplyMinimized(state)
	configuration.IsMinimized = state
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
		SavedMainPosition = Main.Position
		-- Compact floating card
		Main.Size = UDim2.fromOffset(MINI_WIDTH, MINI_HEIGHT)
		Header.Size = UDim2.fromScale(1, 1)
		Header.BackgroundColor3 = BG
		-- Keep near previous top-left, clamp into viewport
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		local px = math.clamp(Main.Position.X.Scale * viewport.X + Main.Position.X.Offset, 8, math.max(8, viewport.X - MINI_WIDTH - 8))
		local py = math.clamp(Main.Position.Y.Scale * viewport.Y + Main.Position.Y.Offset, 8, math.max(8, viewport.Y - MINI_HEIGHT - 8))
		Main.Position = UDim2.fromOffset(px, py)
		-- Same order as full UI: Status left, expand (+) rightmost
		Status.Position = UDim2.new(1, -84, 0, 8)
		Status.Size = UDim2.fromOffset(48, 20)
		MinimizeBtn.Position = UDim2.new(1, -32, 0, 6)
		MinimizeBtn.Size = UDim2.fromOffset(24, 24)
	else
		Header.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
		Header.Size = UDim2.fromScale(1, 0.09)
		configuration.MainWindowInitialized = true
		configuration.ApplyResponsiveMainSize()
		if SavedMainPosition then
			Main.Position = SavedMainPosition
		else
			Main.Position = UDim2.fromScale(0.5 - Main.Size.X.Scale / 2, 0.5 - Main.Size.Y.Scale / 2)
		end
		Main.Position = UDim2.fromScale(
			math.clamp(Main.Position.X.Scale, 0, 1 - Main.Size.X.Scale),
			math.clamp(Main.Position.Y.Scale, 0, 1 - Main.Size.Y.Scale)
		)
		-- Same order: Status left, minimize (−) rightmost
		Status.Position = UDim2.new(1, -84, 0, 10)
		Status.Size = UDim2.fromOffset(48, 20)
		MinimizeBtn.Position = UDim2.new(1, -32, 0, 8)
		MinimizeBtn.Size = UDim2.fromOffset(24, 24)
	end
	local resizeHandle = Main:FindFirstChild("ResizeHandle")
	if resizeHandle then resizeHandle.Visible = not state end
end

configuration.IsMinimized = configuration.SavedMinimized
MinimizeBtn.MouseButton1Click:Connect(function()
	configuration.ApplyMinimized(not configuration.IsMinimized)
	configuration.SaveConfig()
end)

-- Drag
local Dragging, DragStart, StartPos = false, nil, nil
Header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		Dragging = true
		DragStart = input.Position
		StartPos = Main.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				Dragging = false
			end
		end)
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if Dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - DragStart
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		if not viewport then return end
		if configuration.IsMinimized then
			local startX = StartPos.X.Scale * viewport.X + StartPos.X.Offset
			local startY = StartPos.Y.Scale * viewport.Y + StartPos.Y.Offset
			local px = math.clamp(startX + d.X, 4, math.max(4, viewport.X - MINI_WIDTH - 4))
			local py = math.clamp(startY + d.Y, 4, math.max(4, viewport.Y - MINI_HEIGHT - 4))
			Main.Position = UDim2.fromOffset(px, py)
		else
			Main.Position = UDim2.fromScale(
				math.clamp(StartPos.X.Scale + d.X / viewport.X, 0, 1 - configuration.MainWidthScale),
				math.clamp(StartPos.Y.Scale + d.Y / viewport.Y, 0, 1 - configuration.MainHeightScale)
			)
		end
	end
end)

--==================================================
-- CONTENT
--==================================================
-- Right content panel (dark like the image)
ContentPanel = Instance.new("Frame")
ContentPanel.Name = "ContentPanel"
ContentPanel.Size = UDim2.fromScale(0.70, 0.88)
ContentPanel.Position = UDim2.fromScale(0.285, 0.10)
ContentPanel.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
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
ContentPad.PaddingTop = UDim.new(0, 8)
ContentPad.PaddingLeft = UDim.new(0, 12)
ContentPad.PaddingRight = UDim.new(0, 12)
ContentPad.PaddingBottom = UDim.new(0, 8)
ContentPad.Parent = Content

configuration.ApplyMinimized(configuration.IsMinimized)

local Pages = {}
local PageLayouts = {}
function configuration.CreatePage(name, visible)
	local page = Instance.new("ScrollingFrame")
	page.Name = name .. "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 3
	page.ScrollBarImageColor3 = MUTED
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.Visible = visible
	page.Parent = Content
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = page
	Pages[name] = page
	PageLayouts[name] = layout
	return page
end

local ExpPage = configuration.CreatePage("EXP", true)
local ESPPage = configuration.CreatePage("ESP", false)
local PlayerPage = configuration.CreatePage("Player", false)
local AlertsPage = configuration.CreatePage("Alerts", false)
local FarmPage = configuration.CreatePage("Farm", false)
local CombatPage = configuration.CreatePage("Combat", false)
local WaypointPage = configuration.CreatePage("Waypoint", false)

function configuration.AddPageHeading(page, title, description)
	local heading = Instance.new("Frame")
	heading.Size = UDim2.new(1, 0, 0, 52)
	heading.LayoutOrder = 1
	heading.BackgroundTransparency = 1
	heading.Parent = page
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -8, 0, 26)
	titleLabel.Position = UDim2.fromOffset(6, 2)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = TEXT
	titleLabel.TextSize = 18
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = heading
	local descriptionLabel = Instance.new("TextLabel")
	descriptionLabel.Size = UDim2.new(1, -8, 0, 18)
	descriptionLabel.Position = UDim2.fromOffset(6, 28)
	descriptionLabel.BackgroundTransparency = 1
	descriptionLabel.Text = description
	descriptionLabel.TextColor3 = MUTED
	descriptionLabel.TextSize = 12
	descriptionLabel.Font = Enum.Font.Gotham
	descriptionLabel.TextXAlignment = Enum.TextXAlignment.Left
	descriptionLabel.Parent = heading
	return heading
end

configuration.AddPageHeading(ExpPage, "Experience", "Track your level, EXP and active farm session")
configuration.AddPageHeading(ESPPage, "ESP", "Show other players on screen")
configuration.AddPageHeading(PlayerPage, "Players", "Follow, block, whitelist and server list")
configuration.AddPageHeading(AlertsPage, "Alerts", "Warn when other players come nearby")
configuration.AddPageHeading(FarmPage, "Farm settings", "EXP per cycle, range, interval and goal")
configuration.AddPageHeading(CombatPage, "Combat", "Auto attack, skills and target mode")
configuration.AddPageHeading(WaypointPage, "Waypoint", "Pin a position and return when displaced")

Sidebar = Instance.new("Frame")
Sidebar.Name = "Navigation"
Sidebar.Size = UDim2.fromScale(0.26, 0.88)
Sidebar.Position = UDim2.fromScale(0.015, 0.10)
Sidebar.BackgroundColor3 = SIDEBAR_BG
Sidebar.BorderSizePixel = 0
Sidebar.Visible = not configuration.IsMinimized
Sidebar.Parent = Main
Instance.new("UICorner", Sidebar).CornerRadius = UDim.new(0, 10)

-- Sidebar scroll for many items
local SidebarScroll = Instance.new("ScrollingFrame")
SidebarScroll.Name = "SidebarScroll"
SidebarScroll.Size = UDim2.fromScale(1, 1)
SidebarScroll.BackgroundTransparency = 1
SidebarScroll.BorderSizePixel = 0
SidebarScroll.ScrollBarThickness = 3
SidebarScroll.ScrollBarImageColor3 = MUTED
SidebarScroll.CanvasSize = UDim2.new()
SidebarScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SidebarScroll.ScrollingDirection = Enum.ScrollingDirection.Y
SidebarScroll.Parent = Sidebar

local SidebarLayout = Instance.new("UIListLayout")
SidebarLayout.Padding = UDim.new(0, 2)
SidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
SidebarLayout.Parent = SidebarScroll

local SidebarPad = Instance.new("UIPadding")
SidebarPad.PaddingTop = UDim.new(0, 10)
SidebarPad.PaddingLeft = UDim.new(0, 8)
SidebarPad.PaddingRight = UDim.new(0, 8)
SidebarPad.PaddingBottom = UDim.new(0, 12)
SidebarPad.Parent = SidebarScroll

function configuration.MakeNavSection(text, order)
	-- Section header (not clickable) — visually distinct from nav buttons
	local wrap = Instance.new("Frame")
	wrap.Name = "Section_" .. text
	wrap.Size = UDim2.new(1, 0, 0, 28)
	wrap.LayoutOrder = order
	wrap.BackgroundTransparency = 1
	wrap.Parent = SidebarScroll

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 0, 14)
	label.Position = UDim2.fromOffset(12, 12)
	label.BackgroundTransparency = 1
	label.Text = string.upper(text)
	label.TextColor3 = Color3.fromRGB(88, 98, 120)
	label.TextSize = 9
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTransparency = 0.15
	label.Parent = wrap

	-- subtle divider under header text
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -24, 0, 1)
	line.Position = UDim2.fromOffset(12, 26)
	line.BackgroundColor3 = BORDER
	line.BackgroundTransparency = 0.55
	line.BorderSizePixel = 0
	line.Parent = wrap
	return wrap
end

function configuration.MakeNavButton(text, icon, order)
	local button = Instance.new("TextButton")
	button.Name = "Nav_" .. text
	button.Size = UDim2.new(1, 0, 0, 36)
	button.LayoutOrder = order
	button.BackgroundColor3 = SEL_BG
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Parent = SidebarScroll
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 9)

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Label"
	textLabel.Size = UDim2.new(1, -24, 1, 0)
	textLabel.Position = UDim2.fromOffset(14, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextColor3 = MUTED
	textLabel.TextSize = 13
	textLabel.Font = Enum.Font.Gotham
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.Parent = button

	return button
end

configuration.MakeNavSection("Auto Farm", 1)
local NavButtons = {
	EXP    = configuration.MakeNavButton("Overview", nil, 2),
	Farm   = configuration.MakeNavButton("Farm settings", nil, 3),
	Combat = configuration.MakeNavButton("Combat", nil, 4),
	Waypoint = configuration.MakeNavButton("Waypoint", nil, 5),
}
configuration.MakeNavSection("Tools", 6)
NavButtons.Alerts = configuration.MakeNavButton("Alerts", nil, 7)
NavButtons.Player = configuration.MakeNavButton("Players", nil, 8)
configuration.MakeNavSection("Display", 9)
NavButtons.ESP = configuration.MakeNavButton("ESP", nil, 10)

function configuration.SetMainTab(tab)
	for name, page in pairs(Pages) do
		page.Visible = name == tab
		if page.Visible then page.CanvasPosition = Vector2.zero end
	end
	for name, button in pairs(NavButtons) do
		local selected = name == tab
		button.BackgroundTransparency = selected and 0 or 1
		button.BackgroundColor3 = SEL_BG
		local label = button:FindFirstChild("Label")
		if label then
			label.TextColor3 = selected and SEL_TEXT or MUTED
			label.Font = selected and Enum.Font.GothamBold or Enum.Font.Gotham
		end
	end
	if tab == "Combat" and configuration.RefreshCombatMobs then
		configuration.RefreshCombatMobs()
	end
end

for name, button in pairs(NavButtons) do
	button.MouseButton1Click:Connect(function() configuration.SetMainTab(name) end)
end
configuration.SetMainTab("EXP")

--==================================================
-- SERVER STATUS WIDGET
--==================================================
local ServerCard = Instance.new("Frame")
ServerCard.Name = "ServerCard"
ServerCard.Size = UDim2.new(1, 0, 0, 64)
ServerCard.LayoutOrder = 2
ServerCard.BackgroundColor3 = CARD
ServerCard.BorderSizePixel = 0
ServerCard.Parent = ExpPage
Instance.new("UICorner", ServerCard).CornerRadius = UDim.new(0, 12)
local ServerStroke = Instance.new("UIStroke", ServerCard)
ServerStroke.Color = BORDER
ServerStroke.Thickness = 1
ServerStroke.Transparency = 0.55

local ServerTitle = Instance.new("TextLabel")
ServerTitle.Size = UDim2.new(0.5, -12, 0, 14)
ServerTitle.Position = UDim2.fromOffset(14, 10)
ServerTitle.BackgroundTransparency = 1
ServerTitle.Text = "SERVER"
ServerTitle.TextColor3 = ACCENT
ServerTitle.TextSize = 10
ServerTitle.Font = Enum.Font.GothamBold
ServerTitle.TextXAlignment = Enum.TextXAlignment.Left
ServerTitle.Parent = ServerCard

local ServerPlayersLabel = Instance.new("TextLabel")
ServerPlayersLabel.Name = "ServerPlayers"
ServerPlayersLabel.Size = UDim2.new(0.5, -12, 0, 14)
ServerPlayersLabel.Position = UDim2.new(0.5, 0, 0, 10)
ServerPlayersLabel.BackgroundTransparency = 1
ServerPlayersLabel.Text = "0 players"
ServerPlayersLabel.TextColor3 = MUTED
ServerPlayersLabel.TextSize = 11
ServerPlayersLabel.Font = Enum.Font.Gotham
ServerPlayersLabel.TextXAlignment = Enum.TextXAlignment.Right
ServerPlayersLabel.Parent = ServerCard

local ServerPlaceLabel = Instance.new("TextLabel")
ServerPlaceLabel.Name = "ServerPlace"
ServerPlaceLabel.Size = UDim2.new(1, -28, 0, 18)
ServerPlaceLabel.Position = UDim2.fromOffset(14, 28)
ServerPlaceLabel.BackgroundTransparency = 1
ServerPlaceLabel.Text = "—"
ServerPlaceLabel.TextColor3 = TEXT
ServerPlaceLabel.TextSize = 13
ServerPlaceLabel.Font = Enum.Font.GothamMedium
ServerPlaceLabel.TextXAlignment = Enum.TextXAlignment.Left
ServerPlaceLabel.TextTruncate = Enum.TextTruncate.AtEnd
ServerPlaceLabel.Parent = ServerCard

local ServerJobLabel = Instance.new("TextLabel")
ServerJobLabel.Name = "ServerJob"
ServerJobLabel.Size = UDim2.new(1, -28, 0, 12)
ServerJobLabel.Position = UDim2.fromOffset(14, 46)
ServerJobLabel.BackgroundTransparency = 1
ServerJobLabel.Text = "Job —"
ServerJobLabel.TextColor3 = MUTED
ServerJobLabel.TextSize = 10
ServerJobLabel.Font = Enum.Font.Gotham
ServerJobLabel.TextXAlignment = Enum.TextXAlignment.Left
ServerJobLabel.TextTruncate = Enum.TextTruncate.AtEnd
ServerJobLabel.Parent = ServerCard

function configuration.RefreshServerWidget()
	local count = #Players:GetPlayers()
	ServerPlayersLabel.Text = string.format("%d player%s", count, count == 1 and "" or "s")
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
configuration.RefreshServerWidget()
Players.PlayerAdded:Connect(function() configuration.RefreshServerWidget() end)
Players.PlayerRemoving:Connect(function() task.defer(configuration.RefreshServerWidget) end)

--==================================================
-- HERO EXP CARD (big numbers)
--==================================================
InfoCard = Instance.new("Frame")
InfoCard.Size = UDim2.new(1, 0, 0, 242)
InfoCard.LayoutOrder = 3
InfoCard.BackgroundColor3 = CARD
InfoCard.BorderSizePixel = 0
InfoCard.Parent = ExpPage
Instance.new("UICorner", InfoCard).CornerRadius = UDim.new(0, 12)
local InfoStroke = Instance.new("UIStroke", InfoCard)
InfoStroke.Color = BORDER
InfoStroke.Thickness = 1
InfoStroke.Transparency = 0.35

-- Player level + Exp current/max (no separate level progress bar)
local LevelCaption = Instance.new("TextLabel")
LevelCaption.Size = UDim2.new(0.5, -12, 0, 12)
LevelCaption.Position = UDim2.fromOffset(12, 6)
LevelCaption.BackgroundTransparency = 1
LevelCaption.Text = "YOUR LEVEL"
LevelCaption.TextColor3 = ACCENT
LevelCaption.TextSize = 9
LevelCaption.Font = Enum.Font.GothamBold
LevelCaption.TextXAlignment = Enum.TextXAlignment.Left
LevelCaption.Parent = InfoCard

local LevelLabel = Instance.new("TextLabel")
LevelLabel.Name = "LevelLabel"
LevelLabel.Size = UDim2.new(0.45, -8, 0, 22)
LevelLabel.Position = UDim2.fromOffset(12, 18)
LevelLabel.BackgroundTransparency = 1
LevelLabel.Text = "Lv —"
LevelLabel.TextColor3 = TEXT
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
LevelExpText.TextColor3 = MUTED
LevelExpText.TextSize = 13
LevelExpText.Font = Enum.Font.GothamBold
LevelExpText.TextXAlignment = Enum.TextXAlignment.Right
LevelExpText.Parent = InfoCard

-- Big farm EXP number (target mob EXP toward goal)
local ExpCaption = Instance.new("TextLabel")
ExpCaption.Size = UDim2.new(1, -20, 0, 12)
ExpCaption.Position = UDim2.fromOffset(10, 44)
ExpCaption.BackgroundTransparency = 1
ExpCaption.Text = "TARGET EXP  (FARM)"
ExpCaption.TextColor3 = ACCENT
ExpCaption.TextSize = 9
ExpCaption.Font = Enum.Font.GothamBold
ExpCaption.TextXAlignment = Enum.TextXAlignment.Center
ExpCaption.Parent = InfoCard

local ExpLabel = Instance.new("TextLabel")
ExpLabel.Size = UDim2.new(1, -20, 0, 40)
ExpLabel.Position = UDim2.fromOffset(10, 56)
ExpLabel.BackgroundTransparency = 1
ExpLabel.Text = "0"
ExpLabel.TextColor3 = GREEN
ExpLabel.TextSize = 32
ExpLabel.Font = Enum.Font.GothamBlack
ExpLabel.TextXAlignment = Enum.TextXAlignment.Center
ExpLabel.Parent = InfoCard

local MaxLabel = Instance.new("TextLabel")
MaxLabel.Size = UDim2.new(1, -20, 0, 14)
MaxLabel.Position = UDim2.fromOffset(10, 96)
MaxLabel.BackgroundTransparency = 1
MaxLabel.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
MaxLabel.TextColor3 = MUTED
MaxLabel.TextSize = 12
MaxLabel.Font = Enum.Font.Gotham
MaxLabel.TextXAlignment = Enum.TextXAlignment.Center
MaxLabel.Parent = InfoCard

-- Farm target progress bar only
local BarBg = Instance.new("Frame")
BarBg.Size = UDim2.new(1, -28, 0, 8)
BarBg.Position = UDim2.fromOffset(14, 114)
BarBg.BackgroundColor3 = INPUT
BarBg.BorderSizePixel = 0
BarBg.Parent = InfoCard
Instance.new("UICorner", BarBg).CornerRadius = UDim.new(1, 0)

local Bar = Instance.new("Frame")
Bar.Size = UDim2.fromScale(0, 1)
Bar.BackgroundColor3 = GREEN
Bar.BorderSizePixel = 0
Bar.Parent = BarBg
Instance.new("UICorner", Bar).CornerRadius = UDim.new(1, 0)

local PercentLabel = Instance.new("TextLabel")
PercentLabel.Size = UDim2.new(1, 0, 0, 14)
PercentLabel.Position = UDim2.fromOffset(0, 126)
PercentLabel.BackgroundTransparency = 1
PercentLabel.Text = "0%"
PercentLabel.TextColor3 = MUTED
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
TargetLabel.TextColor3 = TEXT
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
DistLabel.TextColor3 = MUTED
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
TimeLabel.TextColor3 = YELLOW
TimeLabel.TextSize = 11
TimeLabel.Font = Enum.Font.GothamBold
TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
TimeLabel.Parent = InfoCard

local RateLabel = Instance.new("TextLabel")
RateLabel.Size = UDim2.new(0.32, -4, 0, 15)
RateLabel.Position = UDim2.new(0.36, 0, 0, 166)
RateLabel.BackgroundTransparency = 1
RateLabel.Text = "Rate -"
RateLabel.TextColor3 = MUTED
RateLabel.TextSize = 11
RateLabel.Font = Enum.Font.Gotham
RateLabel.TextXAlignment = Enum.TextXAlignment.Center
RateLabel.Parent = InfoCard

local StateLabel = Instance.new("TextLabel")
StateLabel.Size = UDim2.new(1, -24, 0, 14)
StateLabel.Position = UDim2.fromOffset(12, 184)
StateLabel.BackgroundTransparency = 1
StateLabel.Text = "Idle"
StateLabel.TextColor3 = MUTED
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
SessionLabel.TextColor3 = MUTED
SessionLabel.TextSize = 10
SessionLabel.Font = Enum.Font.Gotham
SessionLabel.TextXAlignment = Enum.TextXAlignment.Left
SessionLabel.Parent = InfoCard

local RecentCycleLabel = Instance.new("TextLabel")
RecentCycleLabel.Size = UDim2.new(1, -24, 0, 14)
RecentCycleLabel.Position = UDim2.fromOffset(12, 222)
RecentCycleLabel.BackgroundTransparency = 1
RecentCycleLabel.Text = configuration.RecentCycle
RecentCycleLabel.TextColor3 = MUTED
RecentCycleLabel.TextSize = 10
RecentCycleLabel.Font = Enum.Font.Gotham
RecentCycleLabel.TextXAlignment = Enum.TextXAlignment.Left
RecentCycleLabel.Parent = InfoCard

--==================================================
-- START BUTTON
--==================================================
StartBtn = Instance.new("TextButton")
StartBtn.Size = UDim2.new(1, 0, 0, 42)
StartBtn.LayoutOrder = 3
StartBtn.BackgroundColor3 = ACCENT
StartBtn.BorderSizePixel = 0
StartBtn.Text = "Start"
StartBtn.TextColor3 = Color3.new(1, 1, 1)
StartBtn.TextSize = 15
StartBtn.Font = Enum.Font.GothamBold
StartBtn.Parent = ExpPage
Instance.new("UICorner", StartBtn).CornerRadius = UDim.new(0, 10)

local EmergencyStopButton = Instance.new("TextButton")
EmergencyStopButton.Size = UDim2.new(1, 0, 0, 34)
EmergencyStopButton.LayoutOrder = 4
EmergencyStopButton.BackgroundColor3 = CARD
EmergencyStopButton.BorderSizePixel = 0
EmergencyStopButton.Text = "Emergency stop: OFF"
EmergencyStopButton.TextColor3 = MUTED
EmergencyStopButton.TextSize = 12
EmergencyStopButton.Font = Enum.Font.GothamBold
EmergencyStopButton.Parent = ExpPage
Instance.new("UICorner", EmergencyStopButton).CornerRadius = UDim.new(0, 8)

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
ToggleGridLayout.Padding = UDim.new(0, 6)
ToggleGridLayout.SortOrder = Enum.SortOrder.LayoutOrder

function configuration.MakeToggleGrid(parent, order)
	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = order
	grid.BackgroundTransparency = 1
	grid.Parent = parent
	local layout = Instance.new("UIListLayout", grid)
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	return grid
end

local AlertsGrid = configuration.MakeToggleGrid(AlertsPage, 2)
local PlayersGrid = configuration.MakeToggleGrid(PlayerPage, 2)
local CombatGrid = configuration.MakeToggleGrid(CombatPage, 2)
local AttackModeGrid = configuration.MakeToggleGrid(CombatPage, 3)

local AlertsDistanceCard = Instance.new("Frame")
AlertsDistanceCard.Size = UDim2.new(1, 0, 0, 48)
AlertsDistanceCard.LayoutOrder = 3
AlertsDistanceCard.BackgroundColor3 = CARD
AlertsDistanceCard.BorderSizePixel = 0
AlertsDistanceCard.Parent = AlertsPage
Instance.new("UICorner", AlertsDistanceCard).CornerRadius = UDim.new(0, 8)

local AlertsDistanceLabel = Instance.new("TextLabel")
AlertsDistanceLabel.Size = UDim2.new(0.58, -16, 1, 0)
AlertsDistanceLabel.Position = UDim2.new(0, 10, 0, 0)
AlertsDistanceLabel.BackgroundTransparency = 1
AlertsDistanceLabel.Text = "Player alert range (studs)"
AlertsDistanceLabel.TextColor3 = TEXT
AlertsDistanceLabel.TextSize = 11
AlertsDistanceLabel.Font = Enum.Font.Gotham
AlertsDistanceLabel.TextXAlignment = Enum.TextXAlignment.Left
AlertsDistanceLabel.Parent = AlertsDistanceCard

local AlertsDistanceInput = Instance.new("TextBox")
AlertsDistanceInput.Size = UDim2.new(0.36, -8, 0, 30)
AlertsDistanceInput.Position = UDim2.new(0.62, 0, 0.5, -15)
AlertsDistanceInput.BackgroundColor3 = INPUT
AlertsDistanceInput.BorderSizePixel = 0
AlertsDistanceInput.Text = tostring(configuration.AlertsDistance)
AlertsDistanceInput.TextColor3 = TEXT
AlertsDistanceInput.TextSize = 12
AlertsDistanceInput.Font = Enum.Font.GothamBold
AlertsDistanceInput.ClearTextOnFocus = false
AlertsDistanceInput.Parent = AlertsDistanceCard
Instance.new("UICorner", AlertsDistanceInput).CornerRadius = UDim.new(0, 6)
AlertsDistanceInput.FocusLost:Connect(function()
	local value = tonumber(AlertsDistanceInput.Text)
	if value and value >= 0 then
		configuration.AlertsDistance = math.clamp(math.floor(value), 0, 100000)
	end
	AlertsDistanceInput.Text = tostring(configuration.AlertsDistance)
	configuration.SaveConfig()
end)

function configuration.SetToggleVisual(btn, title, isOn, onColor, onBg)
	if not btn then return end
	local titleLabel = btn:FindFirstChild("Title")
	local switch = btn:FindFirstChild("Switch")
	local knob = switch and switch:FindFirstChild("Knob")
	local clean = title or btn:GetAttribute("BaseTitle") or ""
	clean = tostring(clean):gsub("%s*:?%s*ON%s*$", ""):gsub("%s*:?%s*OFF%s*$", "")
	if titleLabel then
		titleLabel.Text = clean
		titleLabel.TextColor3 = TEXT
	end
	btn:SetAttribute("BaseTitle", clean)
	btn:SetAttribute("IsOn", isOn and true or false)
	btn.BackgroundColor3 = CARD
	btn.Text = ""
	if switch then
		-- Always use accent blue for ON (Slayers2-style), gray for OFF
		switch.BackgroundColor3 = isOn and ACCENT or Color3.fromRGB(55, 60, 78)
		if knob then
			knob.Position = isOn and UDim2.new(1, -20, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
		end
	end
end

function configuration.MakeToggle(text, isOn, onColor, onBg, order, parent, description)
	local clean = tostring(text or ""):gsub("%s*:?%s*ON%s*$", ""):gsub("%s*:?%s*OFF%s*$", "")
	local hasDesc = type(description) == "string" and description ~= ""
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, hasDesc and 58 or 48)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = CARD
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent or ToggleGrid
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = BORDER
	stroke.Transparency = 0.65
	stroke.Thickness = 1

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -72, 0, hasDesc and 20 or 48)
	titleLabel.Position = UDim2.fromOffset(16, hasDesc and 10 or 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = clean
	titleLabel.TextColor3 = TEXT
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
		descLabel.TextColor3 = MUTED
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
	switch.BackgroundColor3 = isOn and ACCENT or Color3.fromRGB(55, 60, 78)
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

-- Action row: title + description + chevron (opens a panel / runs an action — not a switch)
function configuration.SetActionVisual(btn, title, accented)
	if not btn then return end
	local titleLabel = btn:FindFirstChild("Title")
	local clean = tostring(title or btn:GetAttribute("BaseTitle") or "")
	if titleLabel then
		titleLabel.Text = clean
		titleLabel.TextColor3 = accented and ACCENT or TEXT
	end
	btn:SetAttribute("BaseTitle", clean)
	btn.BackgroundColor3 = accented and ACCENT_DIM or CARD
	btn.Text = ""
end

function configuration.MakeActionRow(text, order, parent, description)
	local clean = tostring(text or "")
	local hasDesc = type(description) == "string" and description ~= ""
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, hasDesc and 58 or 48)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = CARD
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = BORDER
	stroke.Transparency = 0.65
	stroke.Thickness = 1

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -48, 0, hasDesc and 20 or 48)
	titleLabel.Position = UDim2.fromOffset(16, hasDesc and 10 or 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = clean
	titleLabel.TextColor3 = TEXT
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
		descLabel.TextColor3 = MUTED
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
	chevron.TextColor3 = MUTED
	chevron.TextSize = 16
	chevron.Font = Enum.Font.GothamBold
	chevron.Parent = btn

	btn:SetAttribute("BaseTitle", clean)
	btn:SetAttribute("IsAction", true)
	return btn
end

function configuration.MakeNumberCard(parent, title, initialValue, order, minValue, maxValue, onChanged)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 52)
	card.LayoutOrder = order
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
	local cardStroke = Instance.new("UIStroke", card)
	cardStroke.Color = BORDER
	cardStroke.Transparency = 0.65
	cardStroke.Thickness = 1

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.58, -16, 1, 0)
	label.Position = UDim2.new(0, 16, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = TEXT
	label.TextSize = 13
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = card

	local input = Instance.new("TextBox")
	input.Size = UDim2.new(0.34, -8, 0, 30)
	input.Position = UDim2.new(0.64, 0, 0.5, -15)
	input.BackgroundColor3 = INPUT
	input.BorderSizePixel = 0
	input.Text = tostring(initialValue())
	input.TextColor3 = TEXT
	input.TextSize = 12
	input.Font = Enum.Font.GothamBold
	input.ClearTextOnFocus = false
	input.Parent = card
	Instance.new("UICorner", input).CornerRadius = UDim.new(0, 6)
	input.FocusLost:Connect(function()
		local value = tonumber(input.Text)
		if value and value >= minValue then onChanged(math.clamp(math.floor(value), minValue, maxValue)) end
		input.Text = tostring(initialValue())
		configuration.SaveConfig()
	end)
	return card, input
end

local WaypointInfo = Instance.new("TextLabel")
WaypointInfo.Size = UDim2.new(1, -12, 0, 34)
WaypointInfo.LayoutOrder = 2
WaypointInfo.BackgroundTransparency = 1
WaypointInfo.TextColor3 = MUTED
WaypointInfo.TextSize = 12
WaypointInfo.Font = Enum.Font.Gotham
WaypointInfo.TextWrapped = true
WaypointInfo.TextXAlignment = Enum.TextXAlignment.Left
WaypointInfo.Parent = WaypointPage

local ReturnToWaypointButton = configuration.MakeToggle(
	"Return to waypoint",
	configuration.WaypointReturnEnabled,
	ACCENT,
	ACCENT_DIM,
	3,
	WaypointPage,
	"Walk back when you move outside the radius."
)

local function UpdateWaypointInfo()
	local point = configuration.WaypointPosition
	WaypointInfo.Text = point and string.format("Pinned at  %.1f, %.1f, %.1f", point.X, point.Y, point.Z)
		or "No waypoint set"
	configuration.SetToggleVisual(
		ReturnToWaypointButton,
		"Return to waypoint",
		configuration.WaypointReturnEnabled,
		ACCENT,
		ACCENT_DIM
	)
end

local SetWaypointButton = configuration.MakeActionRow(
	"Pin current position",
	4,
	WaypointPage,
	"Save where you are standing as the return point."
)
SetWaypointButton.MouseButton1Click:Connect(function()
	local character = Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	configuration.WaypointPosition = root.Position
	configuration.WaypointReturnEnabled = true
	UpdateWaypointInfo()
	configuration.SaveConfig()
end)

local ClearWaypointButton = configuration.MakeActionRow("Clear waypoint", 5, WaypointPage)
ClearWaypointButton.MouseButton1Click:Connect(function()
	configuration.WaypointPosition = nil
	configuration.WaypointReturnEnabled = false
	configuration.CombatSystem.ResetNavigationState(configuration.WaypointMoveState or {})
	UpdateWaypointInfo()
	configuration.SaveConfig()
end)

local WaypointRadiusCard, WaypointRadiusInput = configuration.MakeNumberCard(
	WaypointPage,
	"Return radius (studs)",
	function() return configuration.WaypointReturnRadius end,
	6,
	2,
	100,
	function(value) configuration.WaypointReturnRadius = value end
)
WaypointRadiusInput.FocusLost:Connect(function()
	WaypointRadiusInput.Text = tostring(configuration.WaypointReturnRadius)
	configuration.SaveConfig()
end)
ReturnToWaypointButton.MouseButton1Click:Connect(function()
	if not configuration.WaypointPosition then
		configuration.WaypointReturnEnabled = false
		UpdateWaypointInfo()
		return
	end
	configuration.WaypointReturnEnabled = not configuration.WaypointReturnEnabled
	UpdateWaypointInfo()
	configuration.SaveConfig()
end)
UpdateWaypointInfo()

local FollowDistanceCard, FollowDistanceInput = configuration.MakeNumberCard(
	PlayerPage, "Follow spacing (studs)", function() return configuration.FollowDistance end, 3, 2, 100,
	function(value) configuration.FollowDistance = value end
)

local AutoAttackButton = configuration.MakeToggle("Auto attack", configuration.AutoAttackEnabled, RED, RED_DIM, 1, CombatGrid, "Attack the selected target automatically.")
local AutoSkillButton = configuration.MakeToggle("Auto skill", configuration.AutoSkillEnabled, ACCENT, ACCENT_DIM, 2, CombatGrid, "Use skills on an interval while attacking.")
CombatTargetButton = configuration.MakeActionRow("Select player target", 3, CombatGrid, "Pick which player to focus in Player mode.")
local ExpMobTargetButton = configuration.MakeToggle("Attack EXP target", configuration.AutoAttackUseExpTarget, ACCENT, ACCENT_DIM, 4, CombatGrid, "Force combat onto the current EXP farm mob.")
local ExpTargetRetaliationButton = configuration.MakeToggle("Fight back if EXP mob is hit", configuration.ExpTargetRetaliationEnabled, RED, RED_DIM, 5, CombatGrid, "If your EXP mob takes damage, kill it first.")
local BossPriorityButton = configuration.MakeToggle("Prioritize bosses", configuration.AutoAttackBossPriority, ACCENT, ACCENT_DIM, 6, CombatGrid,
	"Choose a nearby boss before ordinary mobs. Manual and EXP targets stay locked.")
configuration.BossesOnlyButton = configuration.MakeToggle("Bosses only", configuration.AutoAttackBossesOnly, ACCENT, ACCENT_DIM, 7, CombatGrid,
	"Only select bosses for normal Auto Attack. Alert and active EXP safety targets may still take priority.")
local CombatDiagnosticsButton = configuration.MakeToggle("Combat diagnostics", false, ACCENT, ACCENT_DIM, 8, CombatGrid,
	"Show the locked target, current route and detected attack hitboxes.")

local AutoAttackModeButtons = {
	Mob = configuration.MakeToggle("Target: Mobs", configuration.AutoAttackMode == "Mob", ACCENT, ACCENT_DIM, 1, AttackModeGrid, "Only attack monsters."),
	Player = configuration.MakeToggle("Target: Players", configuration.AutoAttackMode == "Player", ACCENT, ACCENT_DIM, 2, AttackModeGrid, "Only attack the selected player."),
	Nearby = configuration.MakeToggle("Target: Nearest (mob or player)", configuration.AutoAttackMode == "Nearby", ACCENT, ACCENT_DIM, 3, AttackModeGrid, "Lock the nearest mob or player until it dies."),
}

-- Combat is intentionally limited to the mob selected in the list below.
CombatTargetButton.Visible = false
ExpMobTargetButton.Visible = false
ExpTargetRetaliationButton.Visible = false
BossPriorityButton.Visible = false
configuration.BossesOnlyButton.Visible = false
CombatDiagnosticsButton.Visible = false
AutoAttackModeButtons.Player.Visible = false
AutoAttackModeButtons.Nearby.Visible = false

local AutoAttackRangeCard, AutoAttackRangeInput = configuration.MakeNumberCard(
	CombatPage, "Attack target range (studs)", function() return configuration.AutoAttackRange end, 4, 5, 500,
	function(value) configuration.AutoAttackRange = value end
)

local AutoAttackSearchRangeCard, AutoAttackSearchRangeInput = configuration.MakeNumberCard(
	CombatPage, "Mob visibility range (studs)", function() return configuration.AutoAttackSearchRange end, 5, 5, 1000,
	function(value) configuration.AutoAttackSearchRange = value end
)

local AutoAttackIntervalCard, AutoAttackIntervalInput = configuration.MakeNumberCard(
	CombatPage, "Attack interval (seconds)", function() return configuration.AutoAttackInterval end, 6, 1, 10,
	function(value) configuration.AutoAttackInterval = value end
)

local AutoSkillIntervalCard, AutoSkillIntervalInput = configuration.MakeNumberCard(
	CombatPage, "Skill interval (seconds)", function() return configuration.AutoSkillInterval end, 7, 1, 30,
	function(value) configuration.AutoSkillInterval = value end
)

local CombatMobHeading = Instance.new("Frame")
CombatMobHeading.Size = UDim2.new(1, 0, 0, 30)
CombatMobHeading.LayoutOrder = 8
CombatMobHeading.BackgroundTransparency = 1
CombatMobHeading.Parent = CombatPage

local CombatMobTitle = Instance.new("TextLabel")
CombatMobTitle.Size = UDim2.new(0.65, 0, 1, 0)
CombatMobTitle.BackgroundTransparency = 1
CombatMobTitle.Text = "Available mobs"
CombatMobTitle.TextColor3 = TEXT
CombatMobTitle.TextSize = 12
CombatMobTitle.Font = Enum.Font.GothamBold
CombatMobTitle.TextXAlignment = Enum.TextXAlignment.Left
CombatMobTitle.Parent = CombatMobHeading

local CombatMobRefresh = Instance.new("TextButton")
CombatMobRefresh.Size = UDim2.new(0.32, 0, 1, 0)
CombatMobRefresh.Position = UDim2.new(0.68, 0, 0, 0)
CombatMobRefresh.BackgroundColor3 = INPUT
CombatMobRefresh.BorderSizePixel = 0
CombatMobRefresh.Text = "Refresh list"
CombatMobRefresh.TextColor3 = TEXT
CombatMobRefresh.TextSize = 11
CombatMobRefresh.Font = Enum.Font.GothamBold
CombatMobRefresh.Parent = CombatMobHeading
Instance.new("UICorner", CombatMobRefresh).CornerRadius = UDim.new(0, 7)

local CombatMobScroll = Instance.new("ScrollingFrame")
CombatMobScroll.Size = UDim2.new(1, 0, 0, 120)
CombatMobScroll.LayoutOrder = 9
CombatMobScroll.BackgroundColor3 = CARD
CombatMobScroll.BorderSizePixel = 0
CombatMobScroll.ScrollBarThickness = 3
CombatMobScroll.ScrollBarImageColor3 = MUTED
CombatMobScroll.CanvasSize = UDim2.new()
CombatMobScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
CombatMobScroll.ScrollingDirection = Enum.ScrollingDirection.Y
CombatMobScroll.Parent = CombatPage
Instance.new("UICorner", CombatMobScroll).CornerRadius = UDim.new(0, 8)

local CombatMobListLayout = Instance.new("UIListLayout")
CombatMobListLayout.Padding = UDim.new(0, 4)
CombatMobListLayout.SortOrder = Enum.SortOrder.LayoutOrder
CombatMobListLayout.Parent = CombatMobScroll

configuration.CombatMobRows = {}
configuration.CombatMobUI = { RowByMob = {}, RefreshQueued = false, LastRefreshAt = 0, ListDirty = true }
function configuration.SyncCombatMobRowSelection()
	for mob, row in pairs(configuration.CombatMobUI.RowByMob) do
		if row.Parent then
			local selected = configuration.SelectedCombatMob == mob
			row.BackgroundColor3 = selected and ACCENT_DIM or INPUT
			row.TextColor3 = selected and ACCENT or TEXT
			row.Text = selected and row:GetAttribute("SelectedText") or row:GetAttribute("BaseText")
		end
	end
end

function configuration.RefreshCombatMobs()
	if not CombatPage.Visible then return end
	if not configuration.CombatMobUI.ListDirty then
		configuration.SyncCombatMobRowSelection()
		return
	end
	configuration.CombatMobUI.ListDirty = false
	for _, row in ipairs(configuration.CombatMobRows) do
		row:Destroy()
	end
	table.clear(configuration.CombatMobRows)
	table.clear(configuration.CombatMobUI.RowByMob)

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
		if root and root:IsA("BasePart") and visibleDistance <= configuration.AutoAttackSearchRange and (not humanoid or humanoid.Health > 0) then
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
				IsBoss = IsBossMob(mob, cfg),
			}
			table.insert(entries, entry)
			groupCounts[key] = (groupCounts[key] or 0) + 1
			if groupHasLevels[key] == nil then groupHasLevels[key] = true end
			if not entry.Level then groupHasLevels[key] = false end
		end
	end

	table.sort(entries, function(a, b)
		if a.IsBoss ~= b.IsBoss then return a.IsBoss end
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
		local isSelectedMob = configuration.SelectedCombatMob == selectedMob
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -8, 0, 30)
		row.LayoutOrder = order
		row.BackgroundColor3 = isSelectedMob and ACCENT_DIM or INPUT
		row.BorderSizePixel = 0
		local baseText = string.format("%s%s  •  Lv %s  •  EXP %s", entry.IsBoss and "BOSS  •  " or "", entry.Name,
			entry.Level and tostring(entry.Level) or "—", entry.EXP > -math.huge and tostring(entry.EXP) or "—")
		row:SetAttribute("BaseText", baseText)
		row:SetAttribute("SelectedText", "✓  " .. baseText)
		row.Text = isSelectedMob and ("✓  " .. baseText) or baseText
		row.TextColor3 = isSelectedMob and ACCENT or TEXT
		row.TextSize = 11
		row.Font = Enum.Font.Gotham
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Parent = CombatMobScroll
		configuration.CombatMobUI.RowByMob[selectedMob] = row
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
		row.MouseButton1Click:Connect(function()
			if not selectedMob:IsDescendantOf(MobsFolder) then
				configuration.CombatMobUI.ListDirty = true
				configuration.RefreshCombatMobs()
				return
			end
			configuration.AutoAttackUseExpTarget = false
			configuration.UpdateExpMobTargetButton()
			configuration.SelectedCombatMob = selectedMob
			configuration.AutoAttackPinnedMob = selectedMob
			configuration.CombatTargetMob = selectedMob
			configuration.AutoAttackMode = "Mob"
			configuration.UpdateAutoAttackModeButtons()
			configuration.SaveConfig()
			configuration.RefreshCombatMobs()
		end)
		table.insert(configuration.CombatMobRows, row)
	end
	if #entries == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -8, 0, 30)
		empty.BackgroundTransparency = 1
		empty.Text = "No mobs found in this server"
		empty.TextColor3 = MUTED
		empty.TextSize = 11
		empty.Font = Enum.Font.Gotham
		empty.Parent = CombatMobScroll
		table.insert(configuration.CombatMobRows, empty)
	end
end

function configuration.RequestCombatMobRefresh()
	configuration.CombatMobUI.ListDirty = true
	if configuration.CombatMobUI.RefreshQueued or not CombatPage.Visible then return end
	configuration.CombatMobUI.RefreshQueued = true
	local delay = math.max(0.12, 0.45 - (os.clock() - configuration.CombatMobUI.LastRefreshAt))
	task.delay(delay, function()
		configuration.CombatMobUI.RefreshQueued = false
		if CombatMobScroll.Parent and CombatPage.Visible then
			configuration.CombatMobUI.LastRefreshAt = os.clock()
			configuration.RefreshCombatMobs()
		end
	end)
end

CombatMobRefresh.MouseButton1Click:Connect(function()
	configuration.CombatMobUI.ListDirty = true
	configuration.RefreshCombatMobs()
end)
MobsFolder.ChildAdded:Connect(configuration.RequestCombatMobRefresh)
MobsFolder.ChildRemoved:Connect(configuration.RequestCombatMobRefresh)
configuration.RefreshCombatMobs()

configuration.CombatStatusCard = Instance.new("Frame")
configuration.CombatStatusCard.Size = UDim2.new(1, 0, 0, 78)
configuration.CombatStatusCard.LayoutOrder = 10
configuration.CombatStatusCard.BackgroundColor3 = CARD
configuration.CombatStatusCard.BorderSizePixel = 0
configuration.CombatStatusCard.Parent = CombatPage
Instance.new("UICorner", configuration.CombatStatusCard).CornerRadius = UDim.new(0, 8)
configuration.CombatStatusStroke = Instance.new("UIStroke", configuration.CombatStatusCard)
configuration.CombatStatusStroke.Color = INPUT
configuration.CombatStatusStroke.Transparency = 0.35

configuration.CombatStatusAccent = Instance.new("Frame")
configuration.CombatStatusAccent.Size = UDim2.new(0, 3, 1, -18)
configuration.CombatStatusAccent.Position = UDim2.fromOffset(8, 9)
configuration.CombatStatusAccent.BackgroundColor3 = ACCENT
configuration.CombatStatusAccent.BorderSizePixel = 0
configuration.CombatStatusAccent.Parent = configuration.CombatStatusCard
Instance.new("UICorner", configuration.CombatStatusAccent).CornerRadius = UDim.new(1, 0)

configuration.CombatStatusTitle = Instance.new("TextLabel")
configuration.CombatStatusTitle.Size = UDim2.new(1, -28, 0, 16)
configuration.CombatStatusTitle.Position = UDim2.fromOffset(19, 7)
configuration.CombatStatusTitle.BackgroundTransparency = 1
configuration.CombatStatusTitle.Text = "COMBAT STATUS"
configuration.CombatStatusTitle.TextColor3 = ACCENT
configuration.CombatStatusTitle.TextSize = 9
configuration.CombatStatusTitle.Font = Enum.Font.GothamBold
configuration.CombatStatusTitle.TextXAlignment = Enum.TextXAlignment.Left
configuration.CombatStatusTitle.Parent = configuration.CombatStatusCard

configuration.CombatInfo = Instance.new("TextLabel")
configuration.CombatInfo.Size = UDim2.new(1, -28, 0, 49)
configuration.CombatInfo.Position = UDim2.fromOffset(19, 23)
configuration.CombatInfo.BackgroundTransparency = 1
configuration.CombatInfo.Text = "Combat locks one target, routes around obstacles, and attacks while closing in. It holds still in range; skills fire in range only. EXP firing behavior stays unchanged."
configuration.CombatInfo.TextColor3 = TEXT
configuration.CombatInfo.TextSize = 10
configuration.CombatInfo.Font = Enum.Font.Gotham
configuration.CombatInfo.TextWrapped = true
configuration.CombatInfo.TextXAlignment = Enum.TextXAlignment.Left
configuration.CombatInfo.TextYAlignment = Enum.TextYAlignment.Top
configuration.CombatInfo.Parent = configuration.CombatStatusCard

configuration.HitboxCountCache = setmetatable({}, { __mode = "k" })
configuration.TargetHealthCache = setmetatable({}, { __mode = "k" })
configuration.CombatDebugFolder = nil
configuration.CombatDebugBillboard = nil
configuration.CombatDebugText = nil
configuration.CombatDebugMarkers = {}
configuration.LastCombatDiagnosticsUpdate = 0

function configuration.CountExposedAttackHitboxes(model)
	if not model or not model:IsA("Model") then return 0 end
	local now = os.clock()
	local cached = configuration.HitboxCountCache[model]
	if cached and now - cached.At < 1 then return cached.Count end
	local count = 0
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local explicitlyMarked = item:GetAttribute("CombatHitbox") == true
			local tagged = false
			pcall(function() tagged = CollectionService:HasTag(item, "EnemyAttackHitbox") end)
			local namedWeaponPart = item.Name == "BladePart" and item.Parent
				and (item.Parent.Name == "Sword" or item.Parent.Name == "EnemySword")
			if explicitlyMarked or tagged or namedWeaponPart then count += 1 end
		end
	end
	configuration.HitboxCountCache[model] = { At = now, Count = count }
	return count
end

function configuration.SetCombatDiagnosticsEnabled(enabled)
	configuration.CombatDiagnosticsEnabled = enabled == true
	configuration.SetToggleVisual(CombatDiagnosticsButton, "Combat diagnostics", configuration.CombatDiagnosticsEnabled, ACCENT, ACCENT_DIM)
	if configuration.CombatDiagnosticsEnabled then
		local folderName = "_IamrichCombatDebug_" .. tostring(Player.UserId)
		local oldFolder = workspace:FindFirstChild(folderName)
		if oldFolder then oldFolder:Destroy() end
		configuration.CombatDebugFolder = Instance.new("Folder")
		configuration.CombatDebugFolder.Name = folderName
		configuration.CombatDebugFolder.Parent = workspace
		for index = 1, 8 do
			local marker = Instance.new("Part")
			marker.Name = "RoutePoint" .. index
			marker.Shape = Enum.PartType.Ball
			marker.Size = Vector3.new(index == 1 and 0.9 or 0.55, index == 1 and 0.9 or 0.55, index == 1 and 0.9 or 0.55)
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.Material = Enum.Material.Neon
			marker.Color = index == 1 and ACCENT or Color3.fromRGB(67, 205, 184)
			marker.Transparency = 1
			marker.Parent = configuration.CombatDebugFolder
			configuration.CombatDebugMarkers[index] = marker
		end
		local playerGui = Player:FindFirstChildOfClass("PlayerGui") or ScreenGui
		local billboardName = "_IamrichCombatDiagnostics_" .. tostring(Player.UserId)
		local oldBillboard = playerGui:FindFirstChild(billboardName)
		if oldBillboard then oldBillboard:Destroy() end
		configuration.CombatDebugBillboard = Instance.new("BillboardGui")
		configuration.CombatDebugBillboard.Name = billboardName
		configuration.CombatDebugBillboard.Size = UDim2.fromOffset(230, 66)
		configuration.CombatDebugBillboard.StudsOffset = Vector3.new(0, 4, 0)
		configuration.CombatDebugBillboard.AlwaysOnTop = true
		configuration.CombatDebugBillboard.MaxDistance = 1200
		configuration.CombatDebugBillboard.Enabled = false
		configuration.CombatDebugBillboard.Parent = playerGui
		local background = Instance.new("Frame")
		background.Size = UDim2.fromScale(1, 1)
		background.BackgroundColor3 = BG
		background.BackgroundTransparency = 0.12
		background.BorderSizePixel = 0
		background.Parent = configuration.CombatDebugBillboard
		Instance.new("UICorner", background).CornerRadius = UDim.new(0, 7)
		local stroke = Instance.new("UIStroke", background)
		stroke.Color = ACCENT
		stroke.Transparency = 0.2
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -12, 1, -8)
		label.Position = UDim2.fromOffset(6, 4)
		label.BackgroundTransparency = 1
		label.TextColor3 = TEXT
		label.TextSize = 10
		label.Font = Enum.Font.GothamMedium
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.Parent = background
		configuration.CombatDebugText = label
	else
		if configuration.CombatDebugBillboard then configuration.CombatDebugBillboard:Destroy() end
		if configuration.CombatDebugFolder then configuration.CombatDebugFolder:Destroy() end
		configuration.CombatDebugBillboard, configuration.CombatDebugText, configuration.CombatDebugFolder = nil, nil, nil
		table.clear(configuration.CombatDebugMarkers)
	end
end

CombatDiagnosticsButton.MouseButton1Click:Connect(function()
	configuration.SetCombatDiagnosticsEnabled(not configuration.CombatDiagnosticsEnabled)
end)

function configuration.UpdateCombatDiagnostics(target, targetRoot, distance, attackRange, navigationState, moveState)
	local now = os.clock()
	if now - configuration.LastCombatDiagnosticsUpdate < 0.18 then return end
	configuration.LastCombatDiagnosticsUpdate = now
	local hitboxCount = target and target:IsA("Model") and configuration.CountExposedAttackHitboxes(target) or 0
	local mode = navigationState or "holding"
	if target and targetRoot then
		local name = target.Name
		local kind = target:IsA("Model") and "Mob" or "Player"
		local distanceText = string.format("%.1f / %.1f studs", distance or 0, attackRange or 0)
		local action = (distance or math.huge) <= (attackRange or 0) and "in range · holding/attacking"
			or (moveState and moveState.Active and "approaching · attack input active" or "outside range · route needed")
		local targetModel = target:IsA("Model") and target or target.Character
		local targetHumanoid = targetModel and targetModel:FindFirstChildOfClass("Humanoid")
		local healthState = targetModel and configuration.TargetHealthCache[targetModel]
		if targetHumanoid then
			if not healthState then
				healthState = { Health = targetHumanoid.Health, LastDamageAt = 0 }
				configuration.TargetHealthCache[targetModel] = healthState
			elseif targetHumanoid.Health < healthState.Health - 0.01 then
				healthState.LastDamageAt = now
			end
			if healthState then healthState.Health = targetHumanoid.Health end
		end
		local attackFeedback = "no recent attack input"
		if moveState and moveState.LastAttackTarget == target and moveState.LastAttackSentAt then
			if healthState and healthState.LastDamageAt >= moveState.LastAttackSentAt then
				attackFeedback = "HP drop observed"
			elseif now - moveState.LastAttackSentAt > 1.5 then
				attackFeedback = "no HP drop observed"
			else
				attackFeedback = "waiting for HP response"
			end
		end
		local weaponReady, needsEquip = configuration.Combat.GetWeaponEquipState(Player.Character)
		local weaponStatus = weaponReady and attackFeedback or (needsEquip and "equipping weapon" or "weapon unavailable")
		local statusText = string.format("%s: %s\n%s · %s (%s)\nHitboxes %d · %s", kind, name, distanceText, action, mode, hitboxCount, weaponStatus)
		configuration.CombatInfo.Text = statusText
		if configuration.CombatDebugBillboard then
			configuration.CombatDebugBillboard.Adornee = targetRoot
			configuration.CombatDebugBillboard.Enabled = configuration.CombatDiagnosticsEnabled
			if configuration.CombatDebugText then configuration.CombatDebugText.Text = statusText end
		end
	else
		configuration.CombatInfo.Text = configuration.Farming and "Combat paused during EXP firing."
			or (configuration.AutoAttackEnabled and "Combat: searching for an eligible target."
				or "Combat is idle. Enable Auto Attack and select a target mode.")
		if configuration.CombatDebugBillboard then configuration.CombatDebugBillboard.Enabled = false end
	end

	if configuration.CombatDiagnosticsEnabled and configuration.CombatDebugFolder then
		local points = {}
		if target and targetRoot and moveState and moveState.Waypoints and moveState.WaypointIndex then
			for index = moveState.WaypointIndex, math.min(#moveState.Waypoints, moveState.WaypointIndex + 6) do
				table.insert(points, moveState.Waypoints[index].Position)
			end
		elseif target and targetRoot and moveState and (moveState.PathGoal or moveState.Goal or moveState.PathMoveGoal) then
			table.insert(points, moveState.PathGoal or moveState.Goal or moveState.PathMoveGoal)
		end
		for index, marker in ipairs(configuration.CombatDebugMarkers) do
			local point = points[index]
			marker.Transparency = point and 0.18 or 1
			if point then marker.Position = point end
		end
	end
end

function configuration.UpdateAttackTargetButton()
	local targetPlayer = configuration.AutoAttackTargetUserId and Players:GetPlayerByUserId(tonumber(configuration.AutoAttackTargetUserId))
	configuration.SetActionVisual(CombatTargetButton, targetPlayer and ("Target: @" .. targetPlayer.Name) or "Select player target", targetPlayer ~= nil)
end
configuration.UpdateAttackTargetButton()

function configuration.UpdateAutoAttackModeButtons()
	local titles = {
		Mob = "Target: Mobs",
		Player = "Target: Players",
		Nearby = "Target: Nearest (mob or player)",
	}
	for mode, button in pairs(AutoAttackModeButtons) do
		local selected = configuration.AutoAttackMode == mode
		configuration.SetToggleVisual(button, titles[mode] or mode, selected, ACCENT, ACCENT_DIM)
	end
	if configuration.RefreshCombatMobs then configuration.RefreshCombatMobs() end
end
configuration.UpdateAutoAttackModeButtons()

function configuration.UpdateExpMobTargetButton()
	configuration.SetToggleVisual(ExpMobTargetButton, "Attack EXP target", configuration.AutoAttackUseExpTarget, ACCENT, ACCENT_DIM)
end

ExpMobTargetButton.MouseButton1Click:Connect(function()
	if configuration.AutoAttackBossesOnly then
		configuration.CombatInfo.Text = "Bosses only is active; EXP target selection is disabled."
		return
	end
	configuration.AutoAttackUseExpTarget = not configuration.AutoAttackUseExpTarget
	if configuration.AutoAttackUseExpTarget then
		configuration.AutoAttackMode = "Mob"
		local target = configuration.CurrentTarget
		if configuration.Combat.IsLivingMob(target) then
			configuration.AutoAttackPinnedMob = target
			configuration.CombatTargetMob = target
		else
			configuration.AutoAttackPinnedMob = nil
			configuration.CombatTargetMob = nil
		end
	else
		configuration.AutoAttackPinnedMob = nil
		configuration.CombatTargetMob = nil
	end
	configuration.UpdateAutoAttackModeButtons()
	configuration.UpdateExpMobTargetButton()
	configuration.SaveConfig()
end)

AutoAttackButton.MouseButton1Click:Connect(function()
	configuration.AutoAttackEnabled = not configuration.AutoAttackEnabled
	configuration.SetToggleVisual(AutoAttackButton, "Auto attack", configuration.AutoAttackEnabled, RED, RED_DIM)
	configuration.SaveConfig()
end)

BossPriorityButton.MouseButton1Click:Connect(function()
	configuration.AutoAttackBossPriority = not configuration.AutoAttackBossPriority
	configuration.SetToggleVisual(BossPriorityButton, "Prioritize bosses", configuration.AutoAttackBossPriority, ACCENT, ACCENT_DIM)
	if not configuration.AutoAttackBossPriority and configuration.AutoAttackPinnedMob == nil then
		configuration.CombatTargetMob = nil
		configuration.NearbyLockKind = nil
		configuration.NearbyLockTarget = nil
	end
	configuration.SaveConfig()
end)

configuration.BossesOnlyButton.MouseButton1Click:Connect(function()
	configuration.AutoAttackBossesOnly = not configuration.AutoAttackBossesOnly
	configuration.SetToggleVisual(configuration.BossesOnlyButton, "Bosses only", configuration.AutoAttackBossesOnly, ACCENT, ACCENT_DIM)
	if configuration.AutoAttackBossesOnly then
		configuration.AutoAttackMode = "Mob"
		configuration.AutoAttackUseExpTarget = false
		configuration.UpdateExpMobTargetButton()
		if configuration.AutoAttackPinnedMob and not IsBossMob(configuration.AutoAttackPinnedMob, configuration.AutoAttackPinnedMob:FindFirstChild("Config")) then
			configuration.AutoAttackPinnedMob = nil
		end
		configuration.CombatTargetMob = nil
		configuration.NearbyLockKind = nil
		configuration.NearbyLockTarget = nil
		configuration.UpdateAutoAttackModeButtons()
	else
		configuration.CombatTargetMob = nil
		configuration.NearbyLockKind = nil
		configuration.NearbyLockTarget = nil
	end
	configuration.SaveConfig()
end)

AutoSkillButton.MouseButton1Click:Connect(function()
	configuration.AutoSkillEnabled = not configuration.AutoSkillEnabled
	configuration.SetToggleVisual(AutoSkillButton, "Auto skill", configuration.AutoSkillEnabled, ACCENT, ACCENT_DIM)
	if configuration.AutoSkillEnabled and not configuration.Farming and configuration.CurrentTarget
		and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
		configuration.AutoAttackPinnedMob = configuration.CurrentTarget
		configuration.CombatTargetMob = configuration.CurrentTarget
	end
	configuration.SaveConfig()
end)

for mode, button in pairs(AutoAttackModeButtons) do
	button.MouseButton1Click:Connect(function()
		if configuration.AutoAttackBossesOnly and mode ~= "Mob" then return end
		configuration.AutoAttackMode = mode
		configuration.NearbyLockKind = nil
		configuration.NearbyLockTarget = nil
		if mode ~= "Mob" then
			if configuration.AutoAttackUseExpTarget then
				configuration.AutoAttackUseExpTarget = false
				configuration.AutoAttackPinnedMob = nil
				configuration.CombatTargetMob = nil
				configuration.UpdateExpMobTargetButton()
			end
		end
		if mode == "Player" then
			configuration.AutoAttackPinnedMob = nil
			configuration.CombatTargetMob = nil
		end
		configuration.UpdateAutoAttackModeButtons()
		configuration.SaveConfig()
	end)
end

local AlertToggleButton = configuration.MakeToggle("Player alert", configuration.AlertsEnabled, GREEN, GREEN_DIM, 1, AlertsGrid, "Alert when a non-whitelisted player gets close.")
local AlertFlashButton = configuration.MakeToggle("Screen flash", configuration.AlertFlashEnabled, RED, RED_DIM, 2, AlertsGrid, "Flash the screen when an alert triggers.")
local AutoResumeButton = configuration.MakeToggle("Auto resume", configuration.AutoResumeAfterAlert, ACCENT, ACCENT_DIM, 3, AlertsGrid, "Resume EXP when the alert clears.")
local ESPToggleButton = configuration.MakeToggle("Player ESP", configuration.ESPEnabled, ACCENT, ACCENT_DIM, 2, nil, "Show markers for other players.")
local ESPLineButton = configuration.MakeToggle("ESP lines", configuration.ESPLineEnabled, ACCENT, ACCENT_DIM, 3, nil, "Draw lines to players.")
local ESPBoxButton = configuration.MakeToggle("ESP boxes", configuration.ESPBoxEnabled, ACCENT, ACCENT_DIM, 4, nil, "Draw boxes around players.")
local AutoBlockButton = configuration.MakeToggle("Auto block", configuration.AutoBlockEnabled, RED, RED_DIM, 5, PlayersGrid, "Show the block prompt after the EXP target is defeated.")
local PlayerListButton = configuration.MakeActionRow("Player list", 1, PlayersGrid, "View players in this server.")
local WhitelistButton = configuration.MakeActionRow("Whitelist", 2, PlayersGrid, "Whitelisted players do not trigger alerts or auto-block.")
FollowSelectButton = configuration.MakeActionRow("Follow player", 3, PlayersGrid, "Follow a player at the chosen spacing.")
StopFollowButton = configuration.MakeActionRow("Stop follow", 4, PlayersGrid, "Stop following the selected player.")

function configuration.UpdateFollowButtons()
	local following = configuration.FollowPlayerUserId ~= nil
	configuration.SetActionVisual(FollowSelectButton, following and "Change follow target" or "Follow player", following)
	configuration.SetActionVisual(StopFollowButton, "Stop follow", following)
end
configuration.UpdateFollowButtons()


AlertToggleButton.MouseButton1Click:Connect(function()
	configuration.AlertsEnabled = not configuration.AlertsEnabled
	configuration.SetToggleVisual(AlertToggleButton, "Player alert", configuration.AlertsEnabled, GREEN, GREEN_DIM)
	configuration.SaveConfig()
	if not configuration.AlertsEnabled then
		AlarmOverlay.Visible = false
	end
end)

AlertFlashButton.MouseButton1Click:Connect(function()
	configuration.AlertFlashEnabled = not configuration.AlertFlashEnabled
	configuration.SetToggleVisual(AlertFlashButton, "Screen flash", configuration.AlertFlashEnabled, RED, RED_DIM)
	if not configuration.AlertFlashEnabled then AlarmOverlay.Visible = false end
	configuration.SaveConfig()
end)

AutoResumeButton.MouseButton1Click:Connect(function()
	configuration.AutoResumeAfterAlert = not configuration.AutoResumeAfterAlert
	configuration.SetToggleVisual(AutoResumeButton, "Auto resume", configuration.AutoResumeAfterAlert, ACCENT, ACCENT_DIM)
	configuration.SaveConfig()
end)

ExpTargetRetaliationButton.MouseButton1Click:Connect(function()
	configuration.ExpTargetRetaliationEnabled = not configuration.ExpTargetRetaliationEnabled
	configuration.SetToggleVisual(ExpTargetRetaliationButton, "Fight back if EXP mob is hit", configuration.ExpTargetRetaliationEnabled, RED, RED_DIM)
	if not configuration.ExpTargetRetaliationEnabled then
		local previousTarget = configuration.ExpRetaliationTarget
		configuration.ExpRetaliationTarget = nil
		if configuration.AutoAttackPinnedMob == previousTarget then
			configuration.AutoAttackPinnedMob = nil
		end
		if configuration.CombatTargetMob == previousTarget then configuration.CombatTargetMob = nil end
	end
	configuration.SaveConfig()
end)

ESPToggleButton.MouseButton1Click:Connect(function()
	configuration.ESPEnabled = not configuration.ESPEnabled
	configuration.SetToggleVisual(ESPToggleButton, "Player ESP", configuration.ESPEnabled, ACCENT, ACCENT_DIM)
	configuration.SaveConfig()
end)

ESPLineButton.MouseButton1Click:Connect(function()
	configuration.ESPLineEnabled = not configuration.ESPLineEnabled
	configuration.SetToggleVisual(ESPLineButton, "ESP lines", configuration.ESPLineEnabled, ACCENT, ACCENT_DIM)
	configuration.SaveConfig()
end)

ESPBoxButton.MouseButton1Click:Connect(function()
	configuration.ESPBoxEnabled = not configuration.ESPBoxEnabled
	configuration.SetToggleVisual(ESPBoxButton, "ESP boxes", configuration.ESPBoxEnabled, ACCENT, ACCENT_DIM)
	configuration.SaveConfig()
end)

AutoBlockButton.MouseButton1Click:Connect(function()
	configuration.AutoBlockEnabled = not configuration.AutoBlockEnabled
	configuration.SetToggleVisual(AutoBlockButton, "Auto block", configuration.AutoBlockEnabled, RED, RED_DIM)
	if not configuration.AutoBlockEnabled and not configuration.AlertCombatPending then
		configuration.AlertCombatBlockReady = false
		configuration.AlertBlockTarget = nil
	end
	configuration.SaveConfig()
end)

function configuration.UpdateEmergencyStopButton()
	EmergencyStopButton.Text = configuration.EmergencyStopActive and "Emergency stop: ON  •  click to resume" or "Emergency stop: OFF"
	EmergencyStopButton.TextColor3 = configuration.EmergencyStopActive and RED or MUTED
	EmergencyStopButton.BackgroundColor3 = configuration.EmergencyStopActive and RED_DIM or CARD
end

EmergencyStopButton.MouseButton1Click:Connect(function()
	configuration.EmergencyStopActive = not configuration.EmergencyStopActive
	if configuration.EmergencyStopActive then
		configuration.Farming = false
		configuration.ExpFinishTarget = nil
		if configuration.StopExpMovement then configuration.StopExpMovement() end
		configuration.PauseTimer()
		configuration.ExpMaxCombatTarget = nil
		configuration.AlertCombatPending = false
		configuration.AlertCombatTarget = nil
		configuration.AlertCombatHold = false
		configuration.AlertCombatBlockReady = false
		configuration.AlertBlockTarget = nil
		configuration.LastAlertCombatUserId = nil
		configuration.ExpRetaliationTarget = nil
		configuration.PendingServerHop = false
		configuration.ServerHopKillTarget = nil
		StartBtn.Text = "Start"
		StartBtn.BackgroundColor3 = ACCENT
		Status.Text = "OFF"
		Status.TextColor3 = RED
		Status.BackgroundColor3 = RED_DIM
		StateLabel.Text = "Emergency stop"
		MiniState.Text = "Emergency stop"
		local character = Player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid then humanoid:MoveTo(root.Position) end
		RestoreMovementBoost()
	else
		StateLabel.Text = configuration.Farming and "Searching..." or "Stopped"
		MiniState.Text = StateLabel.Text
	end
	configuration.UpdateEmergencyStopButton()
end)

Player.Idled:Connect(function()
	if not configuration.AntiAFKEnabled or configuration.EmergencyStopActive then return end
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
		if not configuration.MovementBoostEnabled or configuration.EmergencyStopActive then
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
			local followedPlayer = configuration.FollowPlayerUserId
				and Players:GetPlayerByUserId(tonumber(configuration.FollowPlayerUserId))
			local followedHumanoid = followedPlayer and followedPlayer.Character
				and followedPlayer.Character:FindFirstChildOfClass("Humanoid")
			if followedHumanoid then
				-- The regular movement boost is faster than many followed players and
				-- makes the spacing controller overshoot on each correction.
				humanoid.WalkSpeed = followedHumanoid.WalkSpeed
			elseif level.Value >= 300 then
				humanoid.WalkSpeed = 38
			elseif humanoid.WalkSpeed < 28 then
				humanoid.WalkSpeed = 28
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(leavingPlayer)
	if configuration.FollowPlayerUserId == tostring(leavingPlayer.UserId) then
		configuration.FollowPlayerUserId = nil
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root then humanoid:MoveTo(root.Position) end
		configuration.SaveConfig()
		if configuration.UpdateFollowButtons then configuration.UpdateFollowButtons() end
	end
	if configuration.AutoAttackTargetUserId == tostring(leavingPlayer.UserId) then
		configuration.AutoAttackTargetUserId = nil
		configuration.SaveConfig()
		if configuration.UpdateAttackTargetButton then configuration.UpdateAttackTargetButton() end
	end
end)

--==================================================
-- SETTINGS (compact 2x2)
--==================================================
SettingsCard = Instance.new("Frame")
SettingsCard.Size = UDim2.new(1, 0, 0, 142)
SettingsCard.LayoutOrder = 2
SettingsCard.BackgroundColor3 = CARD
SettingsCard.BorderSizePixel = 0
SettingsCard.Parent = FarmPage
Instance.new("UICorner", SettingsCard).CornerRadius = UDim.new(0, 10)

local SettingsTitle = Instance.new("TextLabel")
SettingsTitle.Size = UDim2.new(1, -16, 0, 18)
SettingsTitle.Position = UDim2.fromOffset(8, 4)
SettingsTitle.BackgroundTransparency = 1
SettingsTitle.Text = "Farming settings"
SettingsTitle.TextColor3 = TEXT
SettingsTitle.TextSize = 13
SettingsTitle.Font = Enum.Font.GothamBold
SettingsTitle.TextXAlignment = Enum.TextXAlignment.Left
SettingsTitle.Parent = SettingsCard

function configuration.MakeCompactSetting(parent, name, default, xScale, yOffset)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.5, -16, 0, 14)
	lbl.Position = UDim2.new(xScale, 8, 0, yOffset)
	lbl.BackgroundTransparency = 1
	lbl.Text = name
	lbl.TextColor3 = MUTED
	lbl.TextSize = 10
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = parent

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.5, -16, 0, 24)
	box.Position = UDim2.new(xScale, 8, 0, yOffset + 14)
	box.BackgroundColor3 = INPUT
	box.BorderSizePixel = 0
	box.Text = tostring(default)
	box.TextColor3 = TEXT
	box.TextSize = 12
	box.Font = Enum.Font.GothamBold
	box.ClearTextOnFocus = false
	box.Parent = parent
	Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
	return box
end

local AmountBox = configuration.MakeCompactSetting(SettingsCard, "Amount / cycle", configuration.Amount, 0, 24)
local DistBox = configuration.MakeCompactSetting(SettingsCard, "EXP target search radius (studs)", configuration.MaxDistance, 0.5, 24)
local IntervalBox = configuration.MakeCompactSetting(SettingsCard, "Interval (s)", configuration.Interval, 0, 62)
local MaxBox = configuration.MakeCompactSetting(SettingsCard, "EXP Max", configuration.ExpGoal, 0.5, 62)
local ExpApproachBox = configuration.MakeCompactSetting(SettingsCard, "EXP firing range / standoff (studs)", configuration.ExpApproachDistance, 0, 100)

local ExpAutoApproachButton = configuration.MakeToggle(
	"Move to target",
	configuration.ExpAutoApproachEnabled,
	ACCENT,
	ACCENT_DIM,
	3,
	FarmPage,
	"Move toward the EXP target while farming."
)
ExpAutoApproachButton.MouseButton1Click:Connect(function()
	configuration.ExpAutoApproachEnabled = not configuration.ExpAutoApproachEnabled
	configuration.SetToggleVisual(
		ExpAutoApproachButton,
		"Move to target",
		configuration.ExpAutoApproachEnabled,
		ACCENT,
		ACCENT_DIM
	)
	configuration.SaveConfig()
end)

AmountBox.FocusLost:Connect(function()
	local v = tonumber(AmountBox.Text)
	if v and v > 0 then
		configuration.Amount = math.floor(v)
	end
	AmountBox.Text = tostring(configuration.Amount)
	configuration.SaveConfig()
end)
DistBox.FocusLost:Connect(function()
	local v = tonumber(DistBox.Text)
	if v and v > 0 then
		configuration.MaxDistance = math.clamp(v, 5, 100000)
	end
	DistBox.Text = tostring(configuration.MaxDistance)
	configuration.SaveConfig()
end)
ExpApproachBox.FocusLost:Connect(function()
	local v = tonumber(ExpApproachBox.Text)
	if v and v > 0 then
		configuration.ExpApproachDistance = math.clamp(v, 5, 100)
	end
	ExpApproachBox.Text = tostring(configuration.ExpApproachDistance)
	configuration.SaveConfig()
end)
IntervalBox.FocusLost:Connect(function()
	local v = tonumber(IntervalBox.Text)
	if v and v >= 0 then configuration.Interval = v end
	IntervalBox.Text = tostring(configuration.Interval)
	configuration.SaveConfig()
end)
MaxBox.FocusLost:Connect(function()
	local v = tonumber((MaxBox.Text:gsub(",", "")))
	if v and v > 0 then
		configuration.ExpGoal = v
		MaxLabel.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
	end
	MaxBox.Text = tostring(configuration.ExpGoal)
	configuration.SaveConfig()
end)

--==================================================
-- PLAYER / WHITELIST PANELS (unchanged structure)
--==================================================
local PlayerPanel = Instance.new("Frame")
PlayerPanel.Name = "PlayerListPanel"
PlayerPanel.Size = UDim2.fromScale(configuration.PlayerPanelWidthScale, configuration.PlayerPanelHeightScale)
PlayerPanel.Position = UDim2.fromScale(0.52, 0.19)
PlayerPanel.ZIndex = 90
PlayerPanel.BackgroundColor3 = BG
PlayerPanel.BorderSizePixel = 0
PlayerPanel.Visible = false
PlayerPanel.Parent = ScreenGui
Instance.new("UICorner", PlayerPanel).CornerRadius = UDim.new(0, 12)
local PlayerPanelStroke = Instance.new("UIStroke", PlayerPanel)
PlayerPanelStroke.Color = BORDER
PlayerPanelStroke.Thickness = 1
PlayerPanelStroke.Transparency = 0.35

-- Header bar matching main UI
local PlayerPanelHeader = Instance.new("Frame")
PlayerPanelHeader.Name = "Header"
PlayerPanelHeader.Size = UDim2.new(1, 0, 0, 44)
PlayerPanelHeader.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
PlayerPanelHeader.BorderSizePixel = 0
PlayerPanelHeader.ZIndex = 91
PlayerPanelHeader.Parent = PlayerPanel
Instance.new("UICorner", PlayerPanelHeader).CornerRadius = UDim.new(0, 12)

local PlayerPanelHeaderFix = Instance.new("Frame")
PlayerPanelHeaderFix.Size = UDim2.new(1, 0, 0, 16)
PlayerPanelHeaderFix.Position = UDim2.new(0, 0, 1, -16)
PlayerPanelHeaderFix.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
PlayerPanelHeaderFix.BorderSizePixel = 0
PlayerPanelHeaderFix.ZIndex = 91
PlayerPanelHeaderFix.Parent = PlayerPanelHeader

local PlayerPanelHeaderRule = Instance.new("Frame")
PlayerPanelHeaderRule.Size = UDim2.new(1, -20, 0, 1)
PlayerPanelHeaderRule.Position = UDim2.new(0, 10, 1, -1)
PlayerPanelHeaderRule.BackgroundColor3 = BORDER
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
PlayerPanelTitle.TextColor3 = TEXT
PlayerPanelTitle.TextSize = 14
PlayerPanelTitle.Font = Enum.Font.GothamBold
PlayerPanelTitle.TextXAlignment = Enum.TextXAlignment.Left
PlayerPanelTitle.Parent = PlayerPanelHeader

local PlayerPanelClose = Instance.new("TextButton")
PlayerPanelClose.Size = UDim2.fromOffset(26, 26)
PlayerPanelClose.Position = UDim2.new(1, -34, 0, 9)
PlayerPanelClose.ZIndex = 92
PlayerPanelClose.BackgroundColor3 = INPUT
PlayerPanelClose.BorderSizePixel = 0
PlayerPanelClose.Text = "×"
PlayerPanelClose.TextColor3 = TEXT
PlayerPanelClose.TextSize = 15
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
PlayerScroll.ScrollBarImageColor3 = MUTED
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
PlayerScrollLayout.Padding = UDim.new(0, 8)
PlayerScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
PlayerScrollLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

PlayerListButton.MouseButton1Click:Connect(function()
	configuration.PlayerPanelMode = "server"
	PlayerPanelTitle.Text = "Players in server"
	PlayerPanel.Visible = not PlayerPanel.Visible
	configuration.SetActionVisual(PlayerListButton, PlayerPanel.Visible and "Close list" or "Player list", PlayerPanel.Visible)
end)
PlayerPanelClose.MouseButton1Click:Connect(function()
	PlayerPanel.Visible = false
	configuration.PlayerPanelMode = "server"
	configuration.SetActionVisual(PlayerListButton, "Player list", false)
end)

FollowSelectButton.MouseButton1Click:Connect(function()
	configuration.PlayerPanelMode = "follow"
	PlayerPanelTitle.Text = "Choose player to follow"
	PlayerPanel.Visible = true
	configuration.SetActionVisual(PlayerListButton, "Player list", false)
end)

CombatTargetButton.MouseButton1Click:Connect(function()
	configuration.PlayerPanelMode = "attack"
	PlayerPanelTitle.Text = "Choose player to attack"
	PlayerPanel.Visible = true
	configuration.AutoAttackUseExpTarget = false
	configuration.UpdateExpMobTargetButton()
	configuration.AutoAttackMode = "Player"
	configuration.UpdateAutoAttackModeButtons()
	configuration.SaveConfig()
end)

StopFollowButton.MouseButton1Click:Connect(function()
	configuration.FollowPlayerUserId = nil
	local character = Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root then humanoid:MoveTo(root.Position) end
	configuration.SaveConfig()
	configuration.UpdateFollowButtons()
	if configuration.PlayerPanelMode == "follow" then PlayerPanel.Visible = true end
end)

configuration.WhitelistPanel = Instance.new("Frame")
configuration.WhitelistPanel.Name = "WhitelistPanel"
configuration.WhitelistPanel.Size = UDim2.fromScale(configuration.WhitelistPanelWidthScale, configuration.WhitelistPanelHeightScale)
configuration.WhitelistPanel.Position = UDim2.fromScale(0.04, 0.20)
configuration.WhitelistPanel.ZIndex = 90
configuration.WhitelistPanel.BackgroundColor3 = BG
configuration.WhitelistPanel.BorderSizePixel = 0
configuration.WhitelistPanel.Visible = false
configuration.WhitelistPanel.Parent = ScreenGui
Instance.new("UICorner", configuration.WhitelistPanel).CornerRadius = UDim.new(0, 12)
configuration.WhitelistPanelStroke = Instance.new("UIStroke", configuration.WhitelistPanel)
configuration.WhitelistPanelStroke.Color = BORDER
configuration.WhitelistPanelStroke.Thickness = 1
configuration.WhitelistPanelStroke.Transparency = 0.35

configuration.WhitelistHeader = Instance.new("Frame")
configuration.WhitelistHeader.Name = "Header"
configuration.WhitelistHeader.Size = UDim2.new(1, 0, 0, 44)
configuration.WhitelistHeader.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
configuration.WhitelistHeader.BorderSizePixel = 0
configuration.WhitelistHeader.ZIndex = 91
configuration.WhitelistHeader.Parent = configuration.WhitelistPanel
Instance.new("UICorner", configuration.WhitelistHeader).CornerRadius = UDim.new(0, 12)

configuration.WhitelistHeaderFix = Instance.new("Frame")
configuration.WhitelistHeaderFix.Size = UDim2.new(1, 0, 0, 16)
configuration.WhitelistHeaderFix.Position = UDim2.new(0, 0, 1, -16)
configuration.WhitelistHeaderFix.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
configuration.WhitelistHeaderFix.BorderSizePixel = 0
configuration.WhitelistHeaderFix.ZIndex = 91
configuration.WhitelistHeaderFix.Parent = configuration.WhitelistHeader

configuration.WhitelistHeaderRule = Instance.new("Frame")
configuration.WhitelistHeaderRule.Size = UDim2.new(1, -20, 0, 1)
configuration.WhitelistHeaderRule.Position = UDim2.new(0, 10, 1, -1)
configuration.WhitelistHeaderRule.BackgroundColor3 = BORDER
configuration.WhitelistHeaderRule.BackgroundTransparency = 0.4
configuration.WhitelistHeaderRule.BorderSizePixel = 0
configuration.WhitelistHeaderRule.ZIndex = 92
configuration.WhitelistHeaderRule.Parent = configuration.WhitelistHeader

configuration.WhitelistTitle = Instance.new("TextLabel")
configuration.WhitelistTitle.Size = UDim2.new(1, -20, 0, 22)
configuration.WhitelistTitle.Position = UDim2.fromOffset(14, 11)
configuration.WhitelistTitle.ZIndex = 92
configuration.WhitelistTitle.Active = true
configuration.WhitelistTitle.BackgroundTransparency = 1
configuration.WhitelistTitle.Text = "Whitelist by UserId"
configuration.WhitelistTitle.TextColor3 = TEXT
configuration.WhitelistTitle.TextSize = 14
configuration.WhitelistTitle.Font = Enum.Font.GothamBold
configuration.WhitelistTitle.TextXAlignment = Enum.TextXAlignment.Left
configuration.WhitelistTitle.Parent = configuration.WhitelistHeader

configuration.WhitelistInput = Instance.new("TextBox")
configuration.WhitelistInput.Size = UDim2.new(1, -112, 0, 34)
configuration.WhitelistInput.Position = UDim2.fromOffset(12, 54)
configuration.WhitelistInput.ZIndex = 91
configuration.WhitelistInput.BackgroundColor3 = INPUT
configuration.WhitelistInput.BorderSizePixel = 0
configuration.WhitelistInput.PlaceholderText = "Enter Player UserId"
configuration.WhitelistInput.Text = ""
configuration.WhitelistInput.TextColor3 = TEXT
configuration.WhitelistInput.PlaceholderColor3 = MUTED
configuration.WhitelistInput.TextSize = 12
configuration.WhitelistInput.Font = Enum.Font.Gotham
configuration.WhitelistInput.ClearTextOnFocus = false
configuration.WhitelistInput.Parent = configuration.WhitelistPanel
Instance.new("UICorner", configuration.WhitelistInput).CornerRadius = UDim.new(0, 8)

configuration.AddWhitelistButton = Instance.new("TextButton")
configuration.AddWhitelistButton.Size = UDim2.fromOffset(88, 34)
configuration.AddWhitelistButton.Position = UDim2.new(1, -100, 0, 54)
configuration.AddWhitelistButton.ZIndex = 91
configuration.AddWhitelistButton.BackgroundColor3 = ACCENT_DIM
configuration.AddWhitelistButton.BorderSizePixel = 0
configuration.AddWhitelistButton.Text = "Add ID"
configuration.AddWhitelistButton.TextColor3 = ACCENT
configuration.AddWhitelistButton.TextSize = 12
configuration.AddWhitelistButton.Font = Enum.Font.GothamBold
configuration.AddWhitelistButton.Parent = configuration.WhitelistPanel
Instance.new("UICorner", configuration.AddWhitelistButton).CornerRadius = UDim.new(0, 8)

configuration.WhitelistScroll = Instance.new("ScrollingFrame")
configuration.WhitelistScroll.Size = UDim2.new(1, -20, 1, -102)
configuration.WhitelistScroll.Position = UDim2.fromOffset(10, 96)
configuration.WhitelistScroll.ZIndex = 91
configuration.WhitelistScroll.BackgroundTransparency = 1
configuration.WhitelistScroll.BorderSizePixel = 0
configuration.WhitelistScroll.ScrollBarThickness = 3
configuration.WhitelistScroll.ScrollBarImageColor3 = MUTED
configuration.WhitelistScroll.CanvasSize = UDim2.new()
configuration.WhitelistScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
configuration.WhitelistScroll.ScrollingDirection = Enum.ScrollingDirection.Y
configuration.WhitelistScroll.Parent = configuration.WhitelistPanel

configuration.WhitelistLayout = Instance.new("UIListLayout", configuration.WhitelistScroll)
configuration.WhitelistLayout.Padding = UDim.new(0, 6)
configuration.WhitelistLayout.SortOrder = Enum.SortOrder.LayoutOrder
configuration.WhitelistLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

function configuration.MakeDraggable(panel, handle)
	local dragging = false
	local dragStart
	local startPosition
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = panel.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
			if viewport then
				panel.Position = UDim2.fromScale(
					math.clamp(startPosition.X.Scale + delta.X / viewport.X, 0, 1 - panel.Size.X.Scale),
					math.clamp(startPosition.Y.Scale + delta.Y / viewport.Y, 0, 1 - panel.Size.Y.Scale)
				)
			end
		end
	end)
end

configuration.MakeDraggable(PlayerPanel, PlayerPanelHeader)
configuration.MakeDraggable(configuration.WhitelistPanel, configuration.WhitelistHeader)

function configuration.MakeResizable(panel, name, minWidth, minHeight, onReleased)
	local handle = Instance.new("TextButton")
	handle.Name = name .. "ResizeHandle"
	handle.Size = UDim2.fromScale(0.07, 0.05)
	handle.AnchorPoint = Vector2.new(1, 1)
	handle.Position = UDim2.fromScale(1, 1)
	handle.ZIndex = 95
	handle.BackgroundColor3 = CARD
	handle.BackgroundTransparency = 0.1
	handle.BorderSizePixel = 0
	handle.Text = "◢"
	handle.TextColor3 = MUTED
	handle.TextScaled = true
	handle.Font = Enum.Font.GothamBold
	handle.Parent = panel
	Instance.new("UICorner", handle).CornerRadius = UDim.new(0, 5)

	local resizing = false
	local startPoint
	local startWidth, startHeight
	handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		resizing = true
		startPoint = input.Position
		startWidth, startHeight = panel.Size.X.Scale, panel.Size.Y.Scale
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				resizing = false
				if onReleased then onReleased(panel.Size.X.Scale, panel.Size.Y.Scale) end
			end
		end)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing or (input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch) then return end
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		if not viewport then return end
		local delta = input.Position - startPoint
		local maxWidth = math.max(minWidth, math.min(0.8, 1 - panel.Position.X.Scale))
		local maxHeight = math.max(minHeight, math.min(0.9, 1 - panel.Position.Y.Scale))
		panel.Size = UDim2.fromScale(
			math.clamp(startWidth + delta.X / viewport.X, minWidth, maxWidth),
			math.clamp(startHeight + delta.Y / viewport.Y, minHeight, maxHeight)
		)
	end)
end

configuration.MakeResizable(PlayerPanel, "PlayerPanel", 0.28, 0.35, function(width, height)
	configuration.PlayerPanelWidthScale, configuration.PlayerPanelHeightScale = width, height
	configuration.SaveConfig()
end)
configuration.MakeResizable(configuration.WhitelistPanel, "WhitelistPanel", 0.26, 0.32, function(width, height)
	configuration.WhitelistPanelWidthScale, configuration.WhitelistPanelHeightScale = width, height
	configuration.SaveConfig()
end)

function configuration.RefreshWhitelist()
	for _, child in ipairs(configuration.WhitelistScroll:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	local ids = {}
	for userId in pairs(configuration.WhitelistIds) do table.insert(ids, userId) end
	table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
	for order, userId in ipairs(ids) do
		local playerName = ""
		for _, onlinePlayer in ipairs(Players:GetPlayers()) do
			if tostring(onlinePlayer.UserId) == userId then
				playerName = "  @" .. onlinePlayer.Name
				break
			end
		end

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -12, 0, 32)
		row.LayoutOrder = order
		row.ZIndex = 92
		row.BackgroundTransparency = 1
		row.Parent = configuration.WhitelistScroll

		local idLabel = Instance.new("TextLabel")
		idLabel.Size = UDim2.new(1, -48, 1, 0)
		idLabel.ZIndex = 93
		idLabel.BackgroundTransparency = 1
		idLabel.Text = userId .. playerName
		idLabel.TextColor3 = TEXT
		idLabel.TextSize = 11
		idLabel.Font = Enum.Font.Gotham
		idLabel.TextXAlignment = Enum.TextXAlignment.Left
		idLabel.TextTruncate = Enum.TextTruncate.AtEnd
		idLabel.Parent = row

		local removeButton = Instance.new("TextButton")
		removeButton.Size = UDim2.fromOffset(36, 26)
		removeButton.Position = UDim2.new(1, -40, 0.5, -13)
		removeButton.ZIndex = 93
		removeButton.BackgroundColor3 = Color3.fromRGB(60, 30, 35)
		removeButton.BorderSizePixel = 0
		removeButton.Text = "×"
		removeButton.TextColor3 = RED
		removeButton.TextSize = 14
		removeButton.Font = Enum.Font.GothamBold
		removeButton.Parent = row
		Instance.new("UICorner", removeButton).CornerRadius = UDim.new(0, 5)
		removeButton.MouseButton1Click:Connect(function()
			configuration.WhitelistIds[userId] = nil
			configuration.SaveConfig()
			configuration.RefreshWhitelist()
		end)
	end
end

WhitelistButton.MouseButton1Click:Connect(function()
	configuration.WhitelistPanel.Visible = not configuration.WhitelistPanel.Visible
	if configuration.WhitelistPanel.Visible then configuration.RefreshWhitelist() end
end)

function configuration.AddWhitelistId()
	local idText = configuration.WhitelistInput.Text:match("^%s*(%d+)%s*$")
	if not idText then
		configuration.WhitelistInput.Text = ""
		configuration.WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	local userId = idText:gsub("^0+", "")
	if userId == "" then
		configuration.WhitelistInput.Text = ""
		configuration.WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	configuration.WhitelistIds[userId] = true
	configuration.WhitelistInput.Text = ""
	configuration.WhitelistInput.PlaceholderText = "Enter Player UserId"
	configuration.SaveConfig()
	configuration.RefreshWhitelist()
end

configuration.AddWhitelistButton.MouseButton1Click:Connect(configuration.AddWhitelistId)
configuration.WhitelistInput.FocusLost:Connect(function(enterPressed)
	if enterPressed then configuration.AddWhitelistId() end
end)

AlarmOverlay = Instance.new("Frame")
AlarmOverlay.Name = "FullScreenAlarm"
AlarmOverlay.Size = UDim2.fromScale(1, 1)
AlarmOverlay.BackgroundColor3 = RED
AlarmOverlay.BackgroundTransparency = 0.35
AlarmOverlay.BorderSizePixel = 0
AlarmOverlay.Visible = false
AlarmOverlay.Active = false
AlarmOverlay.ZIndex = 100
AlarmOverlay.Parent = ScreenGui

configuration.AlarmText = Instance.new("TextLabel")
configuration.AlarmText.Size = UDim2.new(1, 0, 0, 72)
configuration.AlarmText.Position = UDim2.new(0, 0, 0.5, -36)
configuration.AlarmText.BackgroundTransparency = 1
configuration.AlarmText.Text = ""
configuration.AlarmText.TextColor3 = Color3.new(1, 1, 1)
configuration.AlarmText.TextStrokeTransparency = 0.15
configuration.AlarmText.TextSize = 30
configuration.AlarmText.Font = Enum.Font.GothamBlack
configuration.AlarmText.ZIndex = 101
configuration.AlarmText.Parent = AlarmOverlay

configuration.PlayerEspLayer = Instance.new("Frame")
configuration.PlayerEspLayer.Name = "PlayerESPLayer"
configuration.PlayerEspLayer.Size = UDim2.fromScale(1, 1)
configuration.PlayerEspLayer.BackgroundTransparency = 1
configuration.PlayerEspLayer.Active = false
configuration.PlayerEspLayer.ZIndex = 0
configuration.PlayerEspLayer.Parent = ScreenGui

local ResizeHandle = Instance.new("TextButton")
ResizeHandle.Name = "ResizeHandle"
ResizeHandle.Visible = not configuration.IsMinimized
ResizeHandle.Size = UDim2.fromOffset(18, 18)
ResizeHandle.AnchorPoint = Vector2.new(1, 1)
ResizeHandle.Position = UDim2.new(1, -5, 1, -5)
ResizeHandle.ZIndex = 92
ResizeHandle.BackgroundColor3 = CARD
ResizeHandle.BackgroundTransparency = 0.1
ResizeHandle.BorderSizePixel = 0
ResizeHandle.Text = "◢"
ResizeHandle.TextColor3 = MUTED
ResizeHandle.TextSize = 11
ResizeHandle.Font = Enum.Font.GothamBold
ResizeHandle.Parent = Main
Instance.new("UICorner", ResizeHandle).CornerRadius = UDim.new(0, 4)

local Resizing, ResizeStart, ResizeStartSize = false, nil, nil
ResizeHandle.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		Resizing = true
		ResizeStart = input.Position
		ResizeStartSize = Vector2.new(Main.Size.X.Scale, Main.Size.Y.Scale)
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				Resizing = false
				configuration.SaveConfig()
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not Resizing then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local viewport = camera.ViewportSize
	local delta = input.Position - ResizeStart
	local maxWidth = math.max(0.2, math.min(1400 / viewport.X, 1 - Main.Position.X.Scale, 1 - 16 / viewport.X))
	local minWidth = math.min(640 / viewport.X, maxWidth)
	local maxHeight = math.max(0.4, math.min(900 / viewport.Y, 1 - Main.Position.Y.Scale, 1 - 16 / viewport.Y))
	local minHeight = math.min(480 / viewport.Y, maxHeight)
	configuration.MainWidthScale = math.clamp(ResizeStartSize.X + delta.X / viewport.X, minWidth, maxWidth)
	if not configuration.IsMinimized then
		configuration.MainHeightScale = math.clamp(ResizeStartSize.Y + delta.Y / viewport.Y, minHeight, maxHeight)
	end
	configuration.MainWindowInitialized = true
	configuration.ApplyResponsiveMainSize()
end)

--==================================================
-- STATUS HELPERS
--==================================================
function configuration.PauseTimer()
	if not configuration.IsPaused and configuration.LastTarget then
		configuration.AccumulatedTime = configuration.AccumulatedTime + (os.clock() - configuration.TargetStartTime)
		configuration.IsPaused = true
	end
end

function configuration.SetIdle(finishCurrentExpTarget)
	local finishTarget = finishCurrentExpTarget and configuration.CurrentTarget
	if finishTarget and configuration.Combat.IsLivingMob(finishTarget) then
		configuration.ExpFinishTarget = finishTarget
		configuration.AutoAttackPinnedMob = finishTarget
		configuration.CombatTargetMob = finishTarget
	else
		configuration.ExpFinishTarget = nil
	end
	if not configuration.AlertCombatPending then
		configuration.ExpRetaliationTarget = nil
	end
	if configuration.Farming and not configuration.AlertCombatPending and configuration.AutoSkillEnabled
		and configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
		configuration.AutoAttackPinnedMob = configuration.CurrentTarget
		configuration.CombatTargetMob = configuration.CurrentTarget
	end
	configuration.Farming = false
	if configuration.StopExpMovement then configuration.StopExpMovement() end
	configuration.PauseTimer()
	StartBtn.Text = "Start"
	StartBtn.BackgroundColor3 = ACCENT
	Status.Text = "OFF"
	Status.TextColor3 = RED
	Status.BackgroundColor3 = RED_DIM
	StateLabel.Text = configuration.ExpFinishTarget and "Finishing EXP target" or "Stopped"
	MiniState.Text = configuration.ExpFinishTarget and "EXP paused — killing the locked target" or "Stopped"
	TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime)
			MiniTime.Text = TimeLabel.Text
end

function configuration.SetRunning()
	if configuration.AlertCombatPending or configuration.AlertCombatHold or configuration.AlertCombatBlockReady then return end
	configuration.EmergencyStopActive = false
	if configuration.UpdateEmergencyStopButton then configuration.UpdateEmergencyStopButton() end
	configuration.Farming = true
	configuration.ExpMaxCombatTarget = nil
	configuration.ExpFinishTarget = nil
	configuration.AutoAttackPinnedMob = nil
	configuration.IsPaused = false
	configuration.SessionExpGained = 0
	configuration.SessionFarmSeconds = 0
	configuration.NoProgressCycles = 0
	SessionLabel.Text = "Session: +0 EXP / 00:00:00 / 0 EXP/h"
	configuration.RecentCycle = "รอบล่าสุด  -"
	RecentCycleLabel.Text = configuration.RecentCycle
	if configuration.LastTarget then
		configuration.TargetStartTime = os.clock()
	end
	StartBtn.Text = "Stop"
	StartBtn.BackgroundColor3 = RED
	Status.Text = "ON"
	Status.TextColor3 = GREEN
	Status.BackgroundColor3 = GREEN_DIM
	StateLabel.Text = "Searching..."
	MiniState.Text = "Searching..."
end

StartBtn.MouseButton1Click:Connect(function()
	if configuration.Farming then
		configuration.SetIdle(true)
	else
		configuration.SetRunning()
	end
end)

Status.MouseButton1Click:Connect(function()
	if configuration.Farming then
		configuration.SetIdle(true)
	else
		configuration.SetRunning()
	end
end)

--==================================================
-- FIND TARGET
--==================================================
function configuration.FindTarget()
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
		if exp.Value >= configuration.ExpGoal then
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
		if d > configuration.MaxDistance then
			continue
		end
		local remaining = configuration.ExpGoal - exp.Value
		-- Prefer closer targets; break distance ties with less remaining EXP (finishes faster).
		if d < bestDist - 0.5 or (math.abs(d - bestDist) <= 0.5 and remaining < bestRemaining) then
			bestDist = d
			bestRemaining = remaining
			best = mob
		end
	end
	return best
end

function configuration.Combat.IsLivingMob(mob)
	if not mob or not mob:IsDescendantOf(MobsFolder) then return false end
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health > 0
end

function configuration.Combat.GetWeaponEquipState(character)
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

function configuration.Combat.FindNearestCombatMob(localRoot, maxDistance, bossesOnly)
	MobCache_Rebuild(false)
	local searchDistance = maxDistance or configuration.AutoAttackSearchRange
	local now = os.clock()
	local searchCache = bossesOnly and MobCache.SearchCaches.Boss or MobCache.SearchCaches.Mob
	if searchCache.Range == searchDistance and now - searchCache.LastSearchAt < 0.25 then
		local cachedMob = searchCache.Mob
		if not cachedMob then return nil, nil, nil end
		local cachedRoot = cachedMob.PrimaryPart or cachedMob:FindFirstChild("HumanoidRootPart")
		if configuration.Combat.IsLivingMob(cachedMob) and not configuration.CombatSystem.IsTargetCoolingDown(cachedMob)
			and cachedRoot and cachedRoot:IsA("BasePart") then
			local cachedDistance = (localRoot.Position - cachedRoot.Position).Magnitude
			if cachedDistance <= searchDistance then return cachedMob, cachedRoot, cachedDistance end
		end
	end
	local bestMob, bestRoot, bestDistance = nil, nil, searchDistance
	for _, entry in ipairs(MobCache.List) do
		local mob, mobRoot, humanoid = entry.Mob, entry.Root, entry.Humanoid
		if not mobRoot or not mobRoot.Parent then
			mobRoot = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
			entry.Root = mobRoot
		end
		if not humanoid or not humanoid.Parent then
			humanoid = mob:FindFirstChildOfClass("Humanoid")
			entry.Humanoid = humanoid
		end
		if mobRoot and mobRoot:IsA("BasePart") and (not humanoid or humanoid.Health > 0)
			and not configuration.CombatSystem.IsTargetCoolingDown(mob)
			and (not bossesOnly or entry.IsBoss == true) then
			local distance = (localRoot.Position - mobRoot.Position).Magnitude
			if distance <= bestDistance then
				bestMob, bestRoot, bestDistance = mob, mobRoot, distance
			end
		end
	end
	searchCache.LastSearchAt = now
	searchCache.Range = searchDistance
	searchCache.Mob = bestMob
	return bestMob, bestRoot, bestDistance
end

function configuration.Combat.FindCombatPlayer(userId)
	local targetPlayer = userId and Players:GetPlayerByUserId(tonumber(userId))
	if not targetPlayer or targetPlayer == Player or configuration.IsWhitelisted(targetPlayer) then return nil, nil end
	local character = targetPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not targetRoot or (humanoid and humanoid.Health <= 0) then return nil, nil end
	return targetPlayer, targetRoot
end

function configuration.Combat.FindAutoAttackTarget(localRoot)
	local function horizontalDistance(a, b)
		local offset = b - a
		return Vector3.new(offset.X, 0, offset.Z).Magnitude
	end
	-- Alert and EXP-cap handling are deliberate exceptions to list selection:
	-- they may only attack the active EXP mob and always take priority.
	local priorityMob = configuration.AlertCombatPending and configuration.AlertCombatTarget
		or configuration.ExpMaxCombatTarget
		or configuration.ExpRetaliationTarget
	if priorityMob and configuration.Combat.IsLivingMob(priorityMob) then
		local priorityRoot = priorityMob.PrimaryPart or priorityMob:FindFirstChild("HumanoidRootPart")
		if priorityRoot and priorityRoot:IsA("BasePart") then
			return "Mob", priorityMob, priorityRoot, horizontalDistance(localRoot.Position, priorityRoot.Position)
		end
	end
	local selectedMob = configuration.SelectedCombatMob
	if not selectedMob or not selectedMob:IsDescendantOf(MobsFolder)
		or not configuration.Combat.IsLivingMob(selectedMob) then
		configuration.SelectedCombatMob = nil
		configuration.CombatTargetMob = nil
		configuration.AutoAttackPinnedMob = nil
		return nil
	end
	-- Temporary navigation cooldowns must not erase the user's list selection.
	if configuration.CombatSystem.IsTargetCoolingDown(selectedMob) then return nil end
	local targetRoot = selectedMob.PrimaryPart or selectedMob:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then return nil end
	local distance = horizontalDistance(localRoot.Position, targetRoot.Position)
	if distance > configuration.AutoAttackSearchRange then return nil end
	return "Mob", selectedMob, targetRoot, distance
end

function configuration.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, currentExp)
	local elapsed = math.max(os.clock() - cycleStartTime, 0.001)
	local gained = currentExp - cycleStartExp
	configuration.RecentCycle = string.format("Last: +%s EXP / %.2fs / %d calls", configuration.FormatNumber(gained), elapsed, callsSent)
	RecentCycleLabel.Text = configuration.RecentCycle
	configuration.SessionExpGained += math.max(gained, 0)
	configuration.SessionFarmSeconds += elapsed
	local sessionRate = configuration.SessionFarmSeconds > 0 and (configuration.SessionExpGained / configuration.SessionFarmSeconds) * 3600 or 0
	SessionLabel.Text = string.format("Session: +%s EXP / %s / %s EXP/h", configuration.FormatNumber(configuration.SessionExpGained), configuration.FormatTime(configuration.SessionFarmSeconds), configuration.FormatNumber(sessionRate))
	if callsSent > 0 and gained <= 0 then
		configuration.NoProgressCycles += 1
	else
		configuration.NoProgressCycles = 0
	end
end

--==================================================
-- FARM LOOP (ยิงไม่เกิน Max)
--==================================================
task.spawn(function()
	local expMoveState = { Active = false, Goal = nil, LastMoveAt = 0 }
	local chasingExpTarget = nil
	configuration.StopExpMovement = function()
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
	local watchedHealthTarget = nil
	local lastObservedTargetHealth = nil
	local healthChangedConnection = nil
	local adaptiveYield = 0
	local lastCycleGain = 0
	local lastCycleCalls = 0
	-- Must close in once per target before the first shot; after that, keep firing while walking back.
	local engagedFireTarget = nil
	local function StartExpRetaliation(mob, currentHealth)
		configuration.ExpRetaliationTarget = mob
		configuration.AutoAttackPinnedMob = mob
		configuration.CombatTargetMob = mob
		lastObservedTargetHealth = currentHealth
		StateLabel.Text = "EXP target hit"
		MiniState.Text = "Attacking the damaged EXP target until it dies"
	end
	while true do
		if not configuration.Farming or configuration.EmergencyStopActive then
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

		local target = configuration.CurrentTarget
		local retaliationTarget = configuration.ExpRetaliationTarget
		if retaliationTarget then
			if configuration.Combat.IsLivingMob(retaliationTarget) then
				StateLabel.Text = "EXP target hit"
				MiniState.Text = "Attacking the damaged EXP target until it dies"
				task.wait(0.1)
				continue
			end
			configuration.ExpRetaliationTarget = nil
			if configuration.AutoAttackPinnedMob == retaliationTarget then
				configuration.AutoAttackPinnedMob = nil
			end
			if configuration.CombatTargetMob == retaliationTarget then
				configuration.CombatTargetMob = nil
			end
			watchedHealthTarget = nil
			lastObservedTargetHealth = nil
			if healthChangedConnection then
				healthChangedConnection:Disconnect()
				healthChangedConnection = nil
			end
		end

		if target and configuration.Combat.IsLivingMob(target) then
			-- ยึดตัวเดิม
		else
			if chasingExpTarget or expMoveState.Active then
				local character = Player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
				expMoveState.Active = false
				expMoveState.Goal = nil
			end
			if configuration.ExpMaxCombatTarget == target then
				configuration.ExpMaxCombatTarget = nil
			end
			configuration.ClearBillboard()
			configuration.CurrentTarget = nil
			engagedFireTarget = nil
			target = configuration.FindTarget()
			configuration.CurrentTarget = target

			if not target then
				TargetLabel.Text = "No target"
				ExpLabel.Text = "-"
				MiniExp.Text = "-"
				DistLabel.Text = "Dist  -"
				StateLabel.Text = "Searching..."
				MiniState.Text = "Searching within the configured radius"
				RateLabel.Text = "Rate -"
				configuration.PauseTimer()
				task.wait(0.5)
				continue
			end

			local cfg = target:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			configuration.AttachBillboard(target, exp and tonumber(exp.Value) or 0)

			-- เริ่มจับเวลา rate ของมอนตัวนี้
			configuration.SessionStartEXP = exp and tonumber(exp.Value) or 0
			configuration.SessionStartTime = os.clock()
		end

		local cfg = target:FindFirstChild("Config")
		local exp = cfg and cfg:FindFirstChild("EXP")
		if not exp then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for target EXP data"
			task.wait(0.25)
			continue
		end

		local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
		if watchedHealthTarget ~= target then
			if healthChangedConnection then healthChangedConnection:Disconnect() end
			watchedHealthTarget = target
			lastObservedTargetHealth = targetHumanoid and targetHumanoid.Health or nil
			healthChangedConnection = nil
			if targetHumanoid then
				healthChangedConnection = targetHumanoid.HealthChanged:Connect(function(currentHealth)
					if configuration.Farming and not configuration.EmergencyStopActive
						and configuration.ExpTargetRetaliationEnabled and lastObservedTargetHealth
						and currentHealth < lastObservedTargetHealth then
						StartExpRetaliation(target, currentHealth)
					end
					lastObservedTargetHealth = currentHealth
				end)
			end
		elseif targetHumanoid then
			if configuration.ExpTargetRetaliationEnabled
				and lastObservedTargetHealth and targetHumanoid.Health < lastObservedTargetHealth then
				StartExpRetaliation(target, targetHumanoid.Health)
				task.wait(0.05)
				continue
			else
				lastObservedTargetHealth = targetHumanoid.Health
			end
		else
			lastObservedTargetHealth = nil
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

		if exp.Value < configuration.ExpGoal and now - lastExpProgressAt >= 20 then
			local character = Player.Character
			local playerGui = Player:FindFirstChildOfClass("PlayerGui")
			local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
			local _, needsEquip = configuration.Combat.GetWeaponEquipState(character)
			StateLabel.Text = needsEquip and "Checking weapon" or "EXP stalled"
			MiniState.Text = needsEquip and "No EXP change; checking weapon and keeping target" or "No EXP change; retrying same target"
			if needsEquip and inputFunction and inputFunction:IsA("BindableFunction") then
				pcall(function()
					inputFunction:Invoke("EquipButton", Enum.UserInputState.Begin)
				end)
			end
			lastExpProgressAt = now
			local recoveryEndsAt = now + 3
			while configuration.Farming and not configuration.EmergencyStopActive and os.clock() < recoveryEndsAt do
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
		ExpLabel.Text = configuration.FormatNumber(expNow)
		MaxLabel.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
		DistLabel.Text = "Dist  " .. string.format("%.1f", dist)
		-- Keep marker alive/updated even if the host part respawned.
		if not configuration.CurrentBillboard or not configuration.CurrentBillboard.Parent then
			configuration.AttachBillboard(target, expNow)
		else
			configuration.UpdateBillboardText(expNow, expNow >= configuration.ExpGoal)
		end

		-- Move only when outside firing range. Holding still inside range avoids orbiting away from the mob.
		if configuration.ExpAutoApproachEnabled and exp.Value < configuration.ExpGoal and root and mroot
			and configuration.ExpRetaliationTarget ~= target
			and configuration.ExpMaxCombatTarget ~= target
			and not (configuration.PendingServerHop and configuration.ServerHopKillTarget == target)
			and not (configuration.AlertCombatPending and configuration.AlertCombatTarget == target) then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local standoff = configuration.ExpApproachDistance
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
		if exp.Value >= configuration.ExpGoal then
			configuration.ExpMaxCombatTarget = target
			StateLabel.Text = "EXP max - waiting for mob to die"
			MiniState.Text = "Waiting for mob to die"
			configuration.UpdateBillboardText(exp.Value, true)
			Bar.Size = UDim2.fromScale(1, 1)
			PercentLabel.Text = "100%"
			task.wait(0.2)
			continue
		end

		if configuration.ExpAutoApproachEnabled and dist > configuration.ExpApproachDistance + 1 then
			StateLabel.Text = "Moving"
			MiniState.Text = "Walking to locked EXP target"
		elseif configuration.NoProgressCycles >= 2 then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for EXP to update on this target"
		else
			StateLabel.Text = "Firing"
			MiniState.Text = "Sending EXP to locked target"
		end
		configuration.UpdateBillboardText(exp.Value, false)

		-- Adaptive fire: scale batch + yield from recent progress.
		local remaining = configuration.ExpGoal - exp.Value
		local baseAmount = configuration.Amount
		if configuration.NoProgressCycles >= 2 then
			baseAmount = math.max(200, math.floor(baseAmount * 0.35))
		elseif lastCycleCalls > 0 and lastCycleGain <= 0 then
			baseAmount = math.max(300, math.floor(baseAmount * 0.55))
		elseif lastCycleCalls > 0 and lastCycleGain >= lastCycleCalls * 0.6 then
			baseAmount = math.min(configuration.Amount, math.floor(baseAmount * 1.15))
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
			if not configuration.Farming or configuration.EmergencyStopActive then break end
			if not target:IsDescendantOf(MobsFolder) then break end
			if configuration.ExpRetaliationTarget == target
				or configuration.ExpMaxCombatTarget == target
				or (configuration.PendingServerHop and configuration.ServerHopKillTarget == target)
				or (configuration.AlertCombatPending and configuration.AlertCombatTarget == target) then
				break
			end
			if exp.Value >= configuration.ExpGoal then break end
			local firingHumanoid = target:FindFirstChildOfClass("Humanoid")
			if configuration.ExpTargetRetaliationEnabled and watchedHealthTarget == target
				and firingHumanoid and lastObservedTargetHealth
				and firingHumanoid.Health < lastObservedTargetHealth then
				StartExpRetaliation(target, firingHumanoid.Health)
				break
			elseif firingHumanoid then
				lastObservedTargetHealth = firingHumanoid.Health
			end

			local firingCharacter = Player.Character
			local firingRoot = firingCharacter and firingCharacter:FindFirstChild("HumanoidRootPart")
			local firingMobRoot = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
			local firingDistance = firingRoot and firingMobRoot
				and (firingRoot.Position - firingMobRoot.Position).Magnitude or math.huge
			local inApproach = not configuration.ExpAutoApproachEnabled
				or firingDistance <= configuration.ExpApproachDistance + 0.75
			local hasEngaged = engagedFireTarget == target

			-- EXP target movement is opt-in; Combat can still approach the target
			-- separately for Alert or Max handling.
			if configuration.ExpAutoApproachEnabled and firingRoot and firingMobRoot and not inApproach then
				local moveHumanoid = firingCharacter and firingCharacter:FindFirstChildOfClass("Humanoid")
				if moveHumanoid then
					local goal = OrbitApproachPoint(firingRoot, firingMobRoot, configuration.ExpApproachDistance)
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
					MiniState.Text = string.format("Approach target once (%.0f / %.0f studs)", firingDistance, configuration.ExpApproachDistance)
					task.wait(0.08)
					continue
				end
				engagedFireTarget = target
				hasEngaged = true
			end

			-- After engaged: keep firing even if range is briefly lost; only bail if way outside search radius.
			if firingDistance > configuration.MaxDistance + 25 then
				StateLabel.Text = configuration.ExpAutoApproachEnabled and "Moving" or "Waiting"
				MiniState.Text = configuration.ExpAutoApproachEnabled
					and string.format("Too far (%.0f); walking back into %.0f studs", firingDistance, configuration.MaxDistance)
					or string.format("Target too far (%.0f); waiting within %.0f studs", firingDistance, configuration.MaxDistance)
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

			-- Sync Auto Attack's mob target to EXP when the target toggle is enabled.
			if configuration.AutoAttackUseExpTarget then
				configuration.AutoAttackPinnedMob = target
				configuration.CombatTargetMob = target
			end
			InitClashing:FireServer(2, exp)
			callsSent += 1

			-- Adaptive throttle near max / after stalled cycles / periodic yield for replicate.
			if exp.Value >= configuration.ExpGoal - 200 then
				task.wait(0.025 + adaptiveYield)
			elseif configuration.NoProgressCycles >= 2 and callsSent % 15 == 0 then
				task.wait(0.03 + adaptiveYield)
			elseif callsSent % batchYieldEvery == 0 then
				task.wait(math.max(0, adaptiveYield))
			end
		end

		if not configuration.Farming or configuration.EmergencyStopActive then continue end

		if not target:IsDescendantOf(MobsFolder) then
			configuration.ClearBillboard()
			configuration.CurrentTarget = nil
			task.wait(0.05)
			continue
		end

		if exp.Value >= configuration.ExpGoal then
			configuration.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, exp.Value)
			lastCycleGain = math.max(0, exp.Value - cycleStartExp)
			lastCycleCalls = callsSent
			adaptiveYield = math.max(0, adaptiveYield - 0.004)
			configuration.ExpMaxCombatTarget = target
			StateLabel.Text = "EXP max - waiting for mob to die"
			MiniState.Text = "Waiting for mob to die"
			configuration.UpdateBillboardText(exp.Value, true)
			Bar.Size = UDim2.fromScale(1, 1)
			PercentLabel.Text = "100%"
			task.wait(0.2)
			continue
		end

		-- รอ EXP ขึ้น (timeout สั้นลงเมื่อใกล้ Max)
		if target:IsDescendantOf(MobsFolder) then
			StateLabel.Text = "Waiting"
			MiniState.Text = "Waiting for EXP update on locked target"
			local expected = math.min(cycleStartExp + callsSent, configuration.ExpGoal)
			local startWait = os.clock()
			local maxWait = (exp.Value >= configuration.ExpGoal - 500) and 2 or 5

			while configuration.Farming and not configuration.EmergencyStopActive and exp.Parent and exp.Value < expected do
				if not target:IsDescendantOf(MobsFolder) then break end
				if exp.Value >= configuration.ExpGoal then break end
				if os.clock() - startWait > maxWait then break end
				task.wait(0.05)
			end
		end

		configuration.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, exp.Value)
		lastCycleGain = math.max(0, exp.Value - cycleStartExp)
		lastCycleCalls = callsSent
		if callsSent > 0 and lastCycleGain <= 0 then
			adaptiveYield = math.min(0.04, adaptiveYield + 0.008)
		elseif lastCycleGain > 0 then
			adaptiveYield = math.max(0, adaptiveYield - 0.006)
		end

		if configuration.Farming then
			if not target:IsDescendantOf(MobsFolder) then
				configuration.ClearBillboard()
				configuration.CurrentTarget = nil
				task.wait(0.05)
				continue
			end
			if exp.Value >= configuration.ExpGoal then
				configuration.PauseTimer()
				continue
			end
			StateLabel.Text = configuration.NoProgressCycles >= 2 and "Waiting" or "Interval"
			MiniState.Text = configuration.NoProgressCycles >= 2
				and "EXP did not update; keeping the same target"
				or ("Waiting " .. tostring(configuration.Interval) .. "s before next cycle")
			task.wait(configuration.Interval)
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
	local attackMoveState = { Active = false, Goal = nil, LastMoveAt = 0, Target = nil, ApproachActive = false }
	local chasingMob = false
	local lastFinishHandoffTarget = nil
	local lastRetaliationAttackTarget = nil
	local lastUiSync = 0
	local function FaceTargetWhenStill(root, targetPosition, alpha)
		if not root or not targetPosition then return end
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		-- Humanoid.AutoRotate already faces movement input. Writing CFrame while
		-- walking fights that rotation and makes the character twitch toward mobs.
		if humanoid and humanoid.MoveDirection.Magnitude > 0.05 then return end
		configuration.CombatSystem.FaceTargetSmooth(root, targetPosition, alpha)
	end
	while true do
	local canCombatDuringExp = configuration.Farming
			and (configuration.ExpMaxCombatTarget ~= nil or configuration.ExpRetaliationTarget ~= nil
				or configuration.PendingServerHop)
		local forceFinishExp = configuration.PendingServerHop and configuration.ServerHopKillTarget ~= nil
		local finishStoppedExp = configuration.ExpFinishTarget ~= nil
		local priorityCombat = configuration.AlertCombatPending or configuration.ExpMaxCombatTarget ~= nil
			or configuration.ExpRetaliationTarget ~= nil or configuration.PendingServerHop
		if not configuration.EmergencyStopActive
			and (configuration.AutoAttackEnabled or configuration.AutoSkillEnabled or priorityCombat)
			and not configuration.AlertCombatHold
			and (not configuration.Farming or canCombatDuringExp or forceFinishExp)
			and not configuration.AlertCombatBlockReady then
			local character = Player.Character
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			local targetKind, target, targetRoot, distance
			if localRoot then
				targetKind, target, targetRoot, distance = configuration.Combat.FindAutoAttackTarget(localRoot)
			end
			if target == configuration.ExpRetaliationTarget and target then
				if lastRetaliationAttackTarget ~= target then
					lastAttackAt = os.clock() - configuration.AutoAttackInterval
					lastRetaliationAttackTarget = target
				end
			else
				lastRetaliationAttackTarget = nil
			end
			if target and targetRoot then
				if target == configuration.ExpFinishTarget and target ~= lastFinishHandoffTarget then
					configuration.CombatSystem.ResetNavigationState(attackMoveState)
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					attackMoveState.LastMoveAt = 0
					attackMoveState.Target = nil
					attackMoveState.ApproachActive = (distance or math.huge) > configuration.AutoAttackRange
					chasingMob = false
					lastFinishHandoffTarget = target
				elseif target ~= configuration.ExpFinishTarget then
					lastFinishHandoffTarget = nil
				end
				local mobEngageRange = math.min(
					configuration.AutoAttackRange,
					math.max(7, configuration.AutoAttackStandoff + 3)
				)
				local attackRange = targetKind == "Mob" and mobEngageRange or configuration.AutoAttackRange
				local evadingEnemySkill = targetKind == "Mob"
					and configuration.CombatSystem.ShouldEvadeTarget(target, localRoot and localRoot.Position)
				if attackMoveState.Target ~= target then
					if attackMoveState.Target ~= nil and attackMoveState.Active then
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					end
					configuration.CombatSystem.ResetNavigationState(attackMoveState)
					attackMoveState.Target = target
					attackMoveState.ApproachActive = (distance or math.huge) > attackRange
				end
				if (distance or math.huge) > attackRange + 1.25 then
					attackMoveState.ApproachActive = true
				elseif evadingEnemySkill then
					attackMoveState.ApproachActive = true
				elseif (distance or math.huge) <= attackRange then
					attackMoveState.ApproachActive = false
				end
				-- Mob combat keeps steering even inside attack range; the approach
				-- point moves around the live target so attacks happen while moving.
				if targetKind == "Mob" then attackMoveState.ApproachActive = true end
				attackMoveState.MarkUnreachableEligible = targetKind == "Mob"
					and target ~= configuration.SelectedCombatMob
					and target ~= configuration.CurrentTarget
					and target ~= configuration.ExpRetaliationTarget
					and target ~= configuration.ExpMaxCombatTarget
					and target ~= configuration.ExpFinishTarget
					and target ~= configuration.AlertCombatTarget
					and target ~= configuration.ServerHopKillTarget
					and not evadingEnemySkill
				local forcedExpCombat = target == configuration.AlertCombatTarget and configuration.AlertCombatPending
					or target == configuration.ExpMaxCombatTarget
					or target == configuration.ExpRetaliationTarget
					or target == configuration.ServerHopKillTarget and configuration.PendingServerHop
				if targetKind == "Mob" and localRoot and (configuration.AutoAttackEnabled or forcedExpCombat) then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					local tookMovement = ClaimMovement("Combat", humanoid, localRoot)
					local approachPoint = configuration.CombatSystem.SelectApproachPoint(
						localRoot, targetRoot, configuration.AutoAttackStandoff, target, attackMoveState, attackRange
					)
					attackMoveState.ApproachTarget = target
					attackMoveState.LastApproachPoint = approachPoint
					-- Sample the ground under the approach point so targets below a ledge
					-- remain reachable without navmesh pathfinding.
					approachPoint = configuration.CombatSystem.GroundAlignGoal(localRoot, approachPoint, target)
					if attackMoveState.ApproachActive then
						-- Refresh long range steering more often; soften close range updates to reduce jitter.
						local interval = (distance or 0) > 40 and 0.12 or 0.10
						local stopRadius = (distance or math.huge) <= attackRange + 2 and 0.15 or 1.9
						local arrived, navigationState = configuration.CombatSystem.NavigateMoveTo(
							humanoid, localRoot, approachPoint, target, attackMoveState, interval, stopRadius, true, false
						)
						attackMoveState.NavigationMode = navigationState
						chasingMob = not arrived
						if configuration.ExpFinishTarget == target then
							StateLabel.Text = navigationState == "path" and "Routing to finish EXP target"
								or (navigationState == "retrying route" and "Finding route to EXP target" or "Walking to finish EXP target")
							MiniState.Text = navigationState == "detouring" and "Steering around an obstacle toward the locked target"
								or (navigationState == "path" and "Following a path to the locked EXP target"
								or (navigationState == "retrying route" and "Route blocked — retrying toward locked target" or "Moving toward the EXP target while attacking")
								)
						elseif not configuration.Farming or configuration.AlertCombatPending or configuration.ExpRetaliationTarget == target then
							StateLabel.Text = evadingEnemySkill and "Avoiding enemy skill"
								or (navigationState == "path" and "Routing to target"
								or (navigationState == "retrying route" and "Finding path" or "Moving to target"))
							MiniState.Text = evadingEnemySkill and "Dodging active BladePart"
								or (navigationState == "path" and "Walking around an obstacle"
								or (navigationState == "detouring" and "Steering around an obstacle"
								or (navigationState == "retrying route" and "Blocked route; retrying" or "Closing distance to attack")))
						end
					elseif chasingMob or attackMoveState.Active or tookMovement then
						if humanoid then humanoid:MoveTo(localRoot.Position) end
						attackMoveState.Active = false
						attackMoveState.Goal = nil
						configuration.CombatSystem.ResetNavigationState(attackMoveState)
						attackMoveState.NavigationMode = "holding"
						chasingMob = false
					end
					-- Start facing early so attacks land cleaner during approach.
					if configuration.FaceTargetEnabled and (distance or 999) <= configuration.AutoAttackRange + 15 then
						FaceTargetWhenStill(localRoot, targetRoot.Position, 0.22)
					end
				elseif targetKind == "Player" and configuration.AutoAttackEnabled and localRoot then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					local tookMovement = ClaimMovement("Combat", humanoid, localRoot)
					if attackMoveState.ApproachActive then
						-- Keep chasing a moving player until they enter attack range; attacks still fire during movement when in range.
						local standoff = math.min(configuration.AutoAttackStandoff, math.max(1, attackRange - 1))
						local approachPoint = OrbitApproachPoint(localRoot, targetRoot, standoff)
						local interval = (distance or 0) > 40 and 0.16 or 0.26
						local arrived, navigationState = configuration.CombatSystem.NavigateMoveTo(
							humanoid, localRoot, approachPoint, target.Character, attackMoveState, interval, 1.9, false, false
						)
						attackMoveState.NavigationMode = navigationState
						chasingMob = not arrived
						StateLabel.Text = navigationState == "path" and "Routing to target"
							or (navigationState == "retrying route" and "Finding path" or "Moving to target")
						MiniState.Text = navigationState == "path" and "Walking around an obstacle"
							or (navigationState == "retrying route" and "Blocked route; retrying" or "Closing distance to attack")
						if configuration.FaceTargetEnabled and (distance or 999) <= configuration.AutoAttackRange + 15 then
							FaceTargetWhenStill(localRoot, targetRoot.Position, 0.22)
						end
					elseif chasingMob or attackMoveState.Active or tookMovement then
						if humanoid then humanoid:MoveTo(localRoot.Position) end
						attackMoveState.Active = false
						attackMoveState.Goal = nil
						configuration.CombatSystem.ResetNavigationState(attackMoveState)
						attackMoveState.NavigationMode = "holding"
						chasingMob = false
					end
				elseif chasingMob or attackMoveState.Active then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					configuration.CombatSystem.ResetNavigationState(attackMoveState)
					chasingMob = false
					attackMoveState.Target = nil
					attackMoveState.ApproachActive = false
					ReleaseMovement("Combat", humanoid, localRoot)
				else
					attackMoveState.Target = nil
					attackMoveState.ApproachActive = false
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					ReleaseMovement("Combat", humanoid, localRoot)
				end

				if distance <= attackRange or chasingMob then
					if configuration.FaceTargetEnabled and localRoot and targetRoot then
						FaceTargetWhenStill(localRoot, targetRoot.Position, distance <= 12 and 0.45 or 0.28)
					end
					local playerGui = Player:FindFirstChildOfClass("PlayerGui")
					local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
					if inputFunction and inputFunction:IsA("BindableFunction") then
						local now = os.clock()
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						local hasWeapon, needsEquip = configuration.Combat.GetWeaponEquipState(character)
						local canAttack = humanoid and humanoid.Health > 0 and hasWeapon
						if not canAttack then
							configuration.CombatInfo.Text = needsEquip and "Waiting for Sword; trying EquipButton before attacking." or "Waiting for PlayerStats and Sword/MainWeld."
							if not configuration.Farming or configuration.AlertCombatPending or configuration.ExpMaxCombatTarget then
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
							configuration.CombatInfo.Text = configuration.AlertCombatPending and "Alert response: attacking only the locked EXP target." or "Weapon ready; Auto Attack can engage the selected target."
							if configuration.ExpFinishTarget == target then
								StateLabel.Text = distance > attackRange and "Moving and finishing target" or "Finishing target"
								MiniState.Text = distance > attackRange and "Attacking while moving to the locked EXP target" or "Attacking the locked EXP target until it dies"
							elseif not configuration.Farming or configuration.AlertCombatPending or configuration.ExpRetaliationTarget == target then
								StateLabel.Text = distance > attackRange and "Moving and attacking" or "Attacking"
								MiniState.Text = distance > attackRange and "Attacking while closing distance" or "In range — attacking target"
							end
							if (configuration.AutoAttackEnabled or forcedExpCombat)
								and now - lastAttackAt >= configuration.AutoAttackInterval then
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
							if configuration.AutoSkillEnabled and distance <= attackRange and now - lastSkillAt >= configuration.AutoSkillInterval then
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
				if not configuration.Farming or configuration.AlertCombatPending
					or target == configuration.ExpRetaliationTarget or target == configuration.ExpMaxCombatTarget
					or target == configuration.ExpFinishTarget
					or target == configuration.ServerHopKillTarget then
					configuration.UpdateCombatDiagnostics(target, targetRoot, distance, attackRange, attackMoveState.NavigationMode, attackMoveState)
				end
			else
				if chasingMob or attackMoveState.Active then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					attackMoveState.Active = false
					attackMoveState.Goal = nil
					configuration.CombatSystem.ResetNavigationState(attackMoveState)
					chasingMob = false
				end
				attackMoveState.Target = nil
				attackMoveState.ApproachActive = false
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				ReleaseMovement("Combat", humanoid, localRoot)
				configuration.UpdateCombatDiagnostics(nil, nil, nil, nil, "searching", attackMoveState)
			end
		else
			if chasingMob or attackMoveState.Active then
				local character = Player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local localRoot = character and character:FindFirstChild("HumanoidRootPart")
				if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
				attackMoveState.Active = false
				attackMoveState.Goal = nil
				configuration.CombatSystem.ResetNavigationState(attackMoveState)
				chasingMob = false
			end
			attackMoveState.Target = nil
			attackMoveState.ApproachActive = false
			local character = Player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			ReleaseMovement("Combat", humanoid, localRoot)
			configuration.UpdateCombatDiagnostics(nil, nil, nil, nil, "paused", attackMoveState)
		end
		-- Throttle button label sync; combat loop no longer needs full UI work every tick.
		local nowUi = os.clock()
		if nowUi - lastUiSync >= 0.35 then
			lastUiSync = nowUi
			configuration.UpdateExpMobTargetButton()
		end
		task.wait(0.08)
	end
end)

-- Return to the pinned position when no higher-priority combat/EXP movement owns the character.
task.spawn(function()
	local moveState = configuration.WaypointMoveState
	while true do
		task.wait(0.12)
		local character = Player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local point = configuration.WaypointPosition
		local paused = configuration.EmergencyStopActive
			or configuration.FollowPlayerUserId ~= nil
			or configuration.AlertCombatPending
			or configuration.AlertCombatHold
			or configuration.ExpMaxCombatTarget ~= nil
			or configuration.ExpRetaliationTarget ~= nil
			or configuration.ExpFinishTarget ~= nil
			or configuration.PendingServerHop
		if not paused and root and configuration.AutoAttackEnabled and not configuration.Farming then
			local targetKind = configuration.Combat.FindAutoAttackTarget(root)
			paused = targetKind ~= nil
		end
		if configuration.Farming and configuration.ExpAutoApproachEnabled then
			paused = true
		end

		if configuration.WaypointReturnEnabled and point and root and humanoid and not paused then
			local distance = (root.Position - point).Magnitude
			if distance > configuration.WaypointReturnRadius then
				ClaimMovement("Waypoint", humanoid, root)
				local _, navigationState = configuration.CombatSystem.NavigateMoveTo(
					humanoid,
					root,
					point,
					nil,
					moveState,
					0.18,
					configuration.WaypointReturnRadius,
					true,
					false
				)
				moveState.NavigationMode = navigationState
			else
				ReleaseMovement("Waypoint", humanoid, root)
				configuration.CombatSystem.ResetNavigationState(moveState)
			end
		else
			if humanoid and root then ReleaseMovement("Waypoint", humanoid, root) end
			configuration.CombatSystem.ResetNavigationState(moveState)
		end
	end
end)

--==================================================
-- LIVE UI + TIMER + RATE
--==================================================
task.spawn(function()
	while true do
		if configuration.Farming and configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
			local cfg = configuration.CurrentTarget:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			local reachedMax = exp and exp.Value >= configuration.ExpGoal

			if configuration.CurrentTarget ~= configuration.LastTarget then
				configuration.LastTarget = configuration.CurrentTarget
				configuration.TargetStartTime = os.clock()
				configuration.AccumulatedTime = 0
				configuration.IsPaused = false
				if exp then
					configuration.SessionStartEXP = exp.Value
					configuration.SessionStartTime = os.clock()
				end
			end

			if not reachedMax then
				if configuration.IsPaused then
					configuration.TargetStartTime = os.clock()
					configuration.IsPaused = false
				end
				TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime + (os.clock() - configuration.TargetStartTime))
				MiniTime.Text = TimeLabel.Text
			else
				configuration.PauseTimer()
				TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime)
			MiniTime.Text = TimeLabel.Text
			end

			-- EXP / Hour
			if exp and configuration.SessionStartTime > 0 then
				local elapsed = os.clock() - configuration.SessionStartTime
				if elapsed > 1 then
					local gained = exp.Value - configuration.SessionStartEXP
					local perHour = (gained / elapsed) * 3600
					RateLabel.Text = configuration.FormatNumber(perHour) .. "/h"
				end
			end
		else
			if configuration.LastTarget then
				TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime)
			MiniTime.Text = TimeLabel.Text
			end
		end

		if configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
			local cfg = configuration.CurrentTarget:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			if exp then
				local ratio = math.clamp(exp.Value / configuration.ExpGoal, 0, 1)
				if math.floor(ratio * 1000) ~= math.floor((Bar.Size.X.Scale or 0) * 1000) then
					Bar.Size = UDim2.fromScale(ratio, 1)
				end
				if math.floor(ratio * 1000) ~= math.floor((MiniBarFill.Size.X.Scale or 0) * 1000) then
					MiniBarFill.Size = UDim2.fromScale(ratio, 1)
					MiniBarFill.BackgroundColor3 = ratio >= 1 and GREEN or (ratio >= 0.6 and ACCENT or GREEN)
				end
				local expText = configuration.FormatNumber(exp.Value)
				if ExpLabel.Text ~= expText then ExpLabel.Text = expText end
				if MiniExp.Text ~= expText then MiniExp.Text = expText end
				local maxText = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
				if MaxLabel.Text ~= maxText then MaxLabel.Text = maxText end
				if MiniMax.Text ~= maxText then MiniMax.Text = maxText end
				local percentText = string.format("%.1f%%", ratio * 100)
				if PercentLabel.Text ~= percentText then PercentLabel.Text = percentText end
				configuration.UpdateBillboardText(exp.Value, exp.Value >= configuration.ExpGoal)
			end

			local char = Player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local mroot = configuration.CurrentTarget.PrimaryPart or configuration.CurrentTarget:FindFirstChild("HumanoidRootPart")
			if root and mroot then
				local distText = "Dist  " .. string.format("%.1f", (root.Position - mroot.Position).Magnitude)
				if DistLabel.Text ~= distText then DistLabel.Text = distText end
			end
		else
			if configuration.CurrentTarget and not configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
				configuration.ClearBillboard()
				configuration.CurrentTarget = nil
			end
		end

		-- Player level + Exp current/max from PlayerStats.Level / PlayerStats.EXP
		do
			local level, pExp, pMax = configuration.GetLocalLevelProgress()
			local levelText = (type(level) == "number") and ("Lv " .. tostring(math.floor(level + 0))) or "Lv —"
			local expLine
			if type(pExp) == "number" and type(pMax) == "number" then
				expLine = string.format("Exp %s/%s", configuration.FormatNumber(pExp), configuration.FormatNumber(pMax))
			elseif type(pExp) == "number" then
				expLine = "Exp " .. configuration.FormatNumber(pExp)
			else
				expLine = "Exp —/—"
			end
			if LevelLabel and LevelLabel.Text ~= levelText then LevelLabel.Text = levelText end
			if MiniLevel and MiniLevel.Text ~= levelText then MiniLevel.Text = levelText end
			if LevelExpText and LevelExpText.Text ~= expLine then LevelExpText.Text = expLine end
			if MiniLevelExpLabel and MiniLevelExpLabel.Text ~= expLine then MiniLevelExpLabel.Text = expLine end
		end

		-- Faster while farming/combat feedback matters; slower when idle to cut CPU.
		local uiBusy = configuration.Farming or configuration.AutoAttackEnabled or configuration.AlertCombatPending
		task.wait(uiBusy and 0.12 or 0.28)
	end
end)

--==================================================
-- PLAYER LIST + FULL-SCREEN ALERTS
--==================================================
task.spawn(function()
	local lastPlayerRefresh = 0
	local lastFollowMove = 0
	local lastFollowProgressCheck = 0
	local lastFollowProgressPosition = nil
	local followEscapeDirection = 0
	local followGoalPosition = nil
	local followMoveState = { Active = false, Goal = nil, LastMoveAt = 0 }
	local lastAutoBlockCheck = 0
	local nextAutoBlockPromptAt = 0
	local lastInteractAt = 0
	local autoBlockTeleporting = false
	local deferredAutoBlockMob = nil
	local flashOn = false
	local lastFlashToggle = 0
	local PlayerVisuals = {}
	local ThumbnailCache = {}
	local PlayerPanelBuildSignature = nil
	local FollowTurnAngles = { 0, 45, -45, 90, -90, 135, -135, 180 }

	while true do
		local char = Player.Character
		local localRoot = char and char:FindFirstChild("HumanoidRootPart")
		local playerSnapshots = nil
		if localRoot and not configuration.EmergencyStopActive
			and (configuration.AlertsEnabled or configuration.FollowPlayerUserId ~= nil) then
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
		if configuration.AlertsEnabled and not configuration.EmergencyStopActive and localRoot then
			for _, snapshot in ipairs(playerSnapshots or {}) do
				local otherPlayer = snapshot.Player
				if otherPlayer ~= Player and not configuration.IsWhitelisted(otherPlayer) then
					local otherRoot = snapshot.Root
					if otherRoot.Parent then
						local distance = (localRoot.Position - otherRoot.Position).Magnitude
						if distance <= configuration.AlertsDistance and distance < nearbyDistance then
							nearbyPlayer = otherPlayer
							nearbyDistance = distance
						end
					end
				end
			end
		end

		local trackedAlertId = tonumber(configuration.LastAlertCombatUserId)
		local trackedAlertPlayer = trackedAlertId and Players:GetPlayerByUserId(trackedAlertId)
		local trackedCharacter = trackedAlertPlayer and trackedAlertPlayer.Character
		local trackedRoot = trackedCharacter and trackedCharacter:FindFirstChild("HumanoidRootPart")
		local trackedPlayerInRange = configuration.AlertsEnabled and localRoot and trackedRoot
			and (localRoot.Position - trackedRoot.Position).Magnitude <= configuration.AlertsDistance
		if not trackedPlayerInRange and not configuration.AlertCombatPending then
			local shouldResume = configuration.AlertCombatHold and configuration.AutoResumeAfterAlert
				and not configuration.EmergencyStopActive
			configuration.LastAlertCombatUserId = nil
			configuration.AlertCombatHold = false
			configuration.AlertCombatBlockReady = false
			configuration.AlertBlockTarget = nil
			if shouldResume then configuration.SetRunning() end
		end

		if nearbyPlayer then
			local alertUserId = tostring(nearbyPlayer.UserId)
			if not configuration.AlertCombatPending and not configuration.AlertCombatBlockReady
				and configuration.LastAlertCombatUserId ~= alertUserId then
				configuration.LastAlertCombatUserId = alertUserId
				configuration.AlertCombatPending = true
				configuration.AlertBlockTarget = nearbyPlayer
				local mob = configuration.CurrentTarget
				if not configuration.Combat.IsLivingMob(mob) then
					mob = nil
				end
				configuration.AlertCombatTarget = mob
				if mob then
					configuration.AutoAttackPinnedMob = mob
					configuration.CombatTargetMob = mob
					StateLabel.Text = "Alert"
					MiniState.Text = "Attacking locked EXP target before Block"
				else
					-- Never substitute a nearby mob when there is no active EXP target.
					configuration.AlertCombatPending = false
					configuration.AlertCombatHold = true
					configuration.AlertCombatBlockReady = configuration.AutoBlockEnabled
					StateLabel.Text = configuration.AutoBlockEnabled and "Block" or "Alert hold"
					MiniState.Text = configuration.AutoBlockEnabled and "No EXP target; opening Block prompt" or "No EXP target; waiting for player to leave"
					if not configuration.AutoBlockEnabled then
						configuration.AlertBlockTarget = nil
					end
				end
				if configuration.Farming then configuration.SetIdle(false) end
				if configuration.AlertCombatPending then
					StateLabel.Text = "Alert"
					MiniState.Text = "Attacking locked EXP target before Block"
				elseif configuration.AlertCombatBlockReady then
					StateLabel.Text = "Block"
					MiniState.Text = "No EXP target; opening Block prompt"
				elseif configuration.AlertCombatHold then
					StateLabel.Text = "Alert hold"
					MiniState.Text = "No EXP target; waiting for player to leave"
				end
			end
		else
			if not configuration.AlertCombatPending and not configuration.AlertCombatBlockReady then
				configuration.AlertCombatHold = false
				configuration.LastAlertCombatUserId = nil
			end
		end

		if configuration.AlertCombatPending then
			local alertMob = configuration.AlertCombatTarget
			if alertMob then
				if not configuration.Combat.IsLivingMob(alertMob) then
					configuration.AlertCombatPending = false
					configuration.AlertCombatTarget = nil
					configuration.AlertCombatHold = true
					configuration.AlertCombatBlockReady = configuration.AutoBlockEnabled
					StateLabel.Text = configuration.AutoBlockEnabled and "Block" or "Alert hold"
					MiniState.Text = configuration.AutoBlockEnabled and "EXP target defeated; opening Block prompt" or "EXP target defeated; waiting for player to leave"
				else
					configuration.AutoAttackPinnedMob = alertMob
					configuration.CombatTargetMob = alertMob
				end
			end
		end

		local followedPlayer = configuration.FollowPlayerUserId and Players:GetPlayerByUserId(tonumber(configuration.FollowPlayerUserId))
		-- Pause Follow while Auto Attack is pursuing a valid target; resume when the target clears.
		local interruptFollow = configuration.AlertCombatPending == true
		if not interruptFollow and (configuration.AutoAttackEnabled or configuration.ExpFinishTarget ~= nil)
			and not configuration.Farming and localRoot then
			local kind = configuration.Combat.FindAutoAttackTarget(localRoot)
			if kind then
				interruptFollow = true
			else
				if not configuration.AutoAttackPinnedMob then
					configuration.CombatTargetMob = nil
				end
				if configuration.AutoAttackMode == "Nearby" and not kind then
					configuration.NearbyLockKind = nil
					configuration.NearbyLockTarget = nil
				end
			end
		end
		-- Follow with spacing while steering around nearby players and stalled movement.
		if not configuration.EmergencyStopActive and not configuration.Farming
			and followedPlayer and char and not interruptFollow and os.clock() - lastFollowMove >= 0.25 then
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			local followedCharacter = followedPlayer.Character
			local followedRoot = followedCharacter and followedCharacter:FindFirstChild("HumanoidRootPart")
			if humanoid and localRoot and followedRoot then
				local followedHumanoid = followedCharacter:FindFirstChildOfClass("Humanoid")
				if followedHumanoid and humanoid.WalkSpeed ~= followedHumanoid.WalkSpeed then
					humanoid.WalkSpeed = followedHumanoid.WalkSpeed
				end
				local spacing = math.max(3, configuration.FollowDistance or 8)
				local now = os.clock()
				local delta = localRoot.Position - followedRoot.Position
				local flat = Vector3.new(delta.X, 0, delta.Z)
				local dist = flat.Magnitude
				-- Prefer staying on the current side of the target; if overlapping, fall back behind them.
				local outward = flat
				if outward.Magnitude < 0.35 then
					local behind = -followedRoot.CFrame.LookVector
					outward = Vector3.new(behind.X, 0, behind.Z)
					if outward.Magnitude < 0.1 then
						outward = Vector3.new(0, 0, -1)
					end
				end
				outward = outward.Unit
				local clearRadius = spacing
				local otherPlayerPositions = {}
				local currentClearance = math.huge
				for _, snapshot in ipairs(playerSnapshots or {}) do
					local otherPlayer = snapshot.Player
					if otherPlayer ~= Player and otherPlayer ~= followedPlayer then
						local otherRoot = snapshot.Root
						if otherRoot.Parent then
							local otherPosition = otherRoot.Position
							table.insert(otherPlayerPositions, otherPosition)
							local dx = localRoot.Position.X - otherPosition.X
							local dz = localRoot.Position.Z - otherPosition.Z
							currentClearance = math.min(currentClearance, math.sqrt(dx * dx + dz * dz))
						end
					end
				end

				local followStuck = false
				if now - lastFollowProgressCheck >= 1.4 then
					if lastFollowProgressPosition and followGoalPosition
						and (localRoot.Position - followGoalPosition).Magnitude > 3
						and (localRoot.Position - lastFollowProgressPosition).Magnitude < 0.45 then
						followStuck = true
						followEscapeDirection = (followEscapeDirection + 1) % 8
					end
					lastFollowProgressPosition = localRoot.Position
					lastFollowProgressCheck = now
				end

				-- Hysteresis: only path when too far or too close; hold still inside the comfort band.
				local tooFar = dist > spacing + 1.25
				local tooClose = dist < spacing * 0.72
				local needsFollowMove = tooFar or tooClose or currentClearance < clearRadius or followStuck
				if needsFollowMove then
					local bestGoal, bestScore = nil, -math.huge
					for offset = 0, #FollowTurnAngles - 1 do
						local angleIndex = (offset + followEscapeDirection) % #FollowTurnAngles + 1
						local angle = FollowTurnAngles[angleIndex]
						local radians = math.rad(angle)
						local direction = Vector3.new(
							outward.X * math.cos(radians) - outward.Z * math.sin(radians),
							0,
							outward.X * math.sin(radians) + outward.Z * math.cos(radians)
						)
						for radiusStep = 0, 2 do
							local radius = spacing + clearRadius * 0.5 * radiusStep
							local candidate = followedRoot.Position + direction * radius
							candidate = Vector3.new(candidate.X, followedRoot.Position.Y, candidate.Z)
							local nearestOther = math.huge
							for _, otherPosition in ipairs(otherPlayerPositions) do
								local dx = candidate.X - otherPosition.X
								local dz = candidate.Z - otherPosition.Z
								nearestOther = math.min(nearestOther, math.sqrt(dx * dx + dz * dz))
							end
							local score = math.min(nearestOther, spacing * 3)
								- math.abs(angle) * 0.01
								- (radius - spacing) * 0.7
							if score > bestScore then
								bestGoal, bestScore = candidate, score
							end
						end
					end
					local goal = bestGoal or (followedRoot.Position + outward * spacing)
					ClaimMovement("Follow", humanoid, localRoot)
					configuration.CombatSystem.NavigateMoveTo(
						humanoid, localRoot, goal, followedCharacter, followMoveState, 0.28, 2.2, false, false
					)
					followGoalPosition = goal
				else
					ReleaseMovement("Follow", humanoid, localRoot)
					followGoalPosition = nil
					followEscapeDirection = 0
					configuration.CombatSystem.ResetNavigationState(followMoveState)
				end
				lastFollowMove = now
			end
		end
		if interruptFollow or configuration.EmergencyStopActive or configuration.Farming or not followedPlayer then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			ReleaseMovement("Follow", humanoid, localRoot)
			followGoalPosition = nil
			lastFollowProgressPosition = nil
			followEscapeDirection = 0
			configuration.CombatSystem.ResetNavigationState(followMoveState)
		end

		-- Tap X while Auto Farm or Follow is active so contextual Interact actions can trigger.
		if not configuration.EmergencyStopActive
			and (configuration.Farming or followedPlayer ~= nil)
			and os.clock() - lastInteractAt >= 0.9 then
			lastInteractAt = os.clock()
			TapInteractX()
		end

		if configuration.AutoBlockEnabled and not configuration.EmergencyStopActive and not configuration.AlertCombatPending
			and os.clock() - lastAutoBlockCheck >= 1 then
			lastAutoBlockCheck = os.clock()
			local blockedUsers = configuration.GetBlockedUserSet()
			local hasNonWhitelistedPlayer = false
			local blockedNonWhitelistedPlayer = false
			local nextPlayerToPrompt = nil
			if not configuration.Farming then
				deferredAutoBlockMob = nil
			elseif not deferredAutoBlockMob then
				local activeExpMob = configuration.CurrentTarget
				if not configuration.Combat.IsLivingMob(activeExpMob) then
					activeExpMob = configuration.ExpMaxCombatTarget
				end
				if configuration.Combat.IsLivingMob(activeExpMob) then
					deferredAutoBlockMob = activeExpMob
				end
			end
			local deferPromptForExp = deferredAutoBlockMob ~= nil
				and configuration.Combat.IsLivingMob(deferredAutoBlockMob)
			if deferredAutoBlockMob and not deferPromptForExp then
				deferredAutoBlockMob = nil
			end

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= Player and not configuration.IsWhitelisted(otherPlayer) then
					hasNonWhitelistedPlayer = true
					if blockedUsers and blockedUsers[tostring(otherPlayer.UserId)] then
						blockedNonWhitelistedPlayer = true
						break
					elseif not nextPlayerToPrompt then
						nextPlayerToPrompt = otherPlayer
					end
				end
			end

			local alertTarget = configuration.AlertCombatBlockReady and configuration.AlertBlockTarget
			if alertTarget and alertTarget.Parent == Players
				and not configuration.IsWhitelisted(alertTarget)
				and not (blockedUsers and blockedUsers[tostring(alertTarget.UserId)]) then
				nextPlayerToPrompt = alertTarget
			end

			if not hasNonWhitelistedPlayer then
				-- A server containing only whitelisted players never triggers block or teleport.
				nextAutoBlockPromptAt = 0
				configuration.AlertCombatBlockReady = false
				configuration.AlertBlockTarget = nil
			elseif blockedNonWhitelistedPlayer and not autoBlockTeleporting then
				configuration.AlertCombatBlockReady = false
				configuration.AlertBlockTarget = nil
				-- Prefer finishing the active EXP mob before hopping.
				local killMob = deferredAutoBlockMob
				if not configuration.Combat.IsLivingMob(killMob) then
					killMob = configuration.CurrentTarget
				end
				if not configuration.Combat.IsLivingMob(killMob) then
					killMob = configuration.ExpMaxCombatTarget
				end
				if configuration.Combat.IsLivingMob(killMob) then
					configuration.PendingServerHop = true
					configuration.ServerHopKillTarget = killMob
					configuration.AutoAttackPinnedMob = killMob
					configuration.CombatTargetMob = killMob
					configuration.ExpMaxCombatTarget = killMob
					-- Stop EXP firing; focus on killing, then hop.
					if configuration.Farming then
						configuration.Farming = false
						configuration.PauseTimer()
						StartBtn.Text = "Start"
						StartBtn.BackgroundColor3 = ACCENT
						Status.Text = "OFF"
						Status.TextColor3 = RED
						Status.BackgroundColor3 = RED_DIM
					end
					StateLabel.Text = "Finish EXP"
					MiniState.Text = "Blocked player in server — killing EXP mob before hop"
				else
					configuration.PendingServerHop = false
					configuration.ServerHopKillTarget = nil
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
				if ok and configuration.AlertCombatBlockReady and nextPlayerToPrompt == alertTarget then
					configuration.AlertCombatBlockReady = false
					configuration.AlertBlockTarget = nil
					StateLabel.Text = "Block prompt"
					MiniState.Text = "Block prompt opened; waiting for the Alert player to leave"
				elseif not ok then
					warn("Auto Block prompt failed:", err)
				end
			end
		elseif not configuration.AutoBlockEnabled then
			nextAutoBlockPromptAt = 0
			configuration.PendingServerHop = false
			configuration.ServerHopKillTarget = nil
		end

		-- Complete deferred hop once the locked EXP mob is dead (or gone).
		if configuration.PendingServerHop and not autoBlockTeleporting and not configuration.EmergencyStopActive then
			local hopMob = configuration.ServerHopKillTarget
			local stillAlive = configuration.Combat.IsLivingMob(hopMob)
			if stillAlive then
				configuration.AutoAttackPinnedMob = hopMob
				configuration.CombatTargetMob = hopMob
				StateLabel.Text = "Finish EXP"
				MiniState.Text = "Killing EXP mob before server hop"
			else
				configuration.PendingServerHop = false
				configuration.ServerHopKillTarget = nil
				configuration.ExpMaxCombatTarget = nil
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
			local panelPlayers = Players:GetPlayers()
			local signatureParts = { configuration.PlayerPanelMode }
			for _, listedPlayer in ipairs(panelPlayers) do
				table.insert(signatureParts, table.concat({
					tostring(listedPlayer.UserId),
					configuration.IsWhitelisted(listedPlayer) and "w" or "-",
					configuration.IsPlayerESPEnabled(listedPlayer) and "e" or "-",
					configuration.FollowPlayerUserId == tostring(listedPlayer.UserId) and "f" or "-",
					configuration.AutoAttackTargetUserId == tostring(listedPlayer.UserId) and "a" or "-",
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
				if configuration.PlayerPanelMode == "follow" then
					if otherPlayer == Player then continue end
					local selectedPlayer = otherPlayer
					local row = Instance.new("TextButton")
					row.Name = "PlayerRow_" .. selectedPlayer.UserId
					row.Size = UDim2.new(1, -4, 0, 44)
					row.LayoutOrder = order
					row.ZIndex = 92
					local isFollowSelected = configuration.FollowPlayerUserId == tostring(selectedPlayer.UserId)
					row.BackgroundColor3 = isFollowSelected and SEL_BG or CARD
					row.BorderSizePixel = 0
					row.Text = "  " .. selectedPlayer.DisplayName
					row.TextColor3 = isFollowSelected and SEL_TEXT or TEXT
					row.TextSize = 13
					row.Font = Enum.Font.GothamBold
					row.TextXAlignment = Enum.TextXAlignment.Left
					row.TextTruncate = Enum.TextTruncate.AtEnd
					row.Parent = PlayerScroll
					Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
					row.MouseButton1Click:Connect(function()
						configuration.FollowPlayerUserId = tostring(selectedPlayer.UserId)
						configuration.SaveConfig()
						configuration.UpdateFollowButtons()
						PlayerPanel.Visible = false
						configuration.PlayerPanelMode = "server"
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
				row.Size = UDim2.new(1, -4, 0, 118)
				row.LayoutOrder = order
				row.ZIndex = 92
				row.BackgroundColor3 = CARD
				row.BorderSizePixel = 0
				row.Parent = PlayerScroll
				Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
				local rowStroke = Instance.new("UIStroke", row)
				rowStroke.Color = BORDER
				rowStroke.Thickness = 1
				rowStroke.Transparency = 0.55

				local avatar = Instance.new("ImageLabel")
				avatar.Name = "Avatar"
				avatar.Size = UDim2.fromOffset(46, 46)
				avatar.Position = UDim2.fromOffset(12, 14)
				avatar.ZIndex = 93
				avatar.BackgroundColor3 = INPUT
				avatar.BorderSizePixel = 0
				avatar.ScaleType = Enum.ScaleType.Crop
				avatar.Parent = row
				Instance.new("UICorner", avatar).CornerRadius = UDim.new(1, 0)

				if not ThumbnailCache[otherPlayer.UserId] then
					local ok, imageUrl = pcall(function()
						return Players:GetUserThumbnailAsync(otherPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
					end)
					if ok then ThumbnailCache[otherPlayer.UserId] = imageUrl end
				end
				avatar.Image = ThumbnailCache[otherPlayer.UserId] or ""

				local textLeft = otherPlayer == Player and 1 or 72
				local displayName = Instance.new("TextLabel")
				displayName.Name = "DisplayName"
				displayName.Size = UDim2.new(1, -(textLeft + 12), 0, 18)
				displayName.Position = UDim2.fromOffset(66, 10)
				displayName.ZIndex = 93
				displayName.BackgroundTransparency = 1
				displayName.Text = otherPlayer.DisplayName
				displayName.TextColor3 = TEXT
				displayName.TextSize = 14
				displayName.Font = Enum.Font.GothamBold
				displayName.TextXAlignment = Enum.TextXAlignment.Left
				displayName.TextTruncate = Enum.TextTruncate.AtEnd
				displayName.Parent = row

				local usernameLabel = Instance.new("TextLabel")
				usernameLabel.Size = UDim2.new(1, -(textLeft + 12), 0, 15)
				usernameLabel.Position = UDim2.fromOffset(66, 28)
				usernameLabel.ZIndex = 93
				usernameLabel.BackgroundTransparency = 1
				usernameLabel.Text = "@" .. otherPlayer.Name
				usernameLabel.TextColor3 = MUTED
				usernameLabel.TextSize = 11
				usernameLabel.Font = Enum.Font.Gotham
				usernameLabel.TextXAlignment = Enum.TextXAlignment.Left
				usernameLabel.TextTruncate = Enum.TextTruncate.AtEnd
				usernameLabel.Parent = row

				local detail = Instance.new("TextLabel")
				detail.Name = "Distance"
				detail.Size = UDim2.new(1, -78, 0, 15)
				detail.Position = UDim2.fromOffset(66, 48)
				detail.ZIndex = 93
				detail.BackgroundTransparency = 1
				detail.Text = distanceText
				detail.TextColor3 = MUTED
				detail.TextSize = 11
				detail.Font = Enum.Font.Gotham
				detail.TextXAlignment = Enum.TextXAlignment.Left
				detail.TextTruncate = Enum.TextTruncate.AtEnd
				detail.Parent = row

				local currentHP, maximumHP = configuration.GetPlayerHealth(otherPlayer)
				local healthLabel = Instance.new("TextLabel")
				healthLabel.Name = "Health"
				healthLabel.Size = UDim2.new(1, -78, 0, 15)
				healthLabel.Position = UDim2.fromOffset(66, 66)
				healthLabel.ZIndex = 93
				healthLabel.BackgroundTransparency = 1
				healthLabel.Text = currentHP and string.format("HP %d / %d", currentHP, maximumHP) or "HP unavailable"
				if configuration.IsWhitelisted(otherPlayer) then
					healthLabel.Text ..= "  •  WHITELIST"
				end
				healthLabel.TextColor3 = configuration.GetHealthColor(currentHP, maximumHP)
				healthLabel.TextSize = 11
				healthLabel.Font = Enum.Font.Gotham
				healthLabel.TextXAlignment = Enum.TextXAlignment.Left
				healthLabel.TextTruncate = Enum.TextTruncate.AtEnd
				healthLabel.Parent = row

				local statsLabel = Instance.new("TextLabel")
				statsLabel.Name = "PlayerStats"
				statsLabel.Size = UDim2.new(1, -78, 0, 15)
				statsLabel.Position = UDim2.fromOffset(66, 84)
				statsLabel.ZIndex = 93
				statsLabel.BackgroundTransparency = 1
				statsLabel.Text = configuration.FormatPlayerStats(otherPlayer)
				statsLabel.TextColor3 = MUTED
				statsLabel.TextSize = 11
				statsLabel.Font = Enum.Font.Gotham
				statsLabel.TextXAlignment = Enum.TextXAlignment.Left
				statsLabel.TextTruncate = Enum.TextTruncate.AtEnd
				statsLabel.Parent = row

				if otherPlayer ~= Player then
					local playerEspButton = Instance.new("TextButton")
					playerEspButton.Name = "PlayerESPToggle"
					playerEspButton.Size = UDim2.fromOffset(58, 24)
					playerEspButton.Position = UDim2.new(1, -70, 0, 10)
					playerEspButton.ZIndex = 93
					playerEspButton.BackgroundColor3 = configuration.IsPlayerESPEnabled(otherPlayer) and GREEN_DIM or INPUT
					playerEspButton.BorderSizePixel = 0
					playerEspButton.Text = configuration.IsPlayerESPEnabled(otherPlayer) and "ESP ON" or "ESP OFF"
					playerEspButton.TextColor3 = configuration.IsPlayerESPEnabled(otherPlayer) and GREEN or MUTED
					playerEspButton.TextSize = 10
					playerEspButton.Font = Enum.Font.GothamBold
					playerEspButton.Parent = row
					Instance.new("UICorner", playerEspButton).CornerRadius = UDim.new(0, 6)
					playerEspButton.MouseButton1Click:Connect(function()
						local enabled = not configuration.IsPlayerESPEnabled(otherPlayer)
						configuration.PlayerESPEnabled[tostring(otherPlayer.UserId)] = enabled
						playerEspButton.Text = enabled and "ESP ON" or "ESP OFF"
						playerEspButton.TextColor3 = enabled and GREEN or MUTED
						playerEspButton.BackgroundColor3 = enabled and GREEN_DIM or INPUT
					end)

					local whitelistToggle = Instance.new("TextButton")
					whitelistToggle.Name = "WhitelistToggle"
					whitelistToggle.Size = UDim2.fromOffset(58, 24)
					whitelistToggle.Position = UDim2.new(1, -70, 0, 38)
					whitelistToggle.ZIndex = 93
					whitelistToggle.BackgroundColor3 = configuration.IsWhitelisted(otherPlayer) and Color3.fromRGB(55, 45, 22) or INPUT
					whitelistToggle.BorderSizePixel = 0
					whitelistToggle.Text = configuration.IsWhitelisted(otherPlayer) and "WL ON" or "WL ADD"
					whitelistToggle.TextColor3 = configuration.IsWhitelisted(otherPlayer) and YELLOW or MUTED
					whitelistToggle.TextSize = 10
					whitelistToggle.Font = Enum.Font.GothamBold
					whitelistToggle.Parent = row
					Instance.new("UICorner", whitelistToggle).CornerRadius = UDim.new(0, 6)
					whitelistToggle.MouseButton1Click:Connect(function()
						local userId = tostring(otherPlayer.UserId)
						if configuration.IsWhitelisted(otherPlayer) then
							configuration.WhitelistIds[userId] = nil
						else
							configuration.WhitelistIds[userId] = true
						end
						configuration.SaveConfig()
						local enabled = configuration.IsWhitelisted(otherPlayer)
						whitelistToggle.Text = enabled and "WL ON" or "WL ADD"
						whitelistToggle.TextColor3 = enabled and YELLOW or MUTED
						whitelistToggle.BackgroundColor3 = enabled and Color3.fromRGB(55, 45, 22) or INPUT
						if configuration.WhitelistPanel.Visible then configuration.RefreshWhitelist() end
					end)

					if configuration.PlayerPanelMode == "follow" or configuration.PlayerPanelMode == "attack" then
						local followButton = Instance.new("TextButton")
						local selectingAttackTarget = configuration.PlayerPanelMode == "attack"
						followButton.Name = selectingAttackTarget and "AttackTargetSelect" or "FollowToggle"
						followButton.Size = UDim2.fromOffset(58, 24)
						followButton.Position = UDim2.new(1, -70, 0, 66)
						followButton.ZIndex = 93
						local isFollowing = configuration.FollowPlayerUserId == tostring(otherPlayer.UserId)
						followButton.BackgroundColor3 = isFollowing and ACCENT_DIM or INPUT
						followButton.BorderSizePixel = 0
						local isSelected = isFollowing
						if selectingAttackTarget then
							isSelected = configuration.AutoAttackTargetUserId == tostring(otherPlayer.UserId)
						end
						followButton.Text = selectingAttackTarget and (isSelected and "TARGET" or "SELECT") or (isSelected and "STOP" or "FOLLOW")
						followButton.TextColor3 = isSelected and ACCENT or MUTED
						followButton.TextSize = 9
						followButton.Font = Enum.Font.GothamBold
						followButton.Parent = row
						Instance.new("UICorner", followButton).CornerRadius = UDim.new(0, 6)
						followButton.MouseButton1Click:Connect(function()
							if selectingAttackTarget then
								if configuration.AutoAttackBossesOnly then
									configuration.CombatInfo.Text = "Bosses only is active; player targets are disabled."
									return
								end
								if configuration.IsWhitelisted(otherPlayer) then
									configuration.CombatInfo.Text = "Whitelisted players are skipped by Auto Attack."
									return
								end
								configuration.AutoAttackTargetUserId = tostring(otherPlayer.UserId)
								configuration.AutoAttackMode = "Player"
								configuration.UpdateAutoAttackModeButtons()
								configuration.UpdateAttackTargetButton()
							elseif isFollowing then
								configuration.FollowPlayerUserId = nil
								if localRoot then
									local humanoid = char and char:FindFirstChildOfClass("Humanoid")
									if humanoid then humanoid:MoveTo(localRoot.Position) end
								end
							else
								configuration.FollowPlayerUserId = tostring(otherPlayer.UserId)
							end
							configuration.SaveConfig()
							configuration.UpdateFollowButtons()
							PlayerPanel.Visible = false
							configuration.PlayerPanelMode = "server"
							PlayerPanelTitle.Text = "Players in server"
							lastPlayerRefresh = 0
						end)
					end

					local blockButton = Instance.new("TextButton")
					blockButton.Name = "BlockButton"
					blockButton.Size = UDim2.fromOffset(58, 24)
					blockButton.Position = UDim2.new(1, -70, 1, -32)
					blockButton.ZIndex = 93
					blockButton.BackgroundColor3 = RED_DIM
					blockButton.BorderSizePixel = 0
					blockButton.Text = "Block"
					blockButton.TextColor3 = RED
					blockButton.TextSize = 10
					blockButton.Font = Enum.Font.GothamBold
					blockButton.Parent = row
					Instance.new("UICorner", blockButton).CornerRadius = UDim.new(0, 6)
					blockButton.MouseButton1Click:Connect(function()
						if configuration.BlockPromptCache[otherPlayer.UserId] then return end
						configuration.BlockPromptCache[otherPlayer.UserId] = true
						blockButton.Text = "..."
						local ok, err = pcall(function()
							StarterGui:SetCore("PromptBlockPlayer", otherPlayer)
						end)
						if not ok then
							configuration.BlockPromptCache[otherPlayer.UserId] = nil
							blockButton.Text = "Retry"
							warn("PromptBlockPlayer failed:", err)
							return
						end
						blockButton.Text = "Prompted"
						task.delay(3, function()
							configuration.BlockPromptCache[otherPlayer.UserId] = nil
							if blockButton.Parent then blockButton.Text = "Block" end
						end)
						end)
					end
				end
			end

			-- Refresh changing player data in-place; keep cards and their callbacks alive.
			if configuration.PlayerPanelMode == "server" then
				for _, listedPlayer in ipairs(panelPlayers) do
					local row = PlayerScroll:FindFirstChild("PlayerRow_" .. listedPlayer.UserId)
					if row and row:IsA("Frame") then
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
							local currentHP, maximumHP = configuration.GetPlayerHealth(listedPlayer)
							local healthText = currentHP and string.format("HP %d / %d", currentHP, maximumHP) or "HP unavailable"
							if configuration.IsWhitelisted(listedPlayer) then healthText ..= "  •  WHITELIST" end
							if healthLabel.Text ~= healthText then healthLabel.Text = healthText end
							local healthColor = configuration.GetHealthColor(currentHP, maximumHP)
							if healthLabel.TextColor3 ~= healthColor then healthLabel.TextColor3 = healthColor end
						end
						local statsLabel = row:FindFirstChild("PlayerStats")
						if statsLabel then
							local statsText = configuration.FormatPlayerStats(listedPlayer)
							if statsLabel.Text ~= statsText then statsLabel.Text = statsText end
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
				local visual = PlayerVisuals[otherPlayer]

				if otherCharacter and otherRoot then
					if not visual then
						local highlight = Instance.new("Highlight")
						highlight.Name = "PlayerESPOutline"
						highlight.FillTransparency = 1
						highlight.OutlineColor = RED
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
						nameTag.Parent = configuration.PlayerEspLayer

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
						tracer.BackgroundColor3 = RED
						tracer.BorderSizePixel = 0
						tracer.Visible = false
						tracer.ZIndex = 0
						tracer.Parent = configuration.PlayerEspLayer
						visual = { Highlight = highlight, NameTag = nameTag, NameLabel = nameLabel, DistanceLabel = distanceLabel, HealthLabel = healthLabel, StatsLabel = statsLabel, Tracer = tracer }
						PlayerVisuals[otherPlayer] = visual
					end

					visual.Highlight.Adornee = otherCharacter
					visual.NameLabel.Text = otherPlayer.DisplayName .. "  (@" .. otherPlayer.Name .. ")"
					if localRoot then
						local distance = (localRoot.Position - otherRoot.Position).Magnitude
						visual.DistanceLabel.Text = string.format("%.0f studs", distance)
					else
						visual.DistanceLabel.Text = "Distance unavailable"
					end
					local currentHP, maximumHP = configuration.GetPlayerHealth(otherPlayer)
					visual.HealthLabel.Text = currentHP and string.format("HP %d / %d", currentHP, maximumHP) or "HP unavailable"
					visual.HealthLabel.TextColor3 = configuration.GetHealthColor(currentHP, maximumHP)
					visual.StatsLabel.Text = configuration.FormatPlayerStats(otherPlayer)
					local visible = configuration.ESPEnabled and configuration.IsPlayerESPEnabled(otherPlayer) and not configuration.IsWhitelisted(otherPlayer)
					visual.Highlight.Enabled = visible and configuration.ESPBoxEnabled
					visual.NameTag.Visible = false
					visual.Tracer.Visible = false

					if visible and camera and viewport then
						local point, onScreen = camera:WorldToViewportPoint(otherRoot.Position)
						if point.Z > 0 and onScreen then
							visual.NameTag.Position = UDim2.fromScale(point.X / viewport.X, (point.Y - 8) / viewport.Y)
							visual.NameTag.Visible = true
							if configuration.ESPLineEnabled then
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

					if localRoot then
						local distance = (localRoot.Position - otherRoot.Position).Magnitude
						if not configuration.IsWhitelisted(otherPlayer) and distance <= configuration.AlertsDistance and distance < nearbyDistance then
							nearbyDistance = distance
							nearbyPlayer = otherPlayer
						end
					end
				else
					if visual then
						visual.Highlight.Enabled = false
						visual.NameTag.Visible = false
						visual.Tracer.Visible = false
					end
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

		local reachedMax = false
		if configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
			local cfg = configuration.CurrentTarget:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			reachedMax = exp ~= nil and exp.Value >= configuration.ExpGoal
		end

		if configuration.AlertsEnabled and not configuration.EmergencyStopActive and configuration.AlertFlashEnabled and nearbyPlayer then
			AlarmOverlay.BackgroundColor3 = RED
			configuration.AlarmText.Text = string.format("PLAYER NEARBY  •  %s  •  %.0f studs", nearbyPlayer.Name, nearbyDistance)
			AlarmOverlay.Visible = true
		elseif configuration.AlertsEnabled and not configuration.EmergencyStopActive and configuration.AlertFlashEnabled and reachedMax then
			AlarmOverlay.BackgroundColor3 = GREEN
			configuration.AlarmText.Text = "EXP MAX REACHED"
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
		local alertBusy = configuration.AlertsEnabled or configuration.FollowPlayerUserId ~= nil
			or configuration.AlertCombatPending or configuration.AlertCombatHold or AlarmOverlay.Visible
		task.wait(alertBusy and 0.08 or 0.18)
	end
end)

getgenv().IamrichLoaded = true
print("[Iamrich] Loaded successfully.")
