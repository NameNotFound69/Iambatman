-- Party leader following and server navigation for Iamrich.
-- The leader teleport flow follows AIC's in-game Party ChatEvent approach.
local VERSION = "1.2.0"
print("[PartySystem] Version " .. VERSION .. " (public server list + direct join)")
local PartySystem = {}

function PartySystem.Initialize(configuration, services)
	local Players = services.Players
	local Player = services.Player
	local ReplicatedStorage = services.ReplicatedStorage
	local TeleportService = services.TeleportService
	local HttpService = services.HttpService
	local state = {
		Busy = false,
		Teleporting = false,
		Generation = 0,
		CooldownUntil = 0,
		Status = "IDLE",
		UI = {},
	}
	local SetLeader

	local function Notify(title, message, duration)
		if configuration.NotifyUser then
			configuration.NotifyUser(title, message, duration or 5)
		end
	end

	local function GetLeader()
		local userId = tonumber(configuration.PartyLeaderUserId)
		local name = configuration.PartyLeaderName
		if userId and userId > 0 and type(name) == "string" and name ~= "" then
			return { UserId = userId, Name = name }
		end
		return nil
	end

	local function IsLeader(player)
		local leader = GetLeader()
		return leader ~= nil and player ~= nil
			and (player.UserId == leader.UserId or player.Name == leader.Name)
	end

	local function IsLeaderPresent()
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if IsLeader(otherPlayer) then return true end
		end
		return false
	end

	local function SetStatus(value)
		state.Status = tostring(value)
		if state.UI.Status then state.UI.Status.Text = "STATUS  ·  " .. state.Status end
	end

	local function RefreshLeaderLabel()
		local leader = GetLeader()
		if state.UI.Leader then
			state.UI.Leader.Text = leader and ("LEADER  ·  @" .. leader.Name)
				or "LEADER  ·  none"
		end
	end

	local function RefreshPlayerRows()
		local list = state.UI.PlayerList
		if not list then return end
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then child:Destroy() end
		end

		local others = {}
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= Player then table.insert(others, otherPlayer) end
		end
		table.sort(others, function(a, b) return string.lower(a.Name) < string.lower(b.Name) end)

		for order, otherPlayer in ipairs(others) do
			local row = Instance.new("TextButton")
			row.Name = "PartyLeader_" .. tostring(otherPlayer.UserId)
			row.Size = UDim2.new(1, -8, 0, 32)
			row.LayoutOrder = order
			row.BackgroundColor3 = IsLeader(otherPlayer) and Color3.fromRGB(32, 56, 96) or Color3.fromRGB(32, 36, 50)
			row.BorderSizePixel = 0
			row.AutoButtonColor = true
			row.Text = (IsLeader(otherPlayer) and "✓  " or "") .. "@" .. otherPlayer.Name
			row.TextColor3 = IsLeader(otherPlayer) and Color3.fromRGB(120, 180, 255) or Color3.fromRGB(236, 240, 248)
			row.TextSize = 12
			row.Font = Enum.Font.GothamMedium
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Parent = list
			Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)
			row.MouseButton1Click:Connect(function()
				if otherPlayer.Parent ~= Players then return end
				SetLeader(otherPlayer)
				Notify("Party", "Leader set to @" .. otherPlayer.Name)
			end)
		end
		if #others == 0 then
			local empty = Instance.new("TextLabel")
			empty.Name = "Empty"
			empty.Size = UDim2.new(1, -8, 0, 30)
			empty.BackgroundTransparency = 1
			empty.Text = "No other players in this server"
			empty.TextColor3 = Color3.fromRGB(130, 138, 158)
			empty.TextSize = 11
			empty.Font = Enum.Font.Gotham
			empty.Parent = list
		end
	end

	local function StopFarmForParty()
		if not configuration.Farming then return end
		configuration.PartyResumeFarmOnJoin = true
		configuration.SaveConfig()
		if configuration.SetIdle then
			configuration.SetIdle(false)
		else
			configuration.Farming = false
			if configuration.StopExpMovement then configuration.StopExpMovement() end
		end
	end

	local function ResumeFarmNow()
		if configuration.PartyResumeFarmOnJoin ~= true then return end
		configuration.PartyResumeFarmOnJoin = false
		configuration.SaveConfig()
		task.defer(function()
			if configuration.SetRunning and not configuration.EmergencyStopActive then
				configuration.SetRunning()
			end
		end)
	end

	local function ResumeFarmAfterFailure()
		if configuration.PartyResumeFarmOnJoin ~= true then return end
		configuration.PartyResumeFarmOnJoin = false
		configuration.SaveConfig()
		if configuration.SetRunning and not configuration.EmergencyStopActive then
			configuration.SetRunning()
		end
	end

	local function ResumeFarmAfterJoin()
		if configuration.PartyResumeFarmOnJoin ~= true then return end
		configuration.PartyResumeFarmOnJoin = false
		configuration.SaveConfig()
		task.spawn(function()
			for _ = 1, 20 do
				if not configuration.PartyFollowEnabled or not IsLeaderPresent() then return end
				if configuration.SetRunning then
					configuration.SetRunning()
					if configuration.Farming then return end
				end
				task.wait(0.5)
			end
			Notify("Party", "Joined the leader. Press Start to resume farming.")
		end)
	end

	local function ResetCharacter(generation)
		local character = Player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end
		SetStatus("RESPAWNING")
		local respawned = false
		local connection = Player.CharacterAdded:Connect(function() respawned = true end)
		pcall(function() humanoid.Health = 0 end)
		local deadline = os.clock() + 12
		repeat task.wait(0.25) until respawned or os.clock() >= deadline or generation ~= state.Generation
		connection:Disconnect()
		if respawned and generation == state.Generation then task.wait(1) end
	end

	local function RequestLeaderTeleport(leaderName, generation)
		local chatEvent = ReplicatedStorage:FindFirstChild("ChatEvent", true)
		local teleportEvent = ReplicatedStorage:FindFirstChild("TeleportEvent", true)
		if not chatEvent or not chatEvent:IsA("RemoteEvent") then
			return false, "ChatEvent was not found"
		end
		if teleportEvent and teleportEvent:IsA("RemoteEvent") then
			local ok = pcall(function() teleportEvent:FireServer(0) end)
			if not ok then return false, "TeleportEvent failed" end
		end
		task.wait(0.5)
		if generation ~= state.Generation or not configuration.PartyFollowEnabled then return false, "cancelled" end
		local ok, err = pcall(function() chatEvent:FireServer("Party", "tp friend " .. leaderName) end)
		return ok, err
	end

	local function FollowLeader()
		if state.Busy or not configuration.PartyFollowEnabled or not GetLeader() then return end
		state.Busy = true
		state.Generation += 1
		local generation = state.Generation
		StopFarmForParty()
		ResetCharacter(generation)
		if generation ~= state.Generation or not configuration.PartyFollowEnabled then
			state.Busy = false
			SetStatus("IDLE")
			return
		end
		if IsLeaderPresent() then
			state.Busy = false
			SetStatus("WITH LEADER")
			ResumeFarmAfterJoin()
			return
		end

		local leader = GetLeader()
		if not leader then
			state.Busy = false
			SetStatus("NO LEADER")
			return
		end
		local attempts = 3
		for attempt = 1, attempts do
			if generation ~= state.Generation or not configuration.PartyFollowEnabled then break end
			if IsLeaderPresent() then break end
			SetStatus(string.format("TP TO @%s  %d/%d", leader.Name, attempt, attempts))
			local ok, err = RequestLeaderTeleport(leader.Name, generation)
			if not ok and err ~= "cancelled" then
				Notify("Party", "Could not request leader teleport: " .. tostring(err))
			end
			local deadline = os.clock() + 15
			repeat task.wait(0.5) until IsLeaderPresent() or os.clock() >= deadline
				or generation ~= state.Generation or not configuration.PartyFollowEnabled
			if IsLeaderPresent() then break end
		end

		state.Busy = false
		if IsLeaderPresent() then
			state.CooldownUntil = 0
			SetStatus("WITH LEADER")
			ResumeFarmAfterJoin()
		elseif configuration.PartyFollowEnabled and generation == state.Generation then
			state.CooldownUntil = os.clock() + 60
			SetStatus("TP FAILED · RETRY IN 60S")
			ResumeFarmAfterFailure()
			Notify("Party", "Could not join the leader after 3 attempts.", 6)
		else
			SetStatus("IDLE")
		end
	end

	local function SetEnabled(enabled)
		configuration.PartyFollowEnabled = enabled == true
		state.Generation += 1
		state.CooldownUntil = 0
		if not configuration.PartyFollowEnabled then
			state.Busy = false
			SetStatus("OFF")
			ResumeFarmNow()
		else
			SetStatus(not GetLeader() and "NO LEADER" or (IsLeaderPresent() and "WITH LEADER" or "SEARCHING"))
		end
		if state.UI.Toggle then
			configuration.SetToggleVisual(state.UI.Toggle, "Follow party leader", configuration.PartyFollowEnabled, Color3.fromRGB(90, 160, 255), Color3.fromRGB(32, 56, 96))
		end
		configuration.SaveConfig()
		return configuration.PartyFollowEnabled
	end

	SetLeader = function(player)
		state.Generation += 1
		state.Busy = false
		if player and player ~= Player and player.Parent == Players then
			configuration.PartyLeaderUserId = player.UserId
			configuration.PartyLeaderName = player.Name
		else
			configuration.PartyLeaderUserId = nil
			configuration.PartyLeaderName = nil
			if configuration.PartyFollowEnabled then
				configuration.PartyFollowEnabled = false
				if state.UI.Toggle then
					configuration.SetToggleVisual(state.UI.Toggle, "Follow party leader", false, Color3.fromRGB(90, 160, 255), Color3.fromRGB(32, 56, 96))
				end
			end
		end
		state.CooldownUntil = 0
		RefreshLeaderLabel()
		RefreshPlayerRows()
		if configuration.PartyFollowEnabled then
			SetStatus(GetLeader() and (IsLeaderPresent() and "WITH LEADER" or "SEARCHING") or "NO LEADER")
		end
		configuration.SaveConfig()
		if not player then ResumeFarmNow() end
	end

	local function TeleportTo(instanceId, actionName)
		if state.Teleporting then return false end
		state.Teleporting = true
		SetStatus(actionName)
		task.spawn(function()
			local ok, err = pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, instanceId, Player)
			end)
			if not ok then
				state.Teleporting = false
				SetStatus("TELEPORT FAILED")
				Notify("Server", tostring(err), 6)
			end
		end)
		return true
	end

	local function RejoinServer()
		local jobId = tostring(game.JobId or "")
		if jobId == "" then
			Notify("Server", "This server does not expose a JobId, so Rejoin is unavailable.")
			return false
		end
		Notify("Server", "Rejoining this server…")
		return TeleportTo(jobId, "REJOINING SERVER")
	end

	local function ReadPublicServers(cursor)
		local results = {}
		local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
			.. "/servers/Public?sortOrder=Asc&limit=100"
		if type(cursor) == "string" and cursor ~= "" then
			url ..= "&cursor=" .. HttpService:UrlEncode(cursor)
		end
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if not ok then return nil, nil, body end
		local decodedOk, payload = pcall(function() return HttpService:JSONDecode(body) end)
		if not decodedOk or type(payload) ~= "table" or type(payload.data) ~= "table" then
			return nil, nil, "The public server list response was invalid"
		end
		for _, server in ipairs(payload.data) do
			local playing = tonumber(server.playing)
			local maxPlayers = tonumber(server.maxPlayers)
			if type(server.id) == "string" and server.id ~= game.JobId
				and playing and maxPlayers and playing < maxPlayers then
				table.insert(results, {
					Id = server.id,
					Playing = playing,
					MaxPlayers = maxPlayers,
					Ping = tonumber(server.ping),
					FPS = tonumber(server.fps),
				})
			end
		end
		return results, type(payload.nextPageCursor) == "string" and payload.nextPageCursor or nil
	end

	local function HopServer()
		if state.Teleporting then return false end
		SetStatus("FINDING SERVER")
		task.spawn(function()
			local cursor
			for _ = 1, 4 do
				local servers, nextCursor, err = ReadPublicServers(cursor)
				if not servers then
					SetStatus("HOP FAILED")
					Notify("Server hop", "Could not read the public server list: " .. tostring(err), 6)
					return
				end
				if #servers > 0 then
					local target = servers[math.random(1, #servers)].Id
					Notify("Server hop", "Joining another public server…")
					TeleportTo(target, "HOPPING SERVER")
					return
				end
				cursor = nextCursor
				if not cursor or cursor == "" then break end
			end
			SetStatus("NO OTHER SERVER")
			Notify("Server hop", "No different public server with free slots was found.", 6)
		end)
		return true
	end

	local function JoinServer(instanceId)
		if type(instanceId) ~= "string" or instanceId == "" or instanceId == game.JobId then
			Notify("Server", "That server ID is not valid or is already the current server.")
			return false
		end
		return TeleportTo(instanceId, "JOINING SELECTED SERVER")
	end

	local function BuildUI(palette)
		local page = configuration.CreatePage("Party", false)
		configuration.AddPageHeading(page, "Party", "Select a leader and follow them between servers")

		state.UI.Toggle = configuration.MakeToggle("Follow party leader", configuration.PartyFollowEnabled,
			palette.ACCENT, palette.ACCENT_DIM, 2, page, "Join the selected leader when they are in another server.")
		state.UI.Toggle.MouseButton1Click:Connect(function()
			SetEnabled(not configuration.PartyFollowEnabled)
		end)

		local info = Instance.new("Frame")
		info.Name = "PartyStatusCard"
		info.Size = UDim2.new(1, 0, 0, 58)
		info.LayoutOrder = 3
		info.BackgroundColor3 = palette.CARD
		info.BorderSizePixel = 0
		info.Parent = page
		Instance.new("UICorner", info).CornerRadius = UDim.new(0, 9)
		Instance.new("UIStroke", info).Color = palette.BORDER

		state.UI.Leader = Instance.new("TextLabel")
		state.UI.Leader.Size = UDim2.new(1, -20, 0, 20)
		state.UI.Leader.Position = UDim2.fromOffset(10, 7)
		state.UI.Leader.BackgroundTransparency = 1
		state.UI.Leader.TextColor3 = palette.TEXT
		state.UI.Leader.TextSize = 12
		state.UI.Leader.Font = Enum.Font.GothamBold
		state.UI.Leader.TextXAlignment = Enum.TextXAlignment.Left
		state.UI.Leader.Parent = info

		state.UI.Status = Instance.new("TextLabel")
		state.UI.Status.Size = UDim2.new(1, -20, 0, 18)
		state.UI.Status.Position = UDim2.fromOffset(10, 31)
		state.UI.Status.BackgroundTransparency = 1
		state.UI.Status.TextColor3 = palette.MUTED
		state.UI.Status.TextSize = 10
		state.UI.Status.Font = Enum.Font.Gotham
		state.UI.Status.TextXAlignment = Enum.TextXAlignment.Left
		state.UI.Status.Parent = info

		local listHeading = Instance.new("Frame")
		listHeading.Size = UDim2.new(1, 0, 0, 32)
		listHeading.LayoutOrder = 4
		listHeading.BackgroundTransparency = 1
		listHeading.Parent = page
		local listTitle = Instance.new("TextLabel")
		listTitle.Size = UDim2.new(0.57, 0, 1, 0)
		listTitle.BackgroundTransparency = 1
		listTitle.Text = "Party leader"
		listTitle.TextColor3 = palette.TEXT
		listTitle.TextSize = 12
		listTitle.Font = Enum.Font.GothamBold
		listTitle.TextXAlignment = Enum.TextXAlignment.Left
		listTitle.Parent = listHeading
		local refresh = Instance.new("TextButton")
		refresh.Size = UDim2.new(0.4, 0, 1, 0)
		refresh.Position = UDim2.new(0.6, 0, 0, 0)
		refresh.BackgroundColor3 = palette.INPUT
		refresh.BorderSizePixel = 0
		refresh.Text = "Refresh players"
		refresh.TextColor3 = palette.TEXT
		refresh.TextSize = 11
		refresh.Font = Enum.Font.GothamBold
		refresh.Parent = listHeading
		Instance.new("UICorner", refresh).CornerRadius = UDim.new(0, 7)
		refresh.MouseButton1Click:Connect(RefreshPlayerRows)

		state.UI.PlayerList = Instance.new("ScrollingFrame")
		state.UI.PlayerList.Name = "PartyPlayerList"
		state.UI.PlayerList.Size = UDim2.new(1, 0, 0, 164)
		state.UI.PlayerList.LayoutOrder = 5
		state.UI.PlayerList.BackgroundColor3 = palette.CARD
		state.UI.PlayerList.BorderSizePixel = 0
		state.UI.PlayerList.ScrollBarThickness = 3
		state.UI.PlayerList.ScrollBarImageColor3 = palette.MUTED
		state.UI.PlayerList.CanvasSize = UDim2.new()
		state.UI.PlayerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		state.UI.PlayerList.Parent = page
		Instance.new("UICorner", state.UI.PlayerList).CornerRadius = UDim.new(0, 9)
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 5)
		padding.PaddingLeft = UDim.new(0, 5)
		padding.PaddingRight = UDim.new(0, 5)
		padding.Parent = state.UI.PlayerList
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = state.UI.PlayerList

		local clear = Instance.new("TextButton")
		clear.Name = "ClearPartyLeader"
		clear.Size = UDim2.new(1, 0, 0, 36)
		clear.LayoutOrder = 6
		clear.BackgroundColor3 = palette.CARD
		clear.BorderSizePixel = 0
		clear.Text = "Clear leader"
		clear.TextColor3 = palette.RED
		clear.TextSize = 12
		clear.Font = Enum.Font.GothamBold
		clear.Parent = page
		Instance.new("UICorner", clear).CornerRadius = UDim.new(0, 8)
		clear.MouseButton1Click:Connect(function()
			SetLeader(nil)
			Notify("Party", "Leader cleared")
		end)

		RefreshLeaderLabel()
		RefreshPlayerRows()
		SetStatus(state.Status)
	end

	local function BuildServerUI(palette)
		local page = configuration.CreatePage("Server", false)
		configuration.AddPageHeading(page, "Server", "Browse public servers or join a specific one")
		state.UI.ServerPage = page

		local actions = Instance.new("Frame")
		actions.Name = "ServerActions"
		actions.Size = UDim2.new(1, 0, 0, 42)
		actions.LayoutOrder = 2
		actions.BackgroundTransparency = 1
		actions.Parent = page

		local function makeAction(name, text, xScale, color, callback)
			local button = Instance.new("TextButton")
			button.Name = name
			button.Size = UDim2.new(0.5, -5, 1, 0)
			button.Position = UDim2.new(xScale, xScale == 0 and 0 or 5, 0, 0)
			button.BackgroundColor3 = color
			button.BorderSizePixel = 0
			button.Text = text
			button.TextColor3 = palette.TEXT
			button.TextSize = 12
			button.Font = Enum.Font.GothamBold
			button.Parent = actions
			Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
			button.MouseButton1Click:Connect(callback)
			return button
		end

		makeAction("RejoinServer", "Rejoin", 0, palette.INPUT, RejoinServer)
		makeAction("HopServer", "Hop", 0.5, palette.ACCENT_DIM, HopServer)

		local status = Instance.new("TextLabel")
		status.Name = "ServerListStatus"
		status.Size = UDim2.new(1, 0, 0, 20)
		status.LayoutOrder = 3
		status.BackgroundTransparency = 1
		status.Text = "Loading public servers…"
		status.TextColor3 = palette.MUTED
		status.TextSize = 11
		status.Font = Enum.Font.Gotham
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.Parent = page
		state.UI.ServerStatus = status

		local listHeader = Instance.new("Frame")
		listHeader.Name = "ServerListHeader"
		listHeader.Size = UDim2.new(1, 0, 0, 32)
		listHeader.LayoutOrder = 4
		listHeader.BackgroundTransparency = 1
		listHeader.Parent = page

		local listTitle = Instance.new("TextLabel")
		listTitle.Size = UDim2.new(0.55, 0, 1, 0)
		listTitle.BackgroundTransparency = 1
		listTitle.Text = "Public servers"
		listTitle.TextColor3 = palette.TEXT
		listTitle.TextSize = 12
		listTitle.Font = Enum.Font.GothamBold
		listTitle.TextXAlignment = Enum.TextXAlignment.Left
		listTitle.Parent = listHeader

		local refresh = Instance.new("TextButton")
		refresh.Name = "RefreshServers"
		refresh.Size = UDim2.new(0.4, 0, 1, 0)
		refresh.Position = UDim2.new(0.6, 0, 0, 0)
		refresh.BackgroundColor3 = palette.INPUT
		refresh.BorderSizePixel = 0
		refresh.Text = "Refresh"
		refresh.TextColor3 = palette.TEXT
		refresh.TextSize = 11
		refresh.Font = Enum.Font.GothamBold
		refresh.Parent = listHeader
		Instance.new("UICorner", refresh).CornerRadius = UDim.new(0, 7)

		local list = Instance.new("ScrollingFrame")
		list.Name = "PublicServerList"
		list.Size = UDim2.new(1, 0, 0, 260)
		list.LayoutOrder = 5
		list.BackgroundColor3 = palette.CARD
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.ScrollBarImageColor3 = palette.MUTED
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.Parent = page
		state.UI.ServerList = list
		Instance.new("UICorner", list).CornerRadius = UDim.new(0, 9)
		Instance.new("UIStroke", list).Color = palette.BORDER
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 6)
		padding.PaddingBottom = UDim.new(0, 6)
		padding.PaddingLeft = UDim.new(0, 6)
		padding.PaddingRight = UDim.new(0, 6)
		padding.Parent = list
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 5)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list

		local loadMore = Instance.new("TextButton")
		loadMore.Name = "LoadMoreServers"
		loadMore.Size = UDim2.new(1, 0, 0, 36)
		loadMore.LayoutOrder = 6
		loadMore.BackgroundColor3 = palette.INPUT
		loadMore.BorderSizePixel = 0
		loadMore.Text = "Load more"
		loadMore.TextColor3 = palette.TEXT
		loadMore.TextSize = 11
		loadMore.Font = Enum.Font.GothamBold
		loadMore.Visible = false
		loadMore.Parent = page
		Instance.new("UICorner", loadMore).CornerRadius = UDim.new(0, 8)

		local cursor = nil
		local loading = false
		local entryCount = 0
		local function clearRows()
			for _, child in ipairs(list:GetChildren()) do
				if child ~= layout and child ~= padding then child:Destroy() end
			end
			entryCount = 0
		end

		local function addServerRow(server)
			entryCount += 1
			local row = Instance.new("Frame")
			row.Name = "Server_" .. tostring(entryCount)
			row.Size = UDim2.new(1, -2, 0, 72)
			row.LayoutOrder = entryCount
			row.BackgroundColor3 = palette.CARD or palette.INPUT
			row.BorderSizePixel = 0
			row.Parent = list
			Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
			local rowStroke = Instance.new("UIStroke", row)
			rowStroke.Color = palette.BORDER or Color3.fromRGB(40, 45, 60)
			rowStroke.Transparency = 0.55
			rowStroke.Thickness = 1

			local playing = tonumber(server.Playing) or 0
			local maxPlayers = tonumber(server.MaxPlayers) or 0
			local pingVal = tonumber(server.Ping)
			local fpsVal = tonumber(server.FPS)
			local shortId = string.sub(tostring(server.Id), 1, 8) .. "…" .. string.sub(tostring(server.Id), -6)

			local title = Instance.new("TextLabel")
			title.Name = "Title"
			title.Size = UDim2.new(1, -160, 0, 20)
			title.Position = UDim2.fromOffset(12, 8)
			title.BackgroundTransparency = 1
			title.Text = string.format("%d / %d players", playing, maxPlayers)
			title.TextColor3 = palette.TEXT
			title.TextSize = 13
			title.Font = Enum.Font.GothamBold
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Parent = row

			local meta = Instance.new("TextLabel")
			meta.Name = "Meta"
			meta.Size = UDim2.new(1, -160, 0, 18)
			meta.Position = UDim2.fromOffset(12, 30)
			meta.BackgroundTransparency = 1
			local pingText = pingVal and (tostring(math.floor(pingVal + 0.5)) .. " ms") or "n/a"
			local fpsText = fpsVal and tostring(math.floor(fpsVal + 0.5)) or "n/a"
			meta.Text = string.format("Ping %s   ·   FPS %s   ·   %s", pingText, fpsText, shortId)
			meta.TextColor3 = palette.MUTED
			meta.TextSize = 11
			meta.Font = Enum.Font.Gotham
			meta.TextXAlignment = Enum.TextXAlignment.Left
			meta.TextTruncate = Enum.TextTruncate.AtEnd
			meta.Parent = row

			local join = Instance.new("TextButton")
			join.Name = "JoinServer"
			join.Size = UDim2.fromOffset(64, 28)
			join.Position = UDim2.new(1, -72, 0.5, -14)
			join.BackgroundColor3 = palette.ACCENT_DIM
			join.BorderSizePixel = 0
			join.Text = "Join"
			join.TextColor3 = palette.TEXT
			join.TextSize = 12
			join.Font = Enum.Font.GothamBold
			join.Parent = row
			Instance.new("UICorner", join).CornerRadius = UDim.new(0, 7)
			join.MouseButton1Click:Connect(function()
				JoinServer(server.Id)
			end)

			local info = Instance.new("TextButton")
			info.Name = "InfoServer"
			info.Size = UDim2.fromOffset(52, 28)
			info.Position = UDim2.new(1, -130, 0.5, -14)
			info.BackgroundColor3 = palette.INPUT
			info.BorderSizePixel = 0
			info.Text = "Info"
			info.TextColor3 = palette.TEXT
			info.TextSize = 12
			info.Font = Enum.Font.GothamBold
			info.Parent = row
			Instance.new("UICorner", info).CornerRadius = UDim.new(0, 7)
			info.MouseButton1Click:Connect(function()
				if configuration.OpenServerInfo then
					configuration.OpenServerInfo(server)
				elseif Notify then
					Notify("Server", string.format("%d/%d players · Ping %s · FPS %s\n%s", playing, maxPlayers, pingText, fpsText, tostring(server.Id)), 8)
				end
			end)
		end

		local function loadServers(reset)
			if loading then return end
			if reset then
				cursor = nil
				clearRows()
			end
			if not reset and (type(cursor) ~= "string" or cursor == "") then return end
			loading = true
			refresh.Active = false
			loadMore.Active = false
			status.Text = reset and "Loading public servers…" or "Loading more servers…"
			task.spawn(function()
				local servers, nextCursor, err = ReadPublicServers(reset and nil or cursor)
				if not page.Parent then loading = false return end
				loading = false
				refresh.Active = true
				loadMore.Active = true
				if not servers then
					status.Text = "Could not load servers: " .. tostring(err)
					loadMore.Visible = false
					return
				end
				for _, server in ipairs(servers) do addServerRow(server) end
				cursor = nextCursor
				loadMore.Visible = type(cursor) == "string" and cursor ~= ""
				if entryCount == 0 then
					status.Text = "No public servers with free slots were found."
				elseif loadMore.Visible then
					status.Text = tostring(entryCount) .. " servers loaded. More are available."
				else
					status.Text = tostring(entryCount) .. " servers loaded."
				end
			end)
		end

		refresh.MouseButton1Click:Connect(function() loadServers(true) end)
		loadMore.MouseButton1Click:Connect(function() loadServers(false) end)
		task.defer(function() loadServers(true) end)
	end

	local module = {
		SetEnabled = SetEnabled,
		SetLeader = SetLeader,
		RejoinServer = RejoinServer,
		HopServer = HopServer,
		BuildUI = BuildUI,
		BuildServerUI = BuildServerUI,
		GetStatus = function() return state.Status end,
	}

	Players.PlayerAdded:Connect(function()
		RefreshPlayerRows()
		if IsLeaderPresent() then
			state.CooldownUntil = 0
			SetStatus("WITH LEADER")
			ResumeFarmAfterJoin()
		end
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(RefreshPlayerRows)
	end)
	TeleportService.TeleportInitFailed:Connect(function(player, _, errorMessage)
		if player == Player then
			state.Teleporting = false
			SetStatus("TELEPORT FAILED")
			Notify("Server", tostring(errorMessage or "Teleport failed"), 6)
		end
	end)

	task.spawn(function()
		while task.wait(0.75) do
			if not configuration.PartyFollowEnabled or not GetLeader() then
				if not configuration.PartyFollowEnabled then SetStatus("OFF") end
				continue
			end
			if IsLeaderPresent() then
				state.CooldownUntil = 0
				if state.Status ~= "WITH LEADER" then SetStatus("WITH LEADER") end
				ResumeFarmAfterJoin()
			elseif not state.Busy and os.clock() >= state.CooldownUntil then
				task.spawn(FollowLeader)
			end
		end
	end)

	RefreshLeaderLabel()
	if configuration.PartyFollowEnabled then SetStatus(IsLeaderPresent() and "WITH LEADER" or "SEARCHING") end
	return module
end

return PartySystem
