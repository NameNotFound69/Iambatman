local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")

local Player = Players.LocalPlayer
local MobsFolder = workspace:WaitForChild("Mobs")
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
if not InitClashing then return end

--==================================================
-- CONFIG
--==================================================
local configuration = {
	Amount = 5000,
	MaxDistance = 250,
	ExpApproachDistance = 25,
	Interval = 1,
	ExpGoal = 2000000,
	AlertsDistance = 1000,
	FollowDistance = 8,
	FollowPlayerUserId = nil,
	PlayerPanelMode = "server",
	AutoAttackTargetUserId = nil,
	AutoAttackPinnedMob = nil,
	MovementBoostEnabled = true,
	AutoAttackEnabled = false,
	AutoAttackUseExpTarget = false,
	AutoSkillEnabled = false,
	AutoAttackMode = "Mob",
	AutoAttackRange = 25,
	AutoAttackSearchRange = 100,
	AutoAttackInterval = 1,
	AutoSkillInterval = 3,
	AutoAttackStandoff = 4,
	CombatTargetMob = nil,
	Farming = false,
	CurrentTarget = nil,
	ExpMaxCombatTarget = nil,
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
	ConfigRootFolder = "Iamrich",
	ConfigUserFolder = "",
	LegacyConfigFileName = "EXPPlus_Config.json",
	LegacyConfigOwnerFileName = "Iamrich_LegacyConfigOwner.txt",
	MigratedLegacyConfig = false,
	IsMinimized = false,
	Combat = {},
}

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
		if ownerOk then owner = tostring(ownerValue) end
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
	configuration.MaxDistance = math.max(
		ReadNumber("MaxDistance", configuration.MaxDistance, 0, false),
		configuration.ExpApproachDistance + 5
	)
	configuration.Interval = ReadNumber("Interval", configuration.Interval, 0, true)
	configuration.ExpGoal = ReadNumber("ExpGoal", configuration.ExpGoal, 0, false)
	configuration.AlertsDistance = math.clamp(ReadNumber("AlertsDistance", configuration.AlertsDistance, 0, true), 0, 100000)
	configuration.FollowDistance = math.clamp(ReadNumber("FollowDistance", configuration.FollowDistance, 2, false), 2, 100)
	configuration.AutoAttackRange = math.clamp(ReadNumber("AutoAttackRange", configuration.AutoAttackRange, 5, false), 5, 500)
	configuration.AutoAttackSearchRange = math.clamp(ReadNumber("AutoAttackSearchRange", configuration.AutoAttackSearchRange, 5, false), 5, 100000)
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
	if type(config.AutoAttackUseExpTarget) == "boolean" then configuration.AutoAttackUseExpTarget = config.AutoAttackUseExpTarget end
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
		Interval = configuration.Interval,
		ExpGoal = configuration.ExpGoal,
		AlertsDistance = configuration.AlertsDistance,
		FollowDistance = configuration.FollowDistance,
		FollowPlayerUserId = configuration.FollowPlayerUserId,
		AutoAttackTargetUserId = configuration.AutoAttackTargetUserId,
		AutoAttackEnabled = configuration.AutoAttackEnabled,
		AutoAttackUseExpTarget = configuration.AutoAttackUseExpTarget,
		AutoAttackMode = configuration.AutoAttackMode,
		AutoAttackRange = configuration.AutoAttackRange,
		AutoAttackSearchRange = configuration.AutoAttackSearchRange,
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

--==================================================
-- COLORS (Slayers2-style dark + soft cyan)
--==================================================
local BG         = Color3.fromRGB(18, 18, 20)      -- main window
local SIDEBAR_BG = Color3.fromRGB(22, 22, 24)      -- left sidebar
local CARD       = Color3.fromRGB(28, 28, 30)      -- content cards
local INPUT      = Color3.fromRGB(36, 36, 39)      -- inputs / rows
local BORDER     = Color3.fromRGB(45, 45, 48)
local TEXT       = Color3.fromRGB(240, 240, 243)
local MUTED      = Color3.fromRGB(140, 140, 148)
local ACCENT     = Color3.fromRGB(130, 210, 245)   -- soft cyan
local ACCENT_SEL = Color3.fromRGB(160, 220, 245)  -- selected nav (like image)
local GREEN      = Color3.fromRGB(76, 218, 164)
local RED        = Color3.fromRGB(255, 92, 112)
local YELLOW     = Color3.fromRGB(255, 196, 92)
local ACCENT_DIM = Color3.fromRGB(40, 90, 110)
local GREEN_DIM  = Color3.fromRGB(24, 53, 45)
local RED_DIM    = Color3.fromRGB(56, 30, 37)
local SEL_BG     = Color3.fromRGB(160, 220, 245)  -- light blue selected button
local SEL_TEXT   = Color3.fromRGB(20, 30, 40)     -- dark text on selected

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
	local s = tostring(math.floor(n))
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
		configuration.CurrentBillboard:Destroy()
		configuration.CurrentBillboard = nil
	end
end

function configuration.AttachBillboard(mob, expValue)
	configuration.ClearBillboard()
	local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local bb = Instance.new("BillboardGui")
	bb.Name = "FarmMarker"
	bb.Size = UDim2.fromScale(3, 1)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 120
	bb.Parent = root

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = bb
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = ACCENT
	stroke.Thickness = 1.5

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "FARMING\n" .. configuration.FormatNumber(expValue)
	label.TextColor3 = ACCENT
	label.TextSize = 11
	label.Font = Enum.Font.GothamBold
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = frame

	configuration.CurrentBillboard = bb
end

function configuration.UpdateBillboardText(expValue, isMax)
	if configuration.CurrentBillboard then
		local label = configuration.CurrentBillboard:FindFirstChild("Text", true)
		if label then
			if isMax then
				local text = "MAX\n" .. configuration.FormatNumber(expValue)
				if label.Text ~= text then label.Text = text end
				label.TextColor3 = GREEN
			else
				local text = "FARMING\n" .. configuration.FormatNumber(expValue)
				if label.Text ~= text then label.Text = text end
				label.TextColor3 = ACCENT
			end
		end
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
Header.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
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

local Status = Instance.new("TextLabel")
Status.Size = UDim2.fromOffset(48, 20)
Status.Position = UDim2.new(1, -62, 0, 10)
Status.BackgroundColor3 = RED_DIM
Status.Text = "OFF"
Status.TextColor3 = RED
Status.TextSize = 10
Status.Font = Enum.Font.GothamBold
Status.Parent = Header
Instance.new("UICorner", Status).CornerRadius = UDim.new(1, 0)

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Size = UDim2.fromOffset(24, 24)
MinimizeBtn.Position = UDim2.new(1, -92, 0, 8)
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
local MINI_HEIGHT = 128
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

-- Big EXP number
local MiniExp = Instance.new("TextLabel")
MiniExp.Name = "MiniExp"
MiniExp.Size = UDim2.new(1, -20, 0, 36)
MiniExp.Position = UDim2.fromOffset(10, 34)
MiniExp.BackgroundTransparency = 1
MiniExp.Text = "0"
MiniExp.TextColor3 = GREEN
MiniExp.TextSize = 28
MiniExp.Font = Enum.Font.GothamBlack
MiniExp.TextXAlignment = Enum.TextXAlignment.Left
MiniExp.Parent = MiniBar

local MiniMax = Instance.new("TextLabel")
MiniMax.Size = UDim2.new(0.55, 0, 0, 16)
MiniMax.Position = UDim2.fromOffset(10, 70)
MiniMax.BackgroundTransparency = 1
MiniMax.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
MiniMax.TextColor3 = MUTED
MiniMax.TextSize = 11
MiniMax.Font = Enum.Font.Gotham
MiniMax.TextXAlignment = Enum.TextXAlignment.Left
MiniMax.Parent = MiniBar

-- Right side: time + state
local MiniTime = Instance.new("TextLabel")
MiniTime.Name = "MiniTime"
MiniTime.Size = UDim2.new(0.42, 0, 0, 20)
MiniTime.Position = UDim2.new(1, -12, 0, 38)
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
MiniState.Size = UDim2.new(0.42, 0, 0, 16)
MiniState.Position = UDim2.new(1, -12, 0, 58)
MiniState.AnchorPoint = Vector2.new(1, 0)
MiniState.BackgroundTransparency = 1
MiniState.Text = "Idle"
MiniState.TextColor3 = MUTED
MiniState.TextSize = 11
MiniState.Font = Enum.Font.Gotham
MiniState.TextXAlignment = Enum.TextXAlignment.Right
MiniState.Parent = MiniBar

-- Progress bar at bottom of mini card
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
		Status.Position = UDim2.new(1, -86, 0, 8)
		Status.Size = UDim2.fromOffset(40, 18)
		MinimizeBtn.Position = UDim2.new(1, -40, 0, 6)
		MinimizeBtn.Size = UDim2.fromOffset(28, 22)
	else
		Header.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
		Main.Size = UDim2.fromScale(configuration.MainWidthScale, configuration.MainHeightScale)
		Header.Size = UDim2.fromScale(1, 0.09)
		if SavedMainPosition then
			Main.Position = SavedMainPosition
		else
			Main.Position = UDim2.fromScale(0.5 - configuration.MainWidthScale / 2, 0.5 - configuration.MainHeightScale / 2)
		end
		Status.Position = UDim2.new(1, -62, 0, 10)
		Status.Size = UDim2.fromOffset(48, 20)
		MinimizeBtn.Position = UDim2.new(1, -92, 0, 8)
		MinimizeBtn.Size = UDim2.fromOffset(24, 24)
	end
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

configuration.AddPageHeading(ExpPage, "Experience", "Track your EXP progress and current farming session")
configuration.AddPageHeading(ESPPage, "Player ESP", "Choose which player markers to show")
configuration.AddPageHeading(PlayerPage, "Players", "Follow target, spacing, server players and whitelist")
configuration.AddPageHeading(AlertsPage, "Alerts", "Notifications and idle behavior")
configuration.AddPageHeading(FarmPage, "Farming", "Set the EXP cycle amount, target range, interval and goal")
configuration.AddPageHeading(CombatPage, "Auto Attack", "Choose a target and control attack, skill and timing")

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
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 22)
	label.LayoutOrder = order
	label.BackgroundTransparency = 1
	label.Text = "  " .. string.upper(text)
	label.TextColor3 = MUTED
	label.TextSize = 10
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = SidebarScroll
	return label
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
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.fromOffset(22, 22)
	iconLabel.Position = UDim2.fromOffset(8, 7)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = icon or "•"
	iconLabel.TextColor3 = MUTED
	iconLabel.TextSize = 14
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.Parent = button

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Label"
	textLabel.Size = UDim2.new(1, -40, 1, 0)
	textLabel.Position = UDim2.fromOffset(34, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextColor3 = TEXT
	textLabel.TextSize = 13
	textLabel.Font = Enum.Font.Gotham
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.Parent = button

	return button
end

configuration.MakeNavSection("Auto Farm", 1)
local NavButtons = {
	EXP    = configuration.MakeNavButton("Experience", "◆", 2),
	Farm   = configuration.MakeNavButton("Farming", "▣", 3),
	Combat = configuration.MakeNavButton("Auto Attack", "⚔", 4),
}
configuration.MakeNavSection("Monitoring", 5)
NavButtons.Alerts = configuration.MakeNavButton("Alerts", "⚠", 6)
NavButtons.Player = configuration.MakeNavButton("Players", "◎", 7)
configuration.MakeNavSection("Visuals", 8)
NavButtons.ESP = configuration.MakeNavButton("Player ESP", "◇", 9)

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
		local icon = button:FindFirstChild("Icon")
		if label then
			label.TextColor3 = selected and SEL_TEXT or TEXT
			label.Font = selected and Enum.Font.GothamBold or Enum.Font.Gotham
		end
		if icon then
			icon.TextColor3 = selected and SEL_TEXT or MUTED
		end
	end
end

for name, button in pairs(NavButtons) do
	button.MouseButton1Click:Connect(function() configuration.SetMainTab(name) end)
end
configuration.SetMainTab("EXP")

--==================================================
-- HERO EXP CARD (big numbers)
--==================================================
InfoCard = Instance.new("Frame")
InfoCard.Size = UDim2.new(1, 0, 0, 208)
InfoCard.LayoutOrder = 2
InfoCard.BackgroundColor3 = CARD
InfoCard.BorderSizePixel = 0
InfoCard.Parent = ExpPage
Instance.new("UICorner", InfoCard).CornerRadius = UDim.new(0, 12)
local InfoStroke = Instance.new("UIStroke", InfoCard)
InfoStroke.Color = BORDER
InfoStroke.Thickness = 1
InfoStroke.Transparency = 0.35

-- Big EXP number (main focus)
local ExpCaption = Instance.new("TextLabel")
ExpCaption.Size = UDim2.new(1, -20, 0, 12)
ExpCaption.Position = UDim2.fromOffset(10, 5)
ExpCaption.BackgroundTransparency = 1
ExpCaption.Text = "TOTAL EXP"
ExpCaption.TextColor3 = ACCENT
ExpCaption.TextSize = 9
ExpCaption.Font = Enum.Font.GothamBold
ExpCaption.TextXAlignment = Enum.TextXAlignment.Center
ExpCaption.Parent = InfoCard

local ExpLabel = Instance.new("TextLabel")
ExpLabel.Size = UDim2.new(1, -20, 0, 48)
ExpLabel.Position = UDim2.fromOffset(10, 18)
ExpLabel.BackgroundTransparency = 1
ExpLabel.Text = "0"
ExpLabel.TextColor3 = GREEN
ExpLabel.TextSize = 38
ExpLabel.Font = Enum.Font.GothamBlack
ExpLabel.TextXAlignment = Enum.TextXAlignment.Center
ExpLabel.Parent = InfoCard

local MaxLabel = Instance.new("TextLabel")
MaxLabel.Size = UDim2.new(1, -20, 0, 16)
MaxLabel.Position = UDim2.fromOffset(10, 66)
MaxLabel.BackgroundTransparency = 1
MaxLabel.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
MaxLabel.TextColor3 = MUTED
MaxLabel.TextSize = 12
MaxLabel.Font = Enum.Font.Gotham
MaxLabel.TextXAlignment = Enum.TextXAlignment.Center
MaxLabel.Parent = InfoCard

-- Progress bar
local BarBg = Instance.new("Frame")
BarBg.Size = UDim2.new(1, -28, 0, 8)
BarBg.Position = UDim2.fromOffset(14, 88)
BarBg.BackgroundColor3 = INPUT
BarBg.BorderSizePixel = 0
BarBg.Parent = InfoCard
Instance.new("UICorner", BarBg).CornerRadius = UDim.new(1, 0)

local Bar = Instance.new("Frame")
Bar.Size = UDim2.fromScale(0, 1)
Bar.BackgroundColor3 = ACCENT
Bar.BorderSizePixel = 0
Bar.Parent = BarBg
Instance.new("UICorner", Bar).CornerRadius = UDim.new(1, 0)

local PercentLabel = Instance.new("TextLabel")
PercentLabel.Size = UDim2.new(1, 0, 0, 14)
PercentLabel.Position = UDim2.fromOffset(0, 100)
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
TargetLabel.Position = UDim2.fromOffset(12, 120)
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
DistLabel.Position = UDim2.new(0.58, 0, 0, 120)
DistLabel.BackgroundTransparency = 1
DistLabel.Text = "Dist  -"
DistLabel.TextColor3 = MUTED
DistLabel.TextSize = 11
DistLabel.Font = Enum.Font.Gotham
DistLabel.TextXAlignment = Enum.TextXAlignment.Right
DistLabel.Parent = InfoCard

-- Meta row 2: Time + Rate + State
local TimeLabel = Instance.new("TextLabel")
TimeLabel.Size = UDim2.new(0.38, -4, 0, 15)
TimeLabel.Position = UDim2.fromOffset(12, 140)
TimeLabel.BackgroundTransparency = 1
TimeLabel.Text = "00:00:00"
TimeLabel.TextColor3 = YELLOW
TimeLabel.TextSize = 11
TimeLabel.Font = Enum.Font.GothamBold
TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
TimeLabel.Parent = InfoCard

local RateLabel = Instance.new("TextLabel")
RateLabel.Size = UDim2.new(0.32, -4, 0, 15)
RateLabel.Position = UDim2.new(0.36, 0, 0, 140)
RateLabel.BackgroundTransparency = 1
RateLabel.Text = "Rate -"
RateLabel.TextColor3 = MUTED
RateLabel.TextSize = 11
RateLabel.Font = Enum.Font.Gotham
RateLabel.TextXAlignment = Enum.TextXAlignment.Center
RateLabel.Parent = InfoCard

local StateLabel = Instance.new("TextLabel")
StateLabel.Size = UDim2.new(0.32, -10, 0, 15)
StateLabel.Position = UDim2.new(0.68, 0, 0, 140)
StateLabel.BackgroundTransparency = 1
StateLabel.Text = "Idle"
StateLabel.TextColor3 = MUTED
StateLabel.TextSize = 11
StateLabel.Font = Enum.Font.Gotham
StateLabel.TextXAlignment = Enum.TextXAlignment.Right
StateLabel.Parent = InfoCard

-- Session + recent
local SessionLabel = Instance.new("TextLabel")
SessionLabel.Size = UDim2.new(1, -24, 0, 14)
SessionLabel.Position = UDim2.fromOffset(12, 162)
SessionLabel.BackgroundTransparency = 1
SessionLabel.Text = "Session: +0 EXP / 00:00:00 / 0 EXP/h"
SessionLabel.TextColor3 = MUTED
SessionLabel.TextSize = 10
SessionLabel.Font = Enum.Font.Gotham
SessionLabel.TextXAlignment = Enum.TextXAlignment.Left
SessionLabel.Parent = InfoCard

local RecentCycleLabel = Instance.new("TextLabel")
RecentCycleLabel.Size = UDim2.new(1, -24, 0, 14)
RecentCycleLabel.Position = UDim2.fromOffset(12, 182)
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
-- TOGGLE GRID (2 columns)
--==================================================
ToggleGrid = Instance.new("Frame")
ToggleGrid.Size = UDim2.new(1, 0, 0, 80)
ToggleGrid.LayoutOrder = 2
ToggleGrid.BackgroundTransparency = 1
ToggleGrid.Parent = ESPPage

local GridLayout = Instance.new("UIGridLayout", ToggleGrid)
GridLayout.CellSize = UDim2.new(0.5, -4, 0, 36)
GridLayout.CellPadding = UDim2.fromOffset(8, 8)
GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
GridLayout.FillDirectionMaxCells = 2

function configuration.MakeToggleGrid(parent, order)
	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, 0, 0, 40)
	grid.LayoutOrder = order
	grid.BackgroundTransparency = 1
	grid.Parent = parent
	local layout = Instance.new("UIGridLayout", grid)
	layout.CellSize = UDim2.new(0.5, -4, 0, 36)
	layout.CellPadding = UDim2.fromOffset(8, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirectionMaxCells = 2
	return grid
end

local AlertsGrid = configuration.MakeToggleGrid(AlertsPage, 2)
AlertsGrid.Size = UDim2.new(1, 0, 0, 80)
local PlayersGrid = configuration.MakeToggleGrid(PlayerPage, 2)
PlayersGrid.Size = UDim2.new(1, 0, 0, 120)
local CombatGrid = configuration.MakeToggleGrid(CombatPage, 2)
CombatGrid.Size = UDim2.new(1, 0, 0, 80)
local AttackModeGrid = configuration.MakeToggleGrid(CombatPage, 3)
AttackModeGrid.Size = UDim2.new(1, 0, 0, 80)

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

function configuration.MakeToggle(text, isOn, onColor, onBg, order, parent)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromScale(1, 1)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = isOn and onBg or CARD
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = isOn and onColor or MUTED
	btn.TextSize = 12
	btn.Font = Enum.Font.GothamBold
	btn.Parent = parent or ToggleGrid
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
	return btn
end

function configuration.MakeNumberCard(parent, title, initialValue, order, minValue, maxValue, onChanged)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 48)
	card.LayoutOrder = order
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.58, -16, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = TEXT
	label.TextSize = 11
	label.Font = Enum.Font.Gotham
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = card

	local input = Instance.new("TextBox")
	input.Size = UDim2.new(0.36, -8, 0, 30)
	input.Position = UDim2.new(0.62, 0, 0.5, -15)
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

local FollowDistanceCard, FollowDistanceInput = configuration.MakeNumberCard(
	PlayerPage, "Follow spacing (studs)", function() return configuration.FollowDistance end, 3, 2, 100,
	function(value) configuration.FollowDistance = value end
)

local AutoAttackButton = configuration.MakeToggle(
	configuration.AutoAttackEnabled and "Auto Attack: ON" or "Auto Attack: OFF",
	configuration.AutoAttackEnabled, RED, RED_DIM, 1, CombatGrid
)
local AutoSkillButton = configuration.MakeToggle(
	configuration.AutoSkillEnabled and "Auto Skill: ON" or "Auto Skill: OFF",
	configuration.AutoSkillEnabled, ACCENT, ACCENT_DIM, 2, CombatGrid
)
CombatTargetButton = configuration.MakeToggle("Choose player target", false, TEXT, CARD, 3, CombatGrid)
CombatTargetButton.TextColor3 = TEXT
local ExpMobTargetButton = configuration.MakeToggle(
	configuration.AutoAttackUseExpTarget and "Mob EXP: ON" or "Mob EXP: OFF",
	configuration.AutoAttackUseExpTarget, ACCENT, ACCENT_DIM, 4, CombatGrid
)

local AutoAttackModeButtons = {
	Mob = configuration.MakeToggle("Mob", configuration.AutoAttackMode == "Mob", ACCENT, ACCENT_DIM, 1, AttackModeGrid),
	Player = configuration.MakeToggle("Player", configuration.AutoAttackMode == "Player", ACCENT, ACCENT_DIM, 2, AttackModeGrid),
	Nearby = configuration.MakeToggle("Nearest: Mob / Player", configuration.AutoAttackMode == "Nearby", ACCENT, ACCENT_DIM, 3, AttackModeGrid),
}

local AutoAttackRangeCard, AutoAttackRangeInput = configuration.MakeNumberCard(
	CombatPage, "Attack target range (studs)", function() return configuration.AutoAttackRange end, 4, 5, 500,
	function(value) configuration.AutoAttackRange = value end
)

local AutoAttackSearchRangeCard, AutoAttackSearchRangeInput = configuration.MakeNumberCard(
	CombatPage, "Mob search range (studs)", function() return configuration.AutoAttackSearchRange end, 5, 5, 100000,
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
local CombatMobRefreshQueued = false
function configuration.RefreshCombatMobs()
	for _, row in ipairs(configuration.CombatMobRows) do
		row:Destroy()
	end
	table.clear(configuration.CombatMobRows)

	local entries = {}
	local groupCounts = {}
	local groupHasLevels = {}
	local function numericValue(value)
		if typeof(value) == "Instance" then
			if value:IsA("ValueBase") then return tonumber(value.Value) end
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

	for _, mob in ipairs(MobsFolder:GetChildren()) do
		local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and (not humanoid or humanoid.Health > 0) then
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
		local isSelectedMob = configuration.AutoAttackPinnedMob == selectedMob or configuration.CombatTargetMob == selectedMob
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -8, 0, 30)
		row.LayoutOrder = order
		row.BackgroundColor3 = isSelectedMob and ACCENT_DIM or INPUT
		row.BorderSizePixel = 0
		row.Text = string.format("%s%s  •  Lv %s  •  EXP %s", isSelectedMob and "✓  " or "", entry.Name,
			entry.Level and tostring(entry.Level) or "—", entry.EXP > -math.huge and tostring(entry.EXP) or "—")
		row.TextColor3 = isSelectedMob and ACCENT or TEXT
		row.TextSize = 11
		row.Font = Enum.Font.Gotham
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Parent = CombatMobScroll
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
		row.MouseButton1Click:Connect(function()
			if not selectedMob:IsDescendantOf(MobsFolder) then
				configuration.RefreshCombatMobs()
				return
			end
			configuration.AutoAttackUseExpTarget = false
			configuration.UpdateExpMobTargetButton()
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
	if CombatMobRefreshQueued then return end
	CombatMobRefreshQueued = true
	task.delay(0.12, function()
		CombatMobRefreshQueued = false
		if CombatMobScroll.Parent then
			configuration.RefreshCombatMobs()
		end
	end)
end

CombatMobRefresh.MouseButton1Click:Connect(configuration.RefreshCombatMobs)
MobsFolder.ChildAdded:Connect(configuration.RequestCombatMobRefresh)
MobsFolder.ChildRemoved:Connect(configuration.RequestCombatMobRefresh)
configuration.RefreshCombatMobs()

local CombatInfo = Instance.new("TextLabel")
CombatInfo.Size = UDim2.new(1, -8, 0, 34)
CombatInfo.LayoutOrder = 10
CombatInfo.BackgroundTransparency = 1
CombatInfo.Text = "Combat pauses during EXP firing. At EXP Max or Alert, it attacks the locked EXP target."
CombatInfo.TextColor3 = MUTED
CombatInfo.TextSize = 10
CombatInfo.Font = Enum.Font.Gotham
CombatInfo.TextWrapped = true
CombatInfo.TextXAlignment = Enum.TextXAlignment.Left
CombatInfo.Parent = CombatPage

function configuration.UpdateAttackTargetButton()
	local targetPlayer = configuration.AutoAttackTargetUserId and Players:GetPlayerByUserId(tonumber(configuration.AutoAttackTargetUserId))
	CombatTargetButton.Text = targetPlayer and ("Target: @" .. targetPlayer.Name) or "Choose player target"
	CombatTargetButton.TextColor3 = targetPlayer and YELLOW or TEXT
	CombatTargetButton.BackgroundColor3 = targetPlayer and Color3.fromRGB(62, 52, 30) or CARD
end
configuration.UpdateAttackTargetButton()

function configuration.UpdateAutoAttackModeButtons()
	for mode, button in pairs(AutoAttackModeButtons) do
		local selected = configuration.AutoAttackMode == mode
		button.TextColor3 = selected and ACCENT or MUTED
		button.BackgroundColor3 = selected and ACCENT_DIM or CARD
	end
	if configuration.RefreshCombatMobs then configuration.RefreshCombatMobs() end
end
configuration.UpdateAutoAttackModeButtons()

function configuration.UpdateExpMobTargetButton()
	ExpMobTargetButton.Text = configuration.AutoAttackUseExpTarget and "Mob EXP: ON" or "Mob EXP: OFF"
	ExpMobTargetButton.TextColor3 = configuration.AutoAttackUseExpTarget and ACCENT or MUTED
	ExpMobTargetButton.BackgroundColor3 = configuration.AutoAttackUseExpTarget and ACCENT_DIM or CARD
end

ExpMobTargetButton.MouseButton1Click:Connect(function()
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
	AutoAttackButton.Text = configuration.AutoAttackEnabled and "Auto Attack: ON" or "Auto Attack: OFF"
	AutoAttackButton.TextColor3 = configuration.AutoAttackEnabled and RED or MUTED
	AutoAttackButton.BackgroundColor3 = configuration.AutoAttackEnabled and RED_DIM or CARD
	configuration.SaveConfig()
end)

AutoSkillButton.MouseButton1Click:Connect(function()
	configuration.AutoSkillEnabled = not configuration.AutoSkillEnabled
	AutoSkillButton.Text = configuration.AutoSkillEnabled and "Auto Skill: ON" or "Auto Skill: OFF"
	AutoSkillButton.TextColor3 = configuration.AutoSkillEnabled and ACCENT or MUTED
	AutoSkillButton.BackgroundColor3 = configuration.AutoSkillEnabled and ACCENT_DIM or CARD
	if configuration.AutoSkillEnabled and not configuration.Farming and configuration.CurrentTarget
		and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
		configuration.AutoAttackPinnedMob = configuration.CurrentTarget
		configuration.CombatTargetMob = configuration.CurrentTarget
	end
	configuration.SaveConfig()
end)

for mode, button in pairs(AutoAttackModeButtons) do
	button.MouseButton1Click:Connect(function()
		configuration.AutoAttackMode = mode
		if mode ~= "Mob" then
			if configuration.AutoAttackUseExpTarget then
				configuration.AutoAttackUseExpTarget = false
				configuration.AutoAttackPinnedMob = nil
				configuration.CombatTargetMob = nil
				configuration.UpdateExpMobTargetButton()
			end
		end
		configuration.UpdateAutoAttackModeButtons()
		configuration.SaveConfig()
	end)
end

local AlertToggleButton = configuration.MakeToggle(configuration.AlertsEnabled and "Alerts: ON" or "Alerts: OFF", configuration.AlertsEnabled, GREEN, GREEN_DIM, 1, AlertsGrid)
local AlertFlashButton = configuration.MakeToggle(
	configuration.AlertFlashEnabled and "Screen flash: ON" or "Screen flash: OFF",
	configuration.AlertFlashEnabled, RED, RED_DIM, 2, AlertsGrid
)
local AutoResumeButton = configuration.MakeToggle(
	configuration.AutoResumeAfterAlert and "Resume after Alert: ON" or "Resume after Alert: OFF",
	configuration.AutoResumeAfterAlert, ACCENT, ACCENT_DIM, 3, AlertsGrid
)
local ESPToggleButton = configuration.MakeToggle(configuration.ESPEnabled and "ESP: ON" or "ESP: OFF", configuration.ESPEnabled, ACCENT, ACCENT_DIM, 2)
local ESPLineButton = configuration.MakeToggle(configuration.ESPLineEnabled and "Lines: ON" or "Lines: OFF", configuration.ESPLineEnabled, ACCENT, ACCENT_DIM, 3)
local ESPBoxButton = configuration.MakeToggle(configuration.ESPBoxEnabled and "Boxes: ON" or "Boxes: OFF", configuration.ESPBoxEnabled, ACCENT, ACCENT_DIM, 4)
local AutoBlockButton = configuration.MakeToggle(configuration.AutoBlockEnabled and "Auto Block: ON" or "Auto Block: OFF", configuration.AutoBlockEnabled, RED, RED_DIM, 5, PlayersGrid)
local PlayerListButton = configuration.MakeToggle("Open player list", false, TEXT, CARD, 1, PlayersGrid)
PlayerListButton.TextColor3 = TEXT
local WhitelistButton = configuration.MakeToggle("Whitelist IDs", false, TEXT, CARD, 2, PlayersGrid)
WhitelistButton.TextColor3 = TEXT
FollowSelectButton = configuration.MakeToggle("Choose follow target", false, TEXT, CARD, 3, PlayersGrid)
FollowSelectButton.TextColor3 = TEXT
StopFollowButton = configuration.MakeToggle("Stop following", false, TEXT, CARD, 4, PlayersGrid)
StopFollowButton.TextColor3 = TEXT

function configuration.UpdateFollowButtons()
	local following = configuration.FollowPlayerUserId ~= nil
	FollowSelectButton.Text = following and "Change follow target" or "Choose follow target"
	FollowSelectButton.TextColor3 = following and ACCENT or TEXT
	FollowSelectButton.BackgroundColor3 = following and ACCENT_DIM or CARD
	StopFollowButton.TextColor3 = following and RED or MUTED
	StopFollowButton.BackgroundColor3 = following and RED_DIM or CARD
end
configuration.UpdateFollowButtons()

-- placeholder to keep grid even (empty)
local SpacerToggle = Instance.new("Frame")
SpacerToggle.LayoutOrder = 8
SpacerToggle.BackgroundTransparency = 1
SpacerToggle.Parent = ToggleGrid

AlertToggleButton.MouseButton1Click:Connect(function()
	configuration.AlertsEnabled = not configuration.AlertsEnabled
	AlertToggleButton.Text = configuration.AlertsEnabled and "Alerts: ON" or "Alerts: OFF"
	AlertToggleButton.TextColor3 = configuration.AlertsEnabled and GREEN or MUTED
	AlertToggleButton.BackgroundColor3 = configuration.AlertsEnabled and GREEN_DIM or CARD
	configuration.SaveConfig()
	if not configuration.AlertsEnabled then
		AlarmOverlay.Visible = false
	end
end)

AlertFlashButton.MouseButton1Click:Connect(function()
	configuration.AlertFlashEnabled = not configuration.AlertFlashEnabled
	AlertFlashButton.Text = configuration.AlertFlashEnabled and "Screen flash: ON" or "Screen flash: OFF"
	AlertFlashButton.TextColor3 = configuration.AlertFlashEnabled and RED or MUTED
	AlertFlashButton.BackgroundColor3 = configuration.AlertFlashEnabled and RED_DIM or CARD
	if not configuration.AlertFlashEnabled then AlarmOverlay.Visible = false end
	configuration.SaveConfig()
end)

AutoResumeButton.MouseButton1Click:Connect(function()
	configuration.AutoResumeAfterAlert = not configuration.AutoResumeAfterAlert
	AutoResumeButton.Text = configuration.AutoResumeAfterAlert and "Resume after Alert: ON" or "Resume after Alert: OFF"
	AutoResumeButton.TextColor3 = configuration.AutoResumeAfterAlert and ACCENT or MUTED
	AutoResumeButton.BackgroundColor3 = configuration.AutoResumeAfterAlert and ACCENT_DIM or CARD
	configuration.SaveConfig()
end)

ESPToggleButton.MouseButton1Click:Connect(function()
	configuration.ESPEnabled = not configuration.ESPEnabled
	ESPToggleButton.Text = configuration.ESPEnabled and "ESP: ON" or "ESP: OFF"
	ESPToggleButton.TextColor3 = configuration.ESPEnabled and ACCENT or MUTED
	ESPToggleButton.BackgroundColor3 = configuration.ESPEnabled and ACCENT_DIM or CARD
	configuration.SaveConfig()
end)

ESPLineButton.MouseButton1Click:Connect(function()
	configuration.ESPLineEnabled = not configuration.ESPLineEnabled
	ESPLineButton.Text = configuration.ESPLineEnabled and "Lines: ON" or "Lines: OFF"
	ESPLineButton.TextColor3 = configuration.ESPLineEnabled and ACCENT or MUTED
	ESPLineButton.BackgroundColor3 = configuration.ESPLineEnabled and ACCENT_DIM or CARD
	configuration.SaveConfig()
end)

ESPBoxButton.MouseButton1Click:Connect(function()
	configuration.ESPBoxEnabled = not configuration.ESPBoxEnabled
	ESPBoxButton.Text = configuration.ESPBoxEnabled and "Boxes: ON" or "Boxes: OFF"
	ESPBoxButton.TextColor3 = configuration.ESPBoxEnabled and ACCENT or MUTED
	ESPBoxButton.BackgroundColor3 = configuration.ESPBoxEnabled and ACCENT_DIM or CARD
	configuration.SaveConfig()
end)

AutoBlockButton.MouseButton1Click:Connect(function()
	configuration.AutoBlockEnabled = not configuration.AutoBlockEnabled
	AutoBlockButton.Text = configuration.AutoBlockEnabled and "Auto Block: ON" or "Auto Block: OFF"
	AutoBlockButton.TextColor3 = configuration.AutoBlockEnabled and RED or MUTED
	AutoBlockButton.BackgroundColor3 = configuration.AutoBlockEnabled and RED_DIM or CARD
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
		configuration.PauseTimer()
		configuration.ExpMaxCombatTarget = nil
		configuration.AlertCombatPending = false
		configuration.AlertCombatTarget = nil
		configuration.AlertCombatHold = false
		configuration.AlertCombatBlockReady = false
		configuration.AlertBlockTarget = nil
		configuration.LastAlertCombatUserId = nil
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
			if level.Value >= 300 then
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
local DistBox = configuration.MakeCompactSetting(SettingsCard, "Search radius (studs)", configuration.MaxDistance, 0.5, 24)
local IntervalBox = configuration.MakeCompactSetting(SettingsCard, "Interval (s)", configuration.Interval, 0, 62)
local MaxBox = configuration.MakeCompactSetting(SettingsCard, "EXP Max", configuration.ExpGoal, 0.5, 62)
local ExpApproachBox = configuration.MakeCompactSetting(SettingsCard, "EXP standoff (studs)", configuration.ExpApproachDistance, 0, 100)

AmountBox.FocusLost:Connect(function()
	local v = tonumber(AmountBox.Text)
	if v and v > 0 then configuration.Amount = math.floor(v) end
	AmountBox.Text = tostring(configuration.Amount)
	configuration.SaveConfig()
end)
DistBox.FocusLost:Connect(function()
	local v = tonumber(DistBox.Text)
	if v and v > 0 then
		configuration.MaxDistance = math.clamp(v, configuration.ExpApproachDistance + 5, 100000)
	end
	DistBox.Text = tostring(configuration.MaxDistance)
	configuration.SaveConfig()
end)
ExpApproachBox.FocusLost:Connect(function()
	local v = tonumber(ExpApproachBox.Text)
	if v and v > 0 then
		configuration.ExpApproachDistance = math.clamp(v, 5, 100)
		configuration.MaxDistance = math.max(configuration.MaxDistance, configuration.ExpApproachDistance + 5)
		DistBox.Text = tostring(configuration.MaxDistance)
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
	PlayerListButton.Text = PlayerPanel.Visible and "Close player list" or "Open player list"
	PlayerListButton.TextColor3 = PlayerPanel.Visible and ACCENT or TEXT
end)
PlayerPanelClose.MouseButton1Click:Connect(function()
	PlayerPanel.Visible = false
	configuration.PlayerPanelMode = "server"
	PlayerListButton.Text = "Open player list"
	PlayerListButton.TextColor3 = TEXT
end)

FollowSelectButton.MouseButton1Click:Connect(function()
	configuration.PlayerPanelMode = "follow"
	PlayerPanelTitle.Text = "Choose player to follow"
	PlayerPanel.Visible = true
	PlayerListButton.Text = "Open player list"
	PlayerListButton.TextColor3 = TEXT
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

local WhitelistPanel = Instance.new("Frame")
WhitelistPanel.Name = "WhitelistPanel"
WhitelistPanel.Size = UDim2.fromScale(configuration.WhitelistPanelWidthScale, configuration.WhitelistPanelHeightScale)
WhitelistPanel.Position = UDim2.fromScale(0.04, 0.20)
WhitelistPanel.ZIndex = 90
WhitelistPanel.BackgroundColor3 = BG
WhitelistPanel.BorderSizePixel = 0
WhitelistPanel.Visible = false
WhitelistPanel.Parent = ScreenGui
Instance.new("UICorner", WhitelistPanel).CornerRadius = UDim.new(0, 12)
local WhitelistPanelStroke = Instance.new("UIStroke", WhitelistPanel)
WhitelistPanelStroke.Color = BORDER
WhitelistPanelStroke.Thickness = 1
WhitelistPanelStroke.Transparency = 0.35

local WhitelistHeader = Instance.new("Frame")
WhitelistHeader.Name = "Header"
WhitelistHeader.Size = UDim2.new(1, 0, 0, 44)
WhitelistHeader.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
WhitelistHeader.BorderSizePixel = 0
WhitelistHeader.ZIndex = 91
WhitelistHeader.Parent = WhitelistPanel
Instance.new("UICorner", WhitelistHeader).CornerRadius = UDim.new(0, 12)

local WhitelistHeaderFix = Instance.new("Frame")
WhitelistHeaderFix.Size = UDim2.new(1, 0, 0, 16)
WhitelistHeaderFix.Position = UDim2.new(0, 0, 1, -16)
WhitelistHeaderFix.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
WhitelistHeaderFix.BorderSizePixel = 0
WhitelistHeaderFix.ZIndex = 91
WhitelistHeaderFix.Parent = WhitelistHeader

local WhitelistHeaderRule = Instance.new("Frame")
WhitelistHeaderRule.Size = UDim2.new(1, -20, 0, 1)
WhitelistHeaderRule.Position = UDim2.new(0, 10, 1, -1)
WhitelistHeaderRule.BackgroundColor3 = BORDER
WhitelistHeaderRule.BackgroundTransparency = 0.4
WhitelistHeaderRule.BorderSizePixel = 0
WhitelistHeaderRule.ZIndex = 92
WhitelistHeaderRule.Parent = WhitelistHeader

local WhitelistTitle = Instance.new("TextLabel")
WhitelistTitle.Size = UDim2.new(1, -20, 0, 22)
WhitelistTitle.Position = UDim2.fromOffset(14, 11)
WhitelistTitle.ZIndex = 92
WhitelistTitle.Active = true
WhitelistTitle.BackgroundTransparency = 1
WhitelistTitle.Text = "Whitelist by UserId"
WhitelistTitle.TextColor3 = TEXT
WhitelistTitle.TextSize = 14
WhitelistTitle.Font = Enum.Font.GothamBold
WhitelistTitle.TextXAlignment = Enum.TextXAlignment.Left
WhitelistTitle.Parent = WhitelistHeader

local WhitelistInput = Instance.new("TextBox")
WhitelistInput.Size = UDim2.new(1, -112, 0, 34)
WhitelistInput.Position = UDim2.fromOffset(12, 54)
WhitelistInput.ZIndex = 91
WhitelistInput.BackgroundColor3 = INPUT
WhitelistInput.BorderSizePixel = 0
WhitelistInput.PlaceholderText = "Enter Player UserId"
WhitelistInput.Text = ""
WhitelistInput.TextColor3 = TEXT
WhitelistInput.PlaceholderColor3 = MUTED
WhitelistInput.TextSize = 12
WhitelistInput.Font = Enum.Font.Gotham
WhitelistInput.ClearTextOnFocus = false
WhitelistInput.Parent = WhitelistPanel
Instance.new("UICorner", WhitelistInput).CornerRadius = UDim.new(0, 8)

local AddWhitelistButton = Instance.new("TextButton")
AddWhitelistButton.Size = UDim2.fromOffset(88, 34)
AddWhitelistButton.Position = UDim2.new(1, -100, 0, 54)
AddWhitelistButton.ZIndex = 91
AddWhitelistButton.BackgroundColor3 = ACCENT_DIM
AddWhitelistButton.BorderSizePixel = 0
AddWhitelistButton.Text = "Add ID"
AddWhitelistButton.TextColor3 = ACCENT
AddWhitelistButton.TextSize = 12
AddWhitelistButton.Font = Enum.Font.GothamBold
AddWhitelistButton.Parent = WhitelistPanel
Instance.new("UICorner", AddWhitelistButton).CornerRadius = UDim.new(0, 8)

local WhitelistScroll = Instance.new("ScrollingFrame")
WhitelistScroll.Size = UDim2.new(1, -20, 1, -102)
WhitelistScroll.Position = UDim2.fromOffset(10, 96)
WhitelistScroll.ZIndex = 91
WhitelistScroll.BackgroundTransparency = 1
WhitelistScroll.BorderSizePixel = 0
WhitelistScroll.ScrollBarThickness = 3
WhitelistScroll.ScrollBarImageColor3 = MUTED
WhitelistScroll.CanvasSize = UDim2.new()
WhitelistScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
WhitelistScroll.ScrollingDirection = Enum.ScrollingDirection.Y
WhitelistScroll.Parent = WhitelistPanel

local WhitelistLayout = Instance.new("UIListLayout", WhitelistScroll)
WhitelistLayout.Padding = UDim.new(0, 6)
WhitelistLayout.SortOrder = Enum.SortOrder.LayoutOrder
WhitelistLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

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
configuration.MakeDraggable(WhitelistPanel, WhitelistHeader)

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
configuration.MakeResizable(WhitelistPanel, "WhitelistPanel", 0.26, 0.32, function(width, height)
	configuration.WhitelistPanelWidthScale, configuration.WhitelistPanelHeightScale = width, height
	configuration.SaveConfig()
end)

function configuration.RefreshWhitelist()
	for _, child in ipairs(WhitelistScroll:GetChildren()) do
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
		row.Parent = WhitelistScroll

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
	WhitelistPanel.Visible = not WhitelistPanel.Visible
	if WhitelistPanel.Visible then configuration.RefreshWhitelist() end
end)

function configuration.AddWhitelistId()
	local idText = WhitelistInput.Text:match("^%s*(%d+)%s*$")
	if not idText then
		WhitelistInput.Text = ""
		WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	local userId = idText:gsub("^0+", "")
	if userId == "" then
		WhitelistInput.Text = ""
		WhitelistInput.PlaceholderText = "Enter a valid UserId"
		return
	end
	configuration.WhitelistIds[userId] = true
	WhitelistInput.Text = ""
	WhitelistInput.PlaceholderText = "Enter Player UserId"
	configuration.SaveConfig()
	configuration.RefreshWhitelist()
end

AddWhitelistButton.MouseButton1Click:Connect(configuration.AddWhitelistId)
WhitelistInput.FocusLost:Connect(function(enterPressed)
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

local AlarmText = Instance.new("TextLabel")
AlarmText.Size = UDim2.new(1, 0, 0, 72)
AlarmText.Position = UDim2.new(0, 0, 0.5, -36)
AlarmText.BackgroundTransparency = 1
AlarmText.Text = ""
AlarmText.TextColor3 = Color3.new(1, 1, 1)
AlarmText.TextStrokeTransparency = 0.15
AlarmText.TextSize = 30
AlarmText.Font = Enum.Font.GothamBlack
AlarmText.ZIndex = 101
AlarmText.Parent = AlarmOverlay

local PlayerEspLayer = Instance.new("Frame")
PlayerEspLayer.Name = "PlayerESPLayer"
PlayerEspLayer.Size = UDim2.fromScale(1, 1)
PlayerEspLayer.BackgroundTransparency = 1
PlayerEspLayer.Active = false
PlayerEspLayer.ZIndex = 0
PlayerEspLayer.Parent = ScreenGui

local ResizeHandle = Instance.new("TextButton")
ResizeHandle.Name = "ResizeHandle"
ResizeHandle.Size = UDim2.fromScale(0.065, 0.032)
ResizeHandle.AnchorPoint = Vector2.new(1, 1)
ResizeHandle.Position = UDim2.fromScale(1, 1)
ResizeHandle.ZIndex = 95
ResizeHandle.BackgroundColor3 = INPUT
ResizeHandle.BackgroundTransparency = 0.2
ResizeHandle.BorderSizePixel = 0
ResizeHandle.Text = "◢"
ResizeHandle.TextColor3 = MUTED
ResizeHandle.TextSize = 12
ResizeHandle.Font = Enum.Font.GothamBold
ResizeHandle.Parent = Main
Instance.new("UICorner", ResizeHandle).CornerRadius = UDim.new(0, 6)

local Resizing, ResizeStart, ResizeStartSize = false, nil, nil
ResizeHandle.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		Resizing = true
		ResizeStart = input.Position
		ResizeStartSize = Vector2.new(configuration.MainWidthScale, configuration.MainHeightScale)
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
	local maxWidth = math.max(0.2, math.min(0.75, 1 - Main.Position.X.Scale))
	local maxHeight = math.max(0.4, math.min(0.95, 1 - Main.Position.Y.Scale))
	configuration.MainWidthScale = math.clamp(ResizeStartSize.X + delta.X / viewport.X, 0.2, maxWidth)
	if not configuration.IsMinimized then
		configuration.MainHeightScale = math.clamp(ResizeStartSize.Y + delta.Y / viewport.Y, 0.4, maxHeight)
	end
	if configuration.IsMinimized then
		Main.Size = UDim2.fromOffset(MINI_WIDTH, MINI_HEIGHT)
	else
		Main.Size = UDim2.fromScale(configuration.MainWidthScale, configuration.MainHeightScale)
	end
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

function configuration.SetIdle()
	if configuration.Farming and not configuration.AlertCombatPending and configuration.AutoSkillEnabled
		and configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
		configuration.AutoAttackPinnedMob = configuration.CurrentTarget
		configuration.CombatTargetMob = configuration.CurrentTarget
	end
	configuration.Farming = false
	configuration.PauseTimer()
	StartBtn.Text = "Start"
	StartBtn.BackgroundColor3 = ACCENT
	Status.Text = "OFF"
	Status.TextColor3 = RED
	Status.BackgroundColor3 = RED_DIM
	StateLabel.Text = "Stopped"
	MiniState.Text = "Stopped"
	TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime)
			MiniTime.Text = TimeLabel.Text
end

function configuration.SetRunning()
	if configuration.AlertCombatPending or configuration.AlertCombatHold or configuration.AlertCombatBlockReady then return end
	configuration.EmergencyStopActive = false
	if configuration.UpdateEmergencyStopButton then configuration.UpdateEmergencyStopButton() end
	configuration.Farming = true
	configuration.ExpMaxCombatTarget = nil
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
		configuration.SetIdle()
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

	local best, bestDist = nil, math.huge
	local mobs = MobsFolder:GetChildren()
	for _, mob in ipairs(mobs) do
		local cfg = mob:FindFirstChild("Config")
		local exp = cfg and cfg:FindFirstChild("EXP")
		local mroot = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		if exp and (exp:IsA("IntValue") or exp:IsA("NumberValue"))
			and mroot and mroot:IsA("BasePart")
			and exp.Value < configuration.ExpGoal then
			local d = (root.Position - mroot.Position).Magnitude
			if d <= configuration.MaxDistance and d < bestDist then
				bestDist = d
				best = mob
			end
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

function configuration.Combat.FindNearestCombatMob(localRoot, maxDistance)
	local bestMob, bestRoot, bestDistance = nil, nil, maxDistance or configuration.AutoAttackSearchRange
	for _, mob in ipairs(MobsFolder:GetChildren()) do
		local mobRoot = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		if mobRoot and mobRoot:IsA("BasePart") and (not humanoid or humanoid.Health > 0) then
			local distance = (localRoot.Position - mobRoot.Position).Magnitude
			if distance <= bestDistance then
				bestMob, bestRoot, bestDistance = mob, mobRoot, distance
			end
		end
	end
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
	if configuration.AlertCombatPending then
		local alertMob = configuration.AlertCombatTarget
		local alertRoot = alertMob and (alertMob.PrimaryPart or alertMob:FindFirstChild("HumanoidRootPart"))
		if configuration.Combat.IsLivingMob(alertMob) and alertRoot and alertRoot:IsA("BasePart") then
			return "Mob", alertMob, alertRoot, (localRoot.Position - alertRoot.Position).Magnitude
		end
		return nil
	end

	local maxedExpMob = configuration.ExpMaxCombatTarget
	if maxedExpMob then
		local maxedRoot = maxedExpMob.PrimaryPart or maxedExpMob:FindFirstChild("HumanoidRootPart")
		if configuration.Combat.IsLivingMob(maxedExpMob) and maxedRoot and maxedRoot:IsA("BasePart") then
			return "Mob", maxedExpMob, maxedRoot, (localRoot.Position - maxedRoot.Position).Magnitude
		end
		configuration.ExpMaxCombatTarget = nil
	end

	if configuration.AutoAttackMode == "Player" then
		local targetPlayer, targetRoot = configuration.Combat.FindCombatPlayer(configuration.AutoAttackTargetUserId)
		if targetPlayer then
			return "Player", targetPlayer, targetRoot, (localRoot.Position - targetRoot.Position).Magnitude
		end
		return nil
	end

	if configuration.AutoAttackMode == "Mob" then
		local lockedMob
		if configuration.AutoAttackUseExpTarget then
			lockedMob = configuration.CurrentTarget
			if not configuration.Combat.IsLivingMob(lockedMob) then return nil end
		else
			lockedMob = configuration.AutoAttackPinnedMob or configuration.CombatTargetMob
		end
		if lockedMob then
			local lockedHumanoid = lockedMob:FindFirstChildOfClass("Humanoid")
			local lockedRoot = lockedMob.PrimaryPart or lockedMob:FindFirstChild("HumanoidRootPart")
			if lockedMob:IsDescendantOf(MobsFolder) and (not lockedHumanoid or lockedHumanoid.Health > 0)
				and lockedRoot and lockedRoot:IsA("BasePart") then
				configuration.CombatTargetMob = lockedMob
				return "Mob", lockedMob, lockedRoot, (localRoot.Position - lockedRoot.Position).Magnitude
			end
			if configuration.AutoAttackPinnedMob == lockedMob then configuration.AutoAttackPinnedMob = nil end
			configuration.CombatTargetMob = nil
		end

		local nearestMob, nearestRoot, nearestDistance = configuration.Combat.FindNearestCombatMob(localRoot)
		if nearestMob then
			configuration.CombatTargetMob = nearestMob
			if configuration.RefreshCombatMobs then configuration.RefreshCombatMobs() end
			return "Mob", nearestMob, nearestRoot, nearestDistance
		end
		return nil
	end

	local mob, mobRoot, mobDistance = configuration.Combat.FindNearestCombatMob(localRoot)

	local nearestPlayer, nearestRoot, nearestDistance
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= Player and not configuration.IsWhitelisted(otherPlayer) then
			local character = otherPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
			if targetRoot and targetRoot:IsA("BasePart") and (not humanoid or humanoid.Health > 0) then
				local distance = (localRoot.Position - targetRoot.Position).Magnitude
				if distance <= configuration.AutoAttackRange and (not nearestDistance or distance < nearestDistance) then
					nearestPlayer, nearestRoot, nearestDistance = otherPlayer, targetRoot, distance
				end
			end
		end
	end
	if nearestPlayer and (not mob or nearestDistance < mobDistance) then
		return "Player", nearestPlayer, nearestRoot, nearestDistance
	end
	if mob then return "Mob", mob, mobRoot, mobDistance end
	return nil
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
	local lastExpMoveAt = 0
	local chasingExpTarget = nil
	local watchedTarget = nil
	local lastObservedExp = nil
	local lastExpProgressAt = 0
	while true do
		if not configuration.Farming or configuration.EmergencyStopActive then
			if watchedTarget then
				local watchedConfig = watchedTarget:FindFirstChild("Config")
				local watchedExp = watchedConfig and watchedConfig:FindFirstChild("EXP")
				if watchedExp then lastObservedExp = watchedExp.Value end
				lastExpProgressAt = os.clock()
			end
			if chasingExpTarget then
				local character = Player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
			end
			task.wait(0.1)
			continue
		end

		local target = configuration.CurrentTarget

		if target and configuration.Combat.IsLivingMob(target) then
			-- ยึดตัวเดิม
		else
			if chasingExpTarget then
				local character = Player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
			end
			if configuration.ExpMaxCombatTarget == target then
				configuration.ExpMaxCombatTarget = nil
			end
			configuration.ClearBillboard()
			configuration.CurrentTarget = nil
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
			configuration.AttachBillboard(target, exp and exp.Value or 0)

			-- เริ่มจับเวลา rate ของมอนตัวนี้
			configuration.SessionStartEXP = exp and exp.Value or 0
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

		TargetLabel.Text = target.Name
		ExpLabel.Text = configuration.FormatNumber(exp.Value)
		MaxLabel.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
		DistLabel.Text = "Dist  " .. string.format("%.1f", dist)

		-- Walk toward the locked EXP mob and hold the configured firing distance.
		if exp.Value < configuration.ExpGoal and root and mroot then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			if dist > configuration.ExpApproachDistance + 1 then
				if humanoid and (chasingExpTarget ~= target or os.clock() - lastExpMoveAt >= 0.4) then
					local flatOffset = Vector3.new(
						root.Position.X - mroot.Position.X,
						0,
						root.Position.Z - mroot.Position.Z
					)
					if flatOffset.Magnitude < 0.1 then
						flatOffset = Vector3.new(mroot.CFrame.LookVector.X, 0, mroot.CFrame.LookVector.Z)
					end
					if flatOffset.Magnitude < 0.1 then flatOffset = Vector3.new(1, 0, 0) end
					humanoid:MoveTo(mroot.Position + flatOffset.Unit * configuration.ExpApproachDistance)
					chasingExpTarget = target
					lastExpMoveAt = os.clock()
				end
			elseif chasingExpTarget then
				if humanoid then humanoid:MoveTo(root.Position) end
				chasingExpTarget = nil
			end
		elseif chasingExpTarget then
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			if humanoid and root then humanoid:MoveTo(root.Position) end
			chasingExpTarget = nil
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

		if dist > configuration.ExpApproachDistance + 1 then
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

		-- ยิงเฉพาะจำนวนที่เหลือถึง Max (กันยิงเกิน)
		local remaining = configuration.ExpGoal - exp.Value
		local toFire = math.min(configuration.Amount, math.max(0, remaining))
		local cycleStartExp = exp.Value
		local cycleStartTime = os.clock()
		local callsSent = 0

		for i = 1, toFire do
			if not configuration.Farming or configuration.EmergencyStopActive then break end
			if not target:IsDescendantOf(MobsFolder) then break end
			if exp.Value >= configuration.ExpGoal then break end

			-- Sync Auto Attack's mob target to EXP when the target toggle is enabled.
			if configuration.AutoAttackUseExpTarget then
				configuration.AutoAttackPinnedMob = target
				configuration.CombatTargetMob = target
			end
			InitClashing:FireServer(2, exp)
			callsSent += 1

			-- ใกล้ Max แล้ว → ยิงช้าลง + รอค่าอัปเดต
			if exp.Value >= configuration.ExpGoal - 200 then
				task.wait(0.02)
			elseif i % 50 == 0 then
				-- เว้นจังหวะเล็กน้อยทุก 50 ครั้ง ให้ Value มีโอกาส replicate
				task.wait()
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
	local lastMoveAt = 0
	local lastEquipAt = 0
	local chasingMob = false
	while true do
		local canCombatWhileExpMaxed = configuration.Farming and configuration.ExpMaxCombatTarget ~= nil
		if not configuration.EmergencyStopActive
			and (configuration.AutoAttackEnabled or configuration.AutoSkillEnabled or configuration.AlertCombatPending)
			and not configuration.AlertCombatHold
			and (not configuration.Farming or canCombatWhileExpMaxed) and not configuration.AlertCombatBlockReady then
			local character = Player.Character
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			local targetKind, target, targetRoot, distance
			if localRoot then
				targetKind, target, targetRoot, distance = configuration.Combat.FindAutoAttackTarget(localRoot)
			end
			if target and targetRoot then
				if targetKind == "Mob" and localRoot and (configuration.AutoAttackEnabled or configuration.AlertCombatPending) then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					local now = os.clock()
					if distance > configuration.AutoAttackStandoff + 1 then
						if humanoid and now - lastMoveAt >= 0.3 then
							local flatOffset = Vector3.new(
								localRoot.Position.X - targetRoot.Position.X,
								0,
								localRoot.Position.Z - targetRoot.Position.Z
							)
							if flatOffset.Magnitude < 0.1 then
								flatOffset = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
							end
							local approachPoint = targetRoot.Position + flatOffset.Unit * configuration.AutoAttackStandoff
							humanoid:MoveTo(approachPoint)
							lastMoveAt = now
							chasingMob = true
						end
					elseif chasingMob and humanoid and now - lastMoveAt >= 0.4 then
						humanoid:MoveTo(localRoot.Position)
						lastMoveAt = now
						chasingMob = false
					end
				elseif chasingMob then
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
					chasingMob = false
				end

				if distance <= configuration.AutoAttackRange then
					local playerGui = Player:FindFirstChildOfClass("PlayerGui")
					local inputFunction = playerGui and playerGui:FindFirstChild("InputBindableFunction", true)
					if inputFunction and inputFunction:IsA("BindableFunction") then
						local now = os.clock()
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						local hasWeapon, needsEquip = configuration.Combat.GetWeaponEquipState(character)
						local canAttack = humanoid and humanoid.Health > 0 and hasWeapon
						if not canAttack then
							CombatInfo.Text = needsEquip and "Waiting for Sword; trying EquipButton before attacking." or "Waiting for PlayerStats and Sword/MainWeld."
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
							CombatInfo.Text = configuration.AlertCombatPending and "Alert response: attacking only the locked EXP target." or "Weapon ready; Auto Attack can engage the selected target."
							if (configuration.AutoAttackEnabled or configuration.AlertCombatPending) and now - lastAttackAt >= configuration.AutoAttackInterval then
								local ok, err = pcall(function()
									inputFunction:Invoke("AttackButton", Enum.UserInputState.Begin)
								end)
								if ok then lastAttackAt = now else warn("Auto Attack failed:", err) end
							end
							if configuration.AutoSkillEnabled and now - lastSkillAt >= configuration.AutoSkillInterval then
								local ok, err = pcall(function()
									inputFunction:Invoke("SkillButton", Enum.UserInputState.Begin)
								end)
								if ok then lastSkillAt = now else warn("Auto Skill failed:", err) end
							end
						end
					end
				end
			elseif chasingMob then
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
				chasingMob = false
			end
		elseif chasingMob then
			local character = Player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local localRoot = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and localRoot then humanoid:MoveTo(localRoot.Position) end
			chasingMob = false
		end
		configuration.UpdateExpMobTargetButton()
		task.wait(0.1)
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

		task.wait(0.1)
	end
end)

--==================================================
-- PLAYER LIST + FULL-SCREEN ALERTS
--==================================================
task.spawn(function()
	local lastPlayerRefresh = 0
	local lastFollowMove = 0
	local lastAutoBlockCheck = 0
	local nextAutoBlockPromptAt = 0
	local autoBlockTeleporting = false
	local flashOn = false
	local lastFlashToggle = 0
	local PlayerVisuals = {}
	local ThumbnailCache = {}
	local PlayerPanelBuildSignature = nil

	while true do
		local char = Player.Character
		local localRoot = char and char:FindFirstChild("HumanoidRootPart")
		local nearbyPlayer = nil
		local nearbyDistance = math.huge
		if configuration.AlertsEnabled and not configuration.EmergencyStopActive and localRoot then
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= Player and not configuration.IsWhitelisted(otherPlayer) then
					local otherCharacter = otherPlayer.Character
					local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
					if otherRoot then
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
				if configuration.Farming then configuration.SetIdle() end
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
		local autoAttackHasMobTarget = configuration.AlertCombatPending
			or (configuration.AutoAttackEnabled and not configuration.Farming
				and configuration.AutoAttackMode == "Mob"
				and (configuration.AutoAttackPinnedMob ~= nil or configuration.CombatTargetMob ~= nil))
		if not configuration.EmergencyStopActive and followedPlayer and char and not autoAttackHasMobTarget and os.clock() - lastFollowMove >= 0.6 then
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			local followedCharacter = followedPlayer.Character
			local followedRoot = followedCharacter and followedCharacter:FindFirstChild("HumanoidRootPart")
			if humanoid and localRoot and followedRoot then
				if (localRoot.Position - followedRoot.Position).Magnitude > configuration.FollowDistance + 2 then
					humanoid:MoveTo(followedRoot.Position - followedRoot.CFrame.LookVector * configuration.FollowDistance)
				else
					humanoid:MoveTo(localRoot.Position)
				end
				lastFollowMove = os.clock()
			end
		end

		if configuration.AutoBlockEnabled and not configuration.EmergencyStopActive and not configuration.AlertCombatPending
			and os.clock() - lastAutoBlockCheck >= 1 then
			lastAutoBlockCheck = os.clock()
			local blockedUsers = configuration.GetBlockedUserSet()
			local hasNonWhitelistedPlayer = false
			local blockedNonWhitelistedPlayer = false
			local nextPlayerToPrompt = nil

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
						if WhitelistPanel.Visible then configuration.RefreshWhitelist() end
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
								if configuration.IsWhitelisted(otherPlayer) then
									CombatInfo.Text = "Whitelisted players are skipped by Auto Attack."
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
						nameTag.Parent = PlayerEspLayer

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
						tracer.Parent = PlayerEspLayer
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
			AlarmText.Text = string.format("PLAYER NEARBY  •  %s  •  %.0f studs", nearbyPlayer.Name, nearbyDistance)
			AlarmOverlay.Visible = true
		elseif configuration.AlertsEnabled and not configuration.EmergencyStopActive and configuration.AlertFlashEnabled and reachedMax then
			AlarmOverlay.BackgroundColor3 = GREEN
			AlarmText.Text = "EXP MAX REACHED"
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

		task.wait(0.05)
	end
end)

getgenv().IamrichLoaded = true
