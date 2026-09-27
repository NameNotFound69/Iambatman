local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")

local Player = Players.LocalPlayer
local MobsFolder = workspace:WaitForChild("Mobs")
local InitClashing = ReplicatedStorage:FindFirstChild("InitClashing", true)
if not InitClashing then return end

--==================================================
-- CONFIG
--==================================================
local configuration = {
	Amount = 5000,
	MaxDistance = 15,
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
	AutoSkillEnabled = false,
	AutoAttackMode = "Mob",
	AutoAttackRange = 25,
	AutoAttackInterval = 1,
	AutoSkillInterval = 3,
	AutoAttackStandoff = 4,
	CombatTargetMob = nil,
	Farming = false,
	CurrentTarget = nil,
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
	AlertsEnabled = true,
	AutoBlockEnabled = true,
	AlertCombatPending = false,
	AlertCombatTarget = nil,
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
	ConfigFileName = "EXPPlus_Config.json",
	IsMinimized = false,
	Combat = {},
}


function configuration.LoadConfig()
	if type(readfile) ~= "function" then return end
	local ok, config = pcall(function()
		return HttpService:JSONDecode(readfile(configuration.ConfigFileName))
	end)
	if not ok or type(config) ~= "table" then return end

	local function ReadNumber(key, current, minimum, allowZero)
		local value = tonumber(config[key])
		if value and value >= minimum and (allowZero or value > 0) then
			return value
		end
		return current
	end

	configuration.Amount = math.floor(ReadNumber("Amount", configuration.Amount, 0, false))
	configuration.MaxDistance = ReadNumber("MaxDistance", configuration.MaxDistance, 0, false)
	configuration.Interval = ReadNumber("Interval", configuration.Interval, 0, true)
	configuration.ExpGoal = ReadNumber("ExpGoal", configuration.ExpGoal, 0, false)
	configuration.AlertsDistance = math.clamp(ReadNumber("AlertsDistance", configuration.AlertsDistance, 0, true), 0, 100000)
	configuration.FollowDistance = math.clamp(ReadNumber("FollowDistance", configuration.FollowDistance, 2, false), 2, 100)
	configuration.AutoAttackRange = math.clamp(ReadNumber("AutoAttackRange", configuration.AutoAttackRange, 5, false), 5, 500)
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
	if type(config.AutoBlockEnabled) == "boolean" then configuration.AutoBlockEnabled = config.AutoBlockEnabled end
	if type(config.MovementBoostEnabled) == "boolean" then configuration.MovementBoostEnabled = config.MovementBoostEnabled end
	if type(config.AutoAttackEnabled) == "boolean" then configuration.AutoAttackEnabled = config.AutoAttackEnabled end
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
	if type(writefile) ~= "function" then return false end
	local ids = {}
	for userId in pairs(configuration.WhitelistIds) do
		table.insert(ids, userId)
	end
	table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)

	local config = {
		Amount = configuration.Amount,
		MaxDistance = configuration.MaxDistance,
		Interval = configuration.Interval,
		ExpGoal = configuration.ExpGoal,
		AlertsDistance = configuration.AlertsDistance,
		FollowDistance = configuration.FollowDistance,
		FollowPlayerUserId = configuration.FollowPlayerUserId,
		AutoAttackTargetUserId = configuration.AutoAttackTargetUserId,
		AutoAttackEnabled = configuration.AutoAttackEnabled,
		AutoAttackMode = configuration.AutoAttackMode,
		AutoAttackRange = configuration.AutoAttackRange,
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
		AutoBlockEnabled = configuration.AutoBlockEnabled,
		MovementBoostEnabled = configuration.MovementBoostEnabled,
		ESPEnabled = configuration.ESPEnabled,
		ESPLineEnabled = configuration.ESPLineEnabled,
		ESPBoxEnabled = configuration.ESPBoxEnabled,
		AntiAFKEnabled = configuration.AntiAFKEnabled,
		WhitelistIds = ids,
		Minimized = configuration.IsMinimized == true,
	}
	local ok = pcall(function()
		writefile(configuration.ConfigFileName, HttpService:JSONEncode(config))
	end)
	return ok
end

configuration.LoadConfig()

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
-- COLORS (minimal graphite + ice blue)
--==================================================
local BG      = Color3.fromRGB(8, 8, 9)
local CARD    = Color3.fromRGB(17, 17, 18)
local INPUT   = Color3.fromRGB(27, 27, 29)
local BORDER  = Color3.fromRGB(48, 48, 51)
local TEXT    = Color3.fromRGB(235, 235, 238)
local MUTED   = Color3.fromRGB(145, 145, 151)
local ACCENT  = Color3.fromRGB(113, 211, 245)
local GREEN   = Color3.fromRGB(76, 218, 164)
local RED     = Color3.fromRGB(255, 92, 112)
local YELLOW  = Color3.fromRGB(255, 196, 92)
local ACCENT_DIM = Color3.fromRGB(39, 116, 145)
local GREEN_DIM  = Color3.fromRGB(24, 53, 45)
local RED_DIM    = Color3.fromRGB(56, 30, 37)

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
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 13)
local MainGradient = Instance.new("UIGradient", Main)
MainGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 12, 13)),
	ColorSequenceKeypoint.new(1, BG),
})
MainGradient.Rotation = 90
local MainStroke = Instance.new("UIStroke", Main)
MainStroke.Color = BORDER
MainStroke.Thickness = 1
MainStroke.Transparency = 0.3

--==================================================
-- HEADER (compact)
--==================================================
local Content
local Sidebar
local InfoCard, StartBtn, ToggleGrid, SettingsCard
local AlarmOverlay
local Header = Instance.new("Frame")
Header.Size = UDim2.fromScale(1, 0.11)
Header.Active = true
Header.BackgroundColor3 = Color3.fromRGB(22, 22, 23)
Header.BorderSizePixel = 0
Header.Parent = Main
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 13)

local HeaderFix = Instance.new("Frame")
HeaderFix.Size = UDim2.fromScale(1, 0.4)
HeaderFix.Position = UDim2.fromScale(0, 0.6)
HeaderFix.BackgroundColor3 = Color3.fromRGB(22, 22, 23)
HeaderFix.BorderSizePixel = 0
HeaderFix.Parent = Header

local HeaderRule = Instance.new("Frame")
HeaderRule.Size = UDim2.new(1, -24, 0, 1)
HeaderRule.Position = UDim2.new(0, 12, 1, -1)
HeaderRule.BackgroundColor3 = BORDER
HeaderRule.BackgroundTransparency = 0.35
HeaderRule.BorderSizePixel = 0
HeaderRule.Parent = Header

function configuration.MakeWindowDot(x, color)
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromScale(0.022, 0.20)
	dot.Position = UDim2.fromScale(x, 0.40)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Parent = Header
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
end
configuration.MakeWindowDot(0.035, Color3.fromRGB(255, 95, 86))
configuration.MakeWindowDot(0.075, Color3.fromRGB(255, 190, 46))
configuration.MakeWindowDot(0.115, Color3.fromRGB(40, 201, 64))

local Title = Instance.new("TextLabel")
Title.Size = UDim2.fromScale(0.72, 0.32)
Title.Position = UDim2.fromScale(0.16, 0.12)
Title.BackgroundTransparency = 1
Title.Text = "EXP+"
Title.TextColor3 = TEXT
Title.TextSize = 15
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Subtitle = Instance.new("TextLabel")
Subtitle.Size = UDim2.fromScale(0.72, 0.24)
Subtitle.Position = UDim2.fromScale(0.16, 0.52)
Subtitle.BackgroundTransparency = 1
Subtitle.Text = "Experience tracker"
Subtitle.TextColor3 = MUTED
Subtitle.TextSize = 10
Subtitle.Font = Enum.Font.Gotham
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.Parent = Header

local Status = Instance.new("TextLabel")
Status.Size = UDim2.fromOffset(48, 20)
Status.Position = UDim2.new(1, -62, 0, 12)
Status.BackgroundColor3 = RED_DIM
Status.Text = "OFF"
Status.TextColor3 = RED
Status.TextSize = 10
Status.Font = Enum.Font.GothamBold
Status.Parent = Header
Instance.new("UICorner", Status).CornerRadius = UDim.new(1, 0)

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Size = UDim2.fromOffset(24, 24)
MinimizeBtn.Position = UDim2.new(1, -92, 0, 10)
MinimizeBtn.BackgroundColor3 = INPUT
MinimizeBtn.BorderSizePixel = 0
MinimizeBtn.Text = "−"
MinimizeBtn.TextColor3 = TEXT
MinimizeBtn.TextSize = 16
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Parent = Header
Instance.new("UICorner", MinimizeBtn).CornerRadius = UDim.new(0, 6)

-- Mini bar (visible only when minimized) — big EXP + time
local MiniBar = Instance.new("Frame")
MiniBar.Name = "MiniBar"
MiniBar.Size = UDim2.new(1, -110, 1, -8)
MiniBar.Position = UDim2.fromOffset(10, 4)
MiniBar.BackgroundTransparency = 1
MiniBar.Visible = false
MiniBar.Parent = Header

local MiniExp = Instance.new("TextLabel")
MiniExp.Name = "MiniExp"
MiniExp.Size = UDim2.new(0.55, 0, 0.6, 0)
MiniExp.Position = UDim2.fromScale(0, 0.05)
MiniExp.BackgroundTransparency = 1
MiniExp.Text = "0"
MiniExp.TextColor3 = GREEN
MiniExp.TextSize = 18
MiniExp.Font = Enum.Font.GothamBlack
MiniExp.TextXAlignment = Enum.TextXAlignment.Left
MiniExp.TextYAlignment = Enum.TextYAlignment.Bottom
MiniExp.Parent = MiniBar

local MiniMax = Instance.new("TextLabel")
MiniMax.Size = UDim2.new(0.55, 0, 0.35, 0)
MiniMax.Position = UDim2.fromScale(0, 0.62)
MiniMax.BackgroundTransparency = 1
MiniMax.Text = "/ " .. configuration.FormatNumber(configuration.ExpGoal)
MiniMax.TextColor3 = MUTED
MiniMax.TextSize = 10
MiniMax.Font = Enum.Font.Gotham
MiniMax.TextXAlignment = Enum.TextXAlignment.Left
MiniMax.TextYAlignment = Enum.TextYAlignment.Top
MiniMax.Parent = MiniBar

local MiniTime = Instance.new("TextLabel")
MiniTime.Name = "MiniTime"
MiniTime.Size = UDim2.new(0.4, 0, 0.55, 0)
MiniTime.Position = UDim2.fromScale(0.55, 0.1)
MiniTime.BackgroundTransparency = 1
MiniTime.Text = "00:00:00"
MiniTime.TextColor3 = YELLOW
MiniTime.TextSize = 14
MiniTime.Font = Enum.Font.GothamBold
MiniTime.TextXAlignment = Enum.TextXAlignment.Right
MiniTime.Parent = MiniBar

local MiniState = Instance.new("TextLabel")
MiniState.Name = "MiniState"
MiniState.Size = UDim2.new(0.4, 0, 0.35, 0)
MiniState.Position = UDim2.fromScale(0.55, 0.6)
MiniState.BackgroundTransparency = 1
MiniState.Text = "Idle"
MiniState.TextColor3 = MUTED
MiniState.TextSize = 10
MiniState.Font = Enum.Font.Gotham
MiniState.TextXAlignment = Enum.TextXAlignment.Right
MiniState.Parent = MiniBar

function configuration.ApplyMinimized(state)
	configuration.IsMinimized = state
	if Content then Content.Visible = not state end
	if Sidebar then Sidebar.Visible = not state end
	MiniBar.Visible = state
	Title.Visible = not state
	Subtitle.Visible = not state
	Main.Size = UDim2.fromScale(configuration.MainWidthScale, state and 0.095 or configuration.MainHeightScale)
	Header.Size = UDim2.fromScale(1, state and 1 or 0.11)
	MinimizeBtn.Text = state and "+" or "−"
	if state then
		Status.Position = UDim2.new(1, -62, 0.5, -10)
		MinimizeBtn.Position = UDim2.new(1, -92, 0.5, -12)
	else
		Status.Position = UDim2.new(1, -62, 0, 12)
		MinimizeBtn.Position = UDim2.new(1, -92, 0, 10)
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
		if viewport then
			Main.Position = UDim2.fromScale(
				math.clamp(StartPos.X.Scale + d.X / viewport.X, 0, 1 - configuration.MainWidthScale),
				math.clamp(StartPos.Y.Scale + d.Y / viewport.Y, 0, 1 - (configuration.IsMinimized and 0.095 or configuration.MainHeightScale))
			)
		end
	end
end)

--==================================================
-- CONTENT
--==================================================
Content = Instance.new("Frame")
Content.Name = "MainContent"
Content.Size = UDim2.fromScale(0.67, 0.83)
Content.Position = UDim2.fromScale(0.30, 0.13)
Content.BackgroundTransparency = 1
Content.BorderSizePixel = 0
Content.Parent = Main
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
	heading.Size = UDim2.new(1, 0, 0, 48)
	heading.LayoutOrder = 1
	heading.BackgroundTransparency = 1
	heading.Parent = page
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -8, 0, 24)
	titleLabel.Position = UDim2.fromOffset(4, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = TEXT
	titleLabel.TextSize = 18
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = heading
	local descriptionLabel = Instance.new("TextLabel")
	descriptionLabel.Size = UDim2.new(1, -8, 0, 16)
	descriptionLabel.Position = UDim2.fromOffset(4, 26)
	descriptionLabel.BackgroundTransparency = 1
	descriptionLabel.Text = description
	descriptionLabel.TextColor3 = MUTED
	descriptionLabel.TextSize = 11
	descriptionLabel.Font = Enum.Font.Gotham
	descriptionLabel.TextXAlignment = Enum.TextXAlignment.Left
	descriptionLabel.Parent = heading
	return heading
end

configuration.AddPageHeading(ExpPage, "Experience", "Track your EXP progress and current farming session")
configuration.AddPageHeading(ESPPage, "ESP", "Choose which player markers to show")
configuration.AddPageHeading(PlayerPage, "Players", "Follow target, spacing, server players and whitelist")
configuration.AddPageHeading(AlertsPage, "Alerts", "Notifications and idle behavior")
configuration.AddPageHeading(FarmPage, "EXP Farm", "Set the EXP cycle amount, target range, interval and goal")
configuration.AddPageHeading(CombatPage, "Auto Farm", "Choose a target and control attack, skill and timing")

Sidebar = Instance.new("Frame")
Sidebar.Name = "Navigation"
Sidebar.Size = UDim2.fromScale(0.25, 0.83)
Sidebar.Position = UDim2.fromScale(0.03, 0.13)
Sidebar.BackgroundColor3 = Color3.fromRGB(20, 20, 21)
Sidebar.BorderSizePixel = 0
Sidebar.Visible = not configuration.IsMinimized
Sidebar.Parent = Main
Instance.new("UICorner", Sidebar).CornerRadius = UDim.new(0, 10)

local SidebarTitle = Instance.new("TextLabel")
SidebarTitle.Size = UDim2.new(1, -16, 0, 24)
SidebarTitle.Position = UDim2.fromOffset(8, 10)
SidebarTitle.BackgroundTransparency = 1
SidebarTitle.Text = "NAVIGATION"
SidebarTitle.TextColor3 = MUTED
SidebarTitle.TextSize = 10
SidebarTitle.Font = Enum.Font.GothamBold
SidebarTitle.TextXAlignment = Enum.TextXAlignment.Left
SidebarTitle.Parent = Sidebar

function configuration.MakeNavButton(text, yScale)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromScale(0.92, 0.09)
	button.Position = UDim2.fromScale(0.04, yScale)
	button.BackgroundColor3 = text == "EXP" and ACCENT_DIM or CARD
	button.BackgroundTransparency = text == "EXP" and 0 or 1
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = text == "EXP" and ACCENT or TEXT
	button.TextSize = 12
	button.Font = Enum.Font.GothamBold
	button.Parent = Sidebar
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
	local marker = Instance.new("Frame")
	marker.Name = "ActiveMark"
	marker.Size = UDim2.new(0, 3, 0.52, 0)
	marker.Position = UDim2.new(0, 0, 0.24, 0)
	marker.BackgroundColor3 = ACCENT
	marker.BorderSizePixel = 0
	marker.Visible = text == "EXP"
	marker.Parent = button
	Instance.new("UICorner", marker).CornerRadius = UDim.new(1, 0)
	return button
end

function configuration.MakeNavSection(text, yScale)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.90, 0.04)
	label.Position = UDim2.fromScale(0.05, yScale)
	label.BackgroundTransparency = 1
	label.Text = string.upper(text)
	label.TextColor3 = MUTED
	label.TextSize = 8
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = Sidebar
	return label
end

configuration.MakeNavSection("Experience", 0.12)
configuration.MakeNavSection("Automation", 0.37)
configuration.MakeNavSection("Monitoring", 0.54)
configuration.MakeNavSection("Players", 0.71)
configuration.MakeNavSection("Visuals", 0.85)

local NavButtons = {
	EXP = configuration.MakeNavButton("EXP", 0.16),
	Farm = configuration.MakeNavButton("EXP Setting", 0.27),
	Combat = configuration.MakeNavButton("Auto Farm", 0.41),
	Alerts = configuration.MakeNavButton("Alerts", 0.58),
	Player = configuration.MakeNavButton("Player", 0.75),
	ESP = configuration.MakeNavButton("Player ESP", 0.88),
}

function configuration.SetMainTab(tab)
	for name, page in pairs(Pages) do
		page.Visible = name == tab
		if page.Visible then page.CanvasPosition = Vector2.zero end
	end
	for name, button in pairs(NavButtons) do
		local selected = name == tab
		button.BackgroundColor3 = selected and ACCENT_DIM or Color3.fromRGB(20, 20, 21)
		button.BackgroundTransparency = selected and 0 or 1
		button.TextColor3 = selected and ACCENT or TEXT
		local marker = button:FindFirstChild("ActiveMark")
		if marker then marker.Visible = selected end
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
AlertsGrid.Size = UDim2.new(1, 0, 0, 40)
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

local AutoAttackModeButtons = {
	Mob = configuration.MakeToggle("Mob", configuration.AutoAttackMode == "Mob", ACCENT, ACCENT_DIM, 1, AttackModeGrid),
	Player = configuration.MakeToggle("Player", configuration.AutoAttackMode == "Player", ACCENT, ACCENT_DIM, 2, AttackModeGrid),
	Nearby = configuration.MakeToggle("Nearest: Mob / Player", configuration.AutoAttackMode == "Nearby", ACCENT, ACCENT_DIM, 3, AttackModeGrid),
}

local AutoAttackRangeCard, AutoAttackRangeInput = configuration.MakeNumberCard(
	CombatPage, "Attack target range (studs)", function() return configuration.AutoAttackRange end, 4, 5, 500,
	function(value) configuration.AutoAttackRange = value end
)

local AutoAttackIntervalCard, AutoAttackIntervalInput = configuration.MakeNumberCard(
	CombatPage, "Attack interval (seconds)", function() return configuration.AutoAttackInterval end, 5, 1, 10,
	function(value) configuration.AutoAttackInterval = value end
)

local AutoSkillIntervalCard, AutoSkillIntervalInput = configuration.MakeNumberCard(
	CombatPage, "Skill interval (seconds)", function() return configuration.AutoSkillInterval end, 6, 1, 30,
	function(value) configuration.AutoSkillInterval = value end
)

local CombatMobHeading = Instance.new("Frame")
CombatMobHeading.Size = UDim2.new(1, 0, 0, 30)
CombatMobHeading.LayoutOrder = 7
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
CombatMobScroll.LayoutOrder = 8
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
function configuration.RefreshCombatMobs()
	for _, row in ipairs(configuration.CombatMobRows) do
		row:Destroy()
	end
	table.clear(configuration.CombatMobRows)

	local available = 0
	for _, mob in ipairs(MobsFolder:GetChildren()) do
		local root = mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and (not humanoid or humanoid.Health > 0) then
			available += 1
			local selectedMob = mob
			local isSelectedMob = configuration.AutoAttackPinnedMob == selectedMob or configuration.CombatTargetMob == selectedMob
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, -8, 0, 30)
			row.LayoutOrder = available
			row.BackgroundColor3 = isSelectedMob and ACCENT_DIM or INPUT
			row.BorderSizePixel = 0
			local cfg = selectedMob:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			local entity = cfg and cfg:FindFirstChild("Entity")
			local entityValue = entity and entity.Value
			local entityName = typeof(entityValue) == "Instance" and entityValue.Name or (entityValue ~= nil and tostring(entityValue) or selectedMob.Name)
			row.Text = string.format("%s%s  •  EXP %s", isSelectedMob and "✓  " or "", entityName, exp and tostring(exp.Value) or "-")
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
				configuration.AutoAttackPinnedMob = selectedMob
				configuration.CombatTargetMob = selectedMob
				configuration.AutoAttackMode = "Mob"
				configuration.UpdateAutoAttackModeButtons()
				configuration.SaveConfig()
				configuration.RefreshCombatMobs()
			end)
			table.insert(configuration.CombatMobRows, row)
		end
	end
	if available == 0 then
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

CombatMobRefresh.MouseButton1Click:Connect(configuration.RefreshCombatMobs)
MobsFolder.ChildAdded:Connect(configuration.RefreshCombatMobs)
MobsFolder.ChildRemoved:Connect(configuration.RefreshCombatMobs)
configuration.RefreshCombatMobs()

local CombatInfo = Instance.new("TextLabel")
CombatInfo.Size = UDim2.new(1, -8, 0, 34)
CombatInfo.LayoutOrder = 9
CombatInfo.BackgroundTransparency = 1
CombatInfo.Text = "Attack and skills pause during EXP farming. Nearest mob stays selected until it dies."
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

AutoAttackButton.MouseButton1Click:Connect(function()
	configuration.AutoAttackEnabled = not configuration.AutoAttackEnabled
	AutoAttackButton.Text = configuration.AutoAttackEnabled and "Auto Attack: ON" or "Auto Attack: OFF"
	AutoAttackButton.TextColor3 = configuration.AutoAttackEnabled and RED or MUTED
	AutoAttackButton.BackgroundColor3 = configuration.AutoAttackEnabled and RED_DIM or CARD
	if configuration.AutoAttackEnabled and not configuration.Farming and configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
		configuration.AutoAttackPinnedMob = configuration.CurrentTarget
	end
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
		configuration.UpdateAutoAttackModeButtons()
		configuration.SaveConfig()
	end)
end

local AlertToggleButton = configuration.MakeToggle(configuration.AlertsEnabled and "Alerts: ON" or "Alerts: OFF", configuration.AlertsEnabled, GREEN, GREEN_DIM, 1, AlertsGrid)
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

Player.Idled:Connect(function()
	if not configuration.AntiAFKEnabled then return end
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
		if not configuration.MovementBoostEnabled then continue end

		local playerGui = Player:FindFirstChildOfClass("PlayerGui")
		local gameGui = playerGui and playerGui:FindFirstChild("GameGui")
		local stamina = gameGui and gameGui:FindFirstChild("Stamina")
		if stamina and (stamina:IsA("NumberValue") or stamina:IsA("IntValue")) then
			local ok = pcall(function()
				stamina.Value = 1e18
			end)
			if not ok and stamina:IsA("IntValue") then
				pcall(function() stamina.Value = 2147483647 end)
			end
		end

		local playerStats = Player:FindFirstChild("PlayerStats")
		local level = playerStats and playerStats:FindFirstChild("Level")
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
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
SettingsCard.Size = UDim2.new(1, 0, 0, 104)
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
local DistBox = configuration.MakeCompactSetting(SettingsCard, "Max distance", configuration.MaxDistance, 0.5, 24)
local IntervalBox = configuration.MakeCompactSetting(SettingsCard, "Interval (s)", configuration.Interval, 0, 62)
local MaxBox = configuration.MakeCompactSetting(SettingsCard, "EXP Max", configuration.ExpGoal, 0.5, 62)

AmountBox.FocusLost:Connect(function()
	local v = tonumber(AmountBox.Text)
	if v and v > 0 then configuration.Amount = math.floor(v) end
	AmountBox.Text = tostring(configuration.Amount)
	configuration.SaveConfig()
end)
DistBox.FocusLost:Connect(function()
	local v = tonumber(DistBox.Text)
	if v and v > 0 then configuration.MaxDistance = v end
	DistBox.Text = tostring(configuration.MaxDistance)
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
Instance.new("UICorner", PlayerPanel).CornerRadius = UDim.new(0, 14)
local PlayerPanelStroke = Instance.new("UIStroke", PlayerPanel)
PlayerPanelStroke.Color = BORDER
PlayerPanelStroke.Thickness = 1.2
PlayerPanelStroke.Transparency = 0.15

local PlayerPanelTitle = Instance.new("TextLabel")
PlayerPanelTitle.Size = UDim2.new(1, -52, 0, 36)
PlayerPanelTitle.Position = UDim2.fromOffset(12, 4)
PlayerPanelTitle.ZIndex = 91
PlayerPanelTitle.Active = true
PlayerPanelTitle.BackgroundTransparency = 1
PlayerPanelTitle.Text = "Players in server"
PlayerPanelTitle.TextColor3 = TEXT
PlayerPanelTitle.TextSize = 15
PlayerPanelTitle.Font = Enum.Font.GothamBold
PlayerPanelTitle.TextXAlignment = Enum.TextXAlignment.Left
PlayerPanelTitle.Parent = PlayerPanel

local PlayerPanelClose = Instance.new("TextButton")
PlayerPanelClose.Size = UDim2.fromOffset(28, 28)
PlayerPanelClose.Position = UDim2.new(1, -36, 0, 8)
PlayerPanelClose.ZIndex = 91
PlayerPanelClose.BackgroundColor3 = INPUT
PlayerPanelClose.BorderSizePixel = 0
PlayerPanelClose.Text = "×"
PlayerPanelClose.TextColor3 = TEXT
PlayerPanelClose.TextSize = 16
PlayerPanelClose.Font = Enum.Font.GothamBold
PlayerPanelClose.Parent = PlayerPanel
Instance.new("UICorner", PlayerPanelClose).CornerRadius = UDim.new(0, 6)

local PlayerScroll = Instance.new("ScrollingFrame")
PlayerScroll.Size = UDim2.fromScale(0.94, 0.86)
PlayerScroll.Position = UDim2.fromScale(0.03, 0.11)
PlayerScroll.ZIndex = 91
PlayerScroll.BackgroundColor3 = CARD
PlayerScroll.BorderSizePixel = 0
PlayerScroll.ScrollBarThickness = 4
PlayerScroll.CanvasSize = UDim2.new()
PlayerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
PlayerScroll.Parent = PlayerPanel
Instance.new("UICorner", PlayerScroll).CornerRadius = UDim.new(0, 8)

local PlayerScrollLayout = Instance.new("UIListLayout", PlayerScroll)
PlayerScrollLayout.Padding = UDim.new(0, 4)
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
Instance.new("UICorner", WhitelistPanel).CornerRadius = UDim.new(0, 14)
local WhitelistPanelStroke = Instance.new("UIStroke", WhitelistPanel)
WhitelistPanelStroke.Color = BORDER
WhitelistPanelStroke.Thickness = 1.2
WhitelistPanelStroke.Transparency = 0.15

local WhitelistTitle = Instance.new("TextLabel")
WhitelistTitle.Size = UDim2.new(1, -20, 0, 30)
WhitelistTitle.Position = UDim2.fromOffset(12, 6)
WhitelistTitle.ZIndex = 91
WhitelistTitle.Active = true
WhitelistTitle.BackgroundTransparency = 1
WhitelistTitle.Text = "Whitelist by Player UserId"
WhitelistTitle.TextColor3 = TEXT
WhitelistTitle.TextSize = 15
WhitelistTitle.Font = Enum.Font.GothamBold
WhitelistTitle.TextXAlignment = Enum.TextXAlignment.Left
WhitelistTitle.Parent = WhitelistPanel

local WhitelistInput = Instance.new("TextBox")
WhitelistInput.Size = UDim2.new(1, -112, 0, 32)
WhitelistInput.Position = UDim2.fromOffset(10, 42)
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
Instance.new("UICorner", WhitelistInput).CornerRadius = UDim.new(0, 6)

local AddWhitelistButton = Instance.new("TextButton")
AddWhitelistButton.Size = UDim2.fromOffset(88, 32)
AddWhitelistButton.Position = UDim2.new(1, -98, 0, 42)
AddWhitelistButton.ZIndex = 91
AddWhitelistButton.BackgroundColor3 = ACCENT
AddWhitelistButton.BorderSizePixel = 0
AddWhitelistButton.Text = "Add ID"
AddWhitelistButton.TextColor3 = Color3.new(1, 1, 1)
AddWhitelistButton.TextSize = 11
AddWhitelistButton.Font = Enum.Font.GothamBold
AddWhitelistButton.Parent = WhitelistPanel
Instance.new("UICorner", AddWhitelistButton).CornerRadius = UDim.new(0, 6)

local WhitelistScroll = Instance.new("ScrollingFrame")
WhitelistScroll.Size = UDim2.fromScale(0.94, 0.74)
WhitelistScroll.Position = UDim2.fromScale(0.03, 0.22)
WhitelistScroll.ZIndex = 91
WhitelistScroll.BackgroundColor3 = CARD
WhitelistScroll.BorderSizePixel = 0
WhitelistScroll.ScrollBarThickness = 4
WhitelistScroll.CanvasSize = UDim2.new()
WhitelistScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
WhitelistScroll.Parent = WhitelistPanel
Instance.new("UICorner", WhitelistScroll).CornerRadius = UDim.new(0, 8)

local WhitelistLayout = Instance.new("UIListLayout", WhitelistScroll)
WhitelistLayout.Padding = UDim.new(0, 4)
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

configuration.MakeDraggable(PlayerPanel, PlayerPanelTitle)
configuration.MakeDraggable(WhitelistPanel, WhitelistTitle)

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
	Main.Size = UDim2.fromScale(configuration.MainWidthScale, configuration.IsMinimized and 0.095 or configuration.MainHeightScale)
end)

--==================================================
-- STATUS HELPERS
--==================================================
function configuration.PauseTimer()
	if not configuration.IsPaused and configuration.LastTarget then
		configuration.AccumulatedTime = configuration.AccumulatedTime + (tick() - configuration.TargetStartTime)
		configuration.IsPaused = true
	end
end

function configuration.SetIdle()
	if configuration.Farming and (configuration.AutoAttackEnabled or configuration.AutoSkillEnabled) and configuration.CurrentTarget and configuration.CurrentTarget:IsDescendantOf(MobsFolder) then
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
	if configuration.AlertCombatPending or configuration.AlertCombatBlockReady then return end
	configuration.Farming = true
	configuration.AutoAttackPinnedMob = nil
	configuration.IsPaused = false
	configuration.SessionExpGained = 0
	configuration.SessionFarmSeconds = 0
	configuration.NoProgressCycles = 0
	SessionLabel.Text = "Session: +0 EXP / 00:00:00 / 0 EXP/h"
	configuration.RecentCycle = "รอบล่าสุด  -"
	RecentCycleLabel.Text = configuration.RecentCycle
	if configuration.LastTarget then
		configuration.TargetStartTime = tick()
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

function configuration.Combat.FindNearestCombatMob(localRoot, maxDistance)
	local bestMob, bestRoot, bestDistance = nil, nil, maxDistance or configuration.AutoAttackRange
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

	if configuration.AutoAttackMode == "Player" then
		local targetPlayer, targetRoot = configuration.Combat.FindCombatPlayer(configuration.AutoAttackTargetUserId)
		if targetPlayer then
			return "Player", targetPlayer, targetRoot, (localRoot.Position - targetRoot.Position).Magnitude
		end
		return nil
	end

	if configuration.AutoAttackMode == "Mob" then
		local lockedMob = configuration.AutoAttackPinnedMob or configuration.CombatTargetMob
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
	while true do
		if not configuration.Farming then
			task.wait(0.1)
			continue
		end

		local target = configuration.CurrentTarget

		if target and target:IsDescendantOf(MobsFolder) then
			-- ยึดตัวเดิม
		else
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
				MiniState.Text = "Searching..."
				RateLabel.Text = "Rate -"
				configuration.PauseTimer()
				task.wait(0.2)
				continue
			end

			local cfg = target:FindFirstChild("Config")
			local exp = cfg and cfg:FindFirstChild("EXP")
			configuration.AttachBillboard(target, exp and exp.Value or 0)

			-- เริ่มจับเวลา rate ของมอนตัวนี้
			configuration.SessionStartEXP = exp and exp.Value or 0
			configuration.SessionStartTime = tick()
		end

		local cfg = target:FindFirstChild("Config")
		local exp = cfg and cfg:FindFirstChild("EXP")
		if not exp then
			task.wait(0.1)
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

		-- ถึง Max แล้ว → หยุดยิง + หยุดนับเวลา
		if exp.Value >= configuration.ExpGoal then
			configuration.SetIdle()
			StateLabel.Text = "Goal reached"
			MiniState.Text = "Goal reached"
			configuration.UpdateBillboardText(exp.Value, true)
			Bar.Size = UDim2.fromScale(1, 1)
			PercentLabel.Text = "100%"
			configuration.PauseTimer()
			task.wait(0.3)
			continue
		end

		StateLabel.Text = configuration.NoProgressCycles >= 2 and ("No EXP progress (" .. configuration.NoProgressCycles .. ")") or "Farming..."
		MiniState.Text = StateLabel.Text
		configuration.UpdateBillboardText(exp.Value, false)

		-- ยิงเฉพาะจำนวนที่เหลือถึง Max (กันยิงเกิน)
		local remaining = configuration.ExpGoal - exp.Value
		local toFire = math.min(configuration.Amount, math.max(0, remaining))
		local cycleStartExp = exp.Value
		local cycleStartTime = os.clock()
		local callsSent = 0

		for i = 1, toFire do
			if not configuration.Farming then break end
			if not target:IsDescendantOf(MobsFolder) then break end
			if exp.Value >= configuration.ExpGoal then break end

			-- Keep Auto Attack on the same mob EXP is targeting.
			if configuration.AutoAttackEnabled then
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

		if not configuration.Farming then continue end

		if not target:IsDescendantOf(MobsFolder) then
			configuration.ClearBillboard()
			configuration.CurrentTarget = nil
			task.wait(0.05)
			continue
		end

		if exp.Value >= configuration.ExpGoal then
			configuration.Combat.RecordCycle(cycleStartExp, cycleStartTime, callsSent, exp.Value)
			configuration.SetIdle()
			StateLabel.Text = "Goal reached"
			MiniState.Text = "Goal reached"
			configuration.UpdateBillboardText(exp.Value, true)
			configuration.PauseTimer()
			continue
		end

		-- รอ EXP ขึ้น (timeout สั้นลงเมื่อใกล้ Max)
		if target:IsDescendantOf(MobsFolder) then
			StateLabel.Text = "Waiting..."
			MiniState.Text = "Waiting..."
			local expected = math.min(cycleStartExp + callsSent, configuration.ExpGoal)
			local startWait = os.clock()
			local maxWait = (exp.Value >= configuration.ExpGoal - 500) and 2 or 5

			while configuration.Farming and exp.Parent and exp.Value < expected do
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
			StateLabel.Text = configuration.NoProgressCycles >= 2 and ("No EXP progress (" .. configuration.NoProgressCycles .. ")") or "Cycle done"
			MiniState.Text = StateLabel.Text
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
	local equippedCharacter = nil
	local chasingMob = false
	while true do
		if (configuration.AutoAttackEnabled or configuration.AutoSkillEnabled or configuration.AlertCombatPending)
			and not configuration.Farming and not configuration.AlertCombatBlockReady then
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
						if equippedCharacter ~= character then
							local equipped = pcall(function()
								inputFunction:Invoke("EquipButton", Enum.UserInputState.Begin)
							end)
							if equipped then
								equippedCharacter = character
								lastAttackAt = os.clock() - configuration.AutoAttackInterval
								lastSkillAt = os.clock() - configuration.AutoSkillInterval
							end
						else
							local now = os.clock()
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
				configuration.TargetStartTime = tick()
				configuration.AccumulatedTime = 0
				configuration.IsPaused = false
				if exp then
					configuration.SessionStartEXP = exp.Value
					configuration.SessionStartTime = tick()
				end
			end

			if not reachedMax then
				if configuration.IsPaused then
					configuration.TargetStartTime = tick()
					configuration.IsPaused = false
				end
				TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime + (tick() - configuration.TargetStartTime))
				MiniTime.Text = TimeLabel.Text
			else
				configuration.PauseTimer()
				TimeLabel.Text = configuration.FormatTime(configuration.AccumulatedTime)
			MiniTime.Text = TimeLabel.Text
			end

			-- EXP / Hour
			if exp and configuration.SessionStartTime > 0 then
				local elapsed = tick() - configuration.SessionStartTime
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

	while true do
		local char = Player.Character
		local localRoot = char and char:FindFirstChild("HumanoidRootPart")
		local nearbyPlayer = nil
		local nearbyDistance = math.huge
		if configuration.AlertsEnabled and localRoot then
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

		if nearbyPlayer then
			local alertUserId = tostring(nearbyPlayer.UserId)
			if not configuration.AlertCombatPending and not configuration.AlertCombatBlockReady
				and configuration.LastAlertCombatUserId ~= alertUserId then
				configuration.LastAlertCombatUserId = alertUserId
				configuration.AlertCombatPending = true
				configuration.AlertBlockTarget = nearbyPlayer
				local mob = configuration.CurrentTarget
				if not configuration.Combat.IsLivingMob(mob) then
					mob = configuration.Combat.FindNearestCombatMob(localRoot, math.huge)
				end
				configuration.AlertCombatTarget = mob
				if mob then
					configuration.AutoAttackPinnedMob = mob
					configuration.CombatTargetMob = mob
				end
				if configuration.Farming then configuration.SetIdle() end
			end
		elseif not configuration.AlertCombatPending and not configuration.AlertCombatBlockReady then
			configuration.LastAlertCombatUserId = nil
		end

		if configuration.AlertCombatPending then
			local alertMob = configuration.AlertCombatTarget
			if alertMob then
				if not configuration.Combat.IsLivingMob(alertMob) then
					configuration.AlertCombatPending = false
					configuration.AlertCombatTarget = nil
					configuration.AlertCombatBlockReady = configuration.AutoBlockEnabled
				else
					configuration.AutoAttackPinnedMob = alertMob
					configuration.CombatTargetMob = alertMob
				end
			elseif localRoot then
				local mob = configuration.Combat.FindNearestCombatMob(localRoot, math.huge)
				if mob then
					configuration.AlertCombatTarget = mob
					configuration.AutoAttackPinnedMob = mob
					configuration.CombatTargetMob = mob
				end
			end
		end

		local followedPlayer = configuration.FollowPlayerUserId and Players:GetPlayerByUserId(tonumber(configuration.FollowPlayerUserId))
		local autoAttackHasMobTarget = configuration.AlertCombatPending
			or (configuration.AutoAttackEnabled and not configuration.Farming
				and configuration.AutoAttackMode == "Mob"
				and (configuration.AutoAttackPinnedMob ~= nil or configuration.CombatTargetMob ~= nil))
		if followedPlayer and char and not autoAttackHasMobTarget and os.clock() - lastFollowMove >= 0.6 then
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

		if configuration.AutoBlockEnabled and not configuration.AlertCombatPending
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
				elseif not ok then
					warn("Auto Block prompt failed:", err)
				end
			end
		elseif not configuration.AutoBlockEnabled then
			nextAutoBlockPromptAt = 0
		end

		if PlayerPanel.Visible and os.clock() - lastPlayerRefresh >= 0.5 then
			lastPlayerRefresh = os.clock()
			for _, child in ipairs(PlayerScroll:GetChildren()) do
				if child.Name:match("^PlayerRow_") then
					child:Destroy()
				end
			end

			for order, otherPlayer in ipairs(Players:GetPlayers()) do
				if configuration.PlayerPanelMode == "follow" then
					if otherPlayer == Player then continue end
					local selectedPlayer = otherPlayer
					local row = Instance.new("TextButton")
					row.Name = "PlayerRow_" .. selectedPlayer.UserId
					row.Size = UDim2.new(1, -12, 0, 44)
					row.LayoutOrder = order
					row.ZIndex = 92
					row.BackgroundColor3 = configuration.FollowPlayerUserId == tostring(selectedPlayer.UserId) and ACCENT_DIM or INPUT
					row.BorderSizePixel = 0
					row.Text = selectedPlayer.DisplayName
					row.TextColor3 = configuration.FollowPlayerUserId == tostring(selectedPlayer.UserId) and ACCENT or TEXT
					row.TextSize = 13
					row.Font = Enum.Font.GothamBold
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
				row.Size = UDim2.new(1, -12, 0, 126)
				row.LayoutOrder = order
				row.ZIndex = 92
				row.BackgroundColor3 = INPUT
				row.BorderSizePixel = 0
				row.Parent = PlayerScroll
				Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

				local avatar = Instance.new("ImageLabel")
				avatar.Name = "Avatar"
				avatar.Size = UDim2.fromOffset(44, 44)
				avatar.Position = UDim2.fromOffset(8, 18)
				avatar.ZIndex = 93
				avatar.BackgroundColor3 = CARD
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

				local displayName = Instance.new("TextLabel")
				displayName.Size = UDim2.new(1, -128, 0, 18)
				displayName.Position = UDim2.fromOffset(58, 4)
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
				usernameLabel.Size = UDim2.new(1, -128, 0, 16)
				usernameLabel.Position = UDim2.fromOffset(58, 22)
				usernameLabel.ZIndex = 93
				usernameLabel.BackgroundTransparency = 1
				usernameLabel.Text = "@" .. otherPlayer.Name
				usernameLabel.TextColor3 = Color3.fromRGB(185, 190, 200)
				usernameLabel.TextSize = 12
				usernameLabel.Font = Enum.Font.Gotham
				usernameLabel.TextXAlignment = Enum.TextXAlignment.Left
				usernameLabel.TextTruncate = Enum.TextTruncate.AtEnd
				usernameLabel.Parent = row

				local detail = Instance.new("TextLabel")
				detail.Size = UDim2.new(1, -128, 0, 16)
				detail.Position = UDim2.fromOffset(58, 40)
				detail.ZIndex = 93
				detail.BackgroundTransparency = 1
				detail.Text = distanceText
				detail.TextColor3 = Color3.fromRGB(185, 190, 200)
				detail.TextSize = 12
				detail.Font = Enum.Font.Gotham
				detail.TextXAlignment = Enum.TextXAlignment.Left
				detail.TextTruncate = Enum.TextTruncate.AtEnd
				detail.Parent = row

				local currentHP, maximumHP = configuration.GetPlayerHealth(otherPlayer)
				local healthLabel = Instance.new("TextLabel")
				healthLabel.Size = UDim2.new(1, -128, 0, 16)
				healthLabel.Position = UDim2.fromOffset(58, 58)
				healthLabel.ZIndex = 93
				healthLabel.BackgroundTransparency = 1
				healthLabel.Text = currentHP and string.format("HP %d / %d", currentHP, maximumHP) or "HP unavailable"
				if configuration.IsWhitelisted(otherPlayer) then
					healthLabel.Text ..= "  •  WHITELIST"
				end
				healthLabel.TextColor3 = configuration.GetHealthColor(currentHP, maximumHP)
				healthLabel.TextSize = 12
				healthLabel.Font = Enum.Font.Gotham
				healthLabel.TextXAlignment = Enum.TextXAlignment.Left
				healthLabel.TextTruncate = Enum.TextTruncate.AtEnd
				healthLabel.Parent = row

				local statsLabel = Instance.new("TextLabel")
				statsLabel.Name = "PlayerStats"
				statsLabel.Size = UDim2.new(1, -128, 0, 16)
				statsLabel.Position = UDim2.fromOffset(58, 76)
				statsLabel.ZIndex = 93
				statsLabel.BackgroundTransparency = 1
				statsLabel.Text = configuration.FormatPlayerStats(otherPlayer)
				statsLabel.TextColor3 = Color3.fromRGB(185, 190, 200)
				statsLabel.TextSize = 11
				statsLabel.Font = Enum.Font.Gotham
				statsLabel.TextXAlignment = Enum.TextXAlignment.Left
				statsLabel.TextTruncate = Enum.TextTruncate.AtEnd
				statsLabel.Parent = row

				if otherPlayer ~= Player then
					local playerEspButton = Instance.new("TextButton")
					playerEspButton.Name = "PlayerESPToggle"
					playerEspButton.Size = UDim2.fromOffset(58, 24)
					playerEspButton.Position = UDim2.new(1, -66, 0, 8)
					playerEspButton.ZIndex = 93
					playerEspButton.BackgroundColor3 = configuration.IsPlayerESPEnabled(otherPlayer) and Color3.fromRGB(34, 58, 48) or CARD
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
						playerEspButton.BackgroundColor3 = enabled and Color3.fromRGB(34, 58, 48) or CARD
					end)

					local whitelistToggle = Instance.new("TextButton")
					whitelistToggle.Name = "WhitelistToggle"
					whitelistToggle.Size = UDim2.fromOffset(58, 24)
					whitelistToggle.Position = UDim2.new(1, -66, 0, 36)
					whitelistToggle.ZIndex = 93
					whitelistToggle.BackgroundColor3 = configuration.IsWhitelisted(otherPlayer) and Color3.fromRGB(62, 52, 30) or CARD
					whitelistToggle.BorderSizePixel = 0
					whitelistToggle.Text = configuration.IsWhitelisted(otherPlayer) and "WL ON" or "WL ADD"
					whitelistToggle.TextColor3 = configuration.IsWhitelisted(otherPlayer) and YELLOW or MUTED
					whitelistToggle.TextSize = 9
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
						whitelistToggle.BackgroundColor3 = enabled and Color3.fromRGB(62, 52, 30) or CARD
						if WhitelistPanel.Visible then configuration.RefreshWhitelist() end
					end)

					if configuration.PlayerPanelMode == "follow" or configuration.PlayerPanelMode == "attack" then
						local followButton = Instance.new("TextButton")
						local selectingAttackTarget = configuration.PlayerPanelMode == "attack"
						followButton.Name = selectingAttackTarget and "AttackTargetSelect" or "FollowToggle"
						followButton.Size = UDim2.fromOffset(58, 24)
						followButton.Position = UDim2.new(1, -66, 0, 64)
						followButton.ZIndex = 93
						local isFollowing = configuration.FollowPlayerUserId == tostring(otherPlayer.UserId)
						followButton.BackgroundColor3 = isFollowing and ACCENT_DIM or CARD
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
					blockButton.Size = UDim2.fromOffset(58, 28)
					blockButton.Position = UDim2.new(1, -66, 1, -34)
					blockButton.ZIndex = 93
					blockButton.BackgroundColor3 = Color3.fromRGB(62, 35, 40)
					blockButton.BorderSizePixel = 0
					blockButton.Text = "Block"
					blockButton.TextColor3 = Color3.fromRGB(255, 155, 165)
					blockButton.TextSize = 11
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

		if configuration.AlertsEnabled and nearbyPlayer then
			AlarmOverlay.BackgroundColor3 = RED
			AlarmText.Text = string.format("PLAYER NEARBY  •  %s  •  %.0f studs", nearbyPlayer.Name, nearbyDistance)
			AlarmOverlay.Visible = true
		elseif configuration.AlertsEnabled and reachedMax then
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
