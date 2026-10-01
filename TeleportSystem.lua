-- Teleport menu adapted from Teleport.txt for Iamrich's page-based UI.
local VERSION = "1.0.1"
print("[TeleportSystem] Version " .. VERSION .. " (doors + waypoint teleports, refresh icon)")

return {
	Initialize = function(configuration, services)
		local replicatedStorage = services.ReplicatedStorage
		local world = services.Workspace or workspace
		local state = { UI = {}, FolderConnections = {}, WorldConnections = {} }

		local function notify(message)
			if configuration.NotifyUser then
				configuration.NotifyUser("Teleport", message, 5)
			end
		end

		local function getRemote()
			local remote = replicatedStorage and replicatedStorage:FindFirstChild("TeleportEvent", true)
			return remote and remote:IsA("RemoteEvent") and remote or nil
		end

		local function fireTeleport(value)
			local remote = getRemote()
			if not remote then
				if state.UI.Status then state.UI.Status.Text = "TeleportEvent is unavailable." end
				notify("TeleportEvent was not found")
				return false
			end
			local ok, err = pcall(function() remote:FireServer(value) end)
			if not ok then
				if state.UI.Status then state.UI.Status.Text = "Teleport request failed." end
				notify("Teleport request failed: " .. tostring(err))
				return false
			end
			return true
		end

		local function findFolders()
			state.Interactions = world:FindFirstChild("Interactions")
			state.Waypoints = world:FindFirstChild("Waypoints")
		end

		local function buildPanel(parent, name, title, accent, layoutOrder, palette)
			local panel = Instance.new("Frame")
			panel.Name = name
			panel.Size = UDim2.new(1, 0, 0, 314)
			panel.LayoutOrder = layoutOrder
			panel.BackgroundTransparency = 1
			panel.Visible = false
			panel.Parent = parent

			local header = Instance.new("Frame")
			header.Size = UDim2.new(1, 0, 0, 30)
			header.BackgroundTransparency = 1
			header.Parent = panel

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -96, 1, 0)
			label.BackgroundTransparency = 1
			label.Text = title
			label.TextColor3 = palette.MUTED
			label.TextSize = 11
			label.Font = Enum.Font.GothamBold
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Parent = header

			local count = Instance.new("TextLabel")
			count.Size = UDim2.new(0, 76, 1, 0)
			count.Position = UDim2.new(1, -110, 0, 0)
			count.BackgroundTransparency = 1
			count.Text = "0"
			count.TextColor3 = accent
			count.TextSize = 10
			count.Font = Enum.Font.GothamBold
			count.TextXAlignment = Enum.TextXAlignment.Right
			count.Parent = header

			local refresh = Instance.new("TextButton")
			refresh.Name = "Refresh"
			refresh.Size = UDim2.fromOffset(28, 26)
			refresh.Position = UDim2.new(1, -32, 0, 2)
			refresh.BackgroundColor3 = palette.INPUT
			refresh.BorderSizePixel = 0
			refresh.Text = ""
			refresh.Parent = header
			Instance.new("UICorner", refresh).CornerRadius = UDim.new(0, 6)

			-- Draw the refresh mark from UI primitives so it does not depend on a
			-- font having the Unicode refresh glyph available.
			local refreshRing = Instance.new("Frame")
			refreshRing.Name = "RefreshRing"
			refreshRing.Size = UDim2.fromOffset(14, 14)
			refreshRing.Position = UDim2.new(0.5, -7, 0.5, -7)
			refreshRing.BackgroundTransparency = 1
			refreshRing.BorderSizePixel = 0
			refreshRing.ZIndex = refresh.ZIndex + 1
			refreshRing.Parent = refresh
			Instance.new("UICorner", refreshRing).CornerRadius = UDim.new(1, 0)
			local refreshStroke = Instance.new("UIStroke")
			refreshStroke.Color = accent
			refreshStroke.Thickness = 2
			refreshStroke.Parent = refreshRing

			local refreshGap = Instance.new("Frame")
			refreshGap.Name = "ArrowGap"
			refreshGap.Size = UDim2.fromOffset(7, 7)
			refreshGap.Position = UDim2.new(0.5, 2, 0, 2)
			refreshGap.BackgroundColor3 = palette.INPUT
			refreshGap.BorderSizePixel = 0
			refreshGap.ZIndex = refresh.ZIndex + 2
			refreshGap.Parent = refresh

			for _, arrowArm in ipairs({
				{ Position = UDim2.new(0.5, 1, 0, 4), Rotation = 25 },
				{ Position = UDim2.new(0.5, 1, 0, 7), Rotation = -45 },
			}) do
				local arm = Instance.new("Frame")
				arm.Name = "RefreshArrow"
				arm.Size = UDim2.fromOffset(6, 2)
				arm.Position = arrowArm.Position
				arm.Rotation = arrowArm.Rotation
				arm.BackgroundColor3 = accent
				arm.BorderSizePixel = 0
				arm.ZIndex = refresh.ZIndex + 3
				arm.Parent = refresh
				Instance.new("UICorner", arm).CornerRadius = UDim.new(1, 0)
			end

			local list = Instance.new("ScrollingFrame")
			list.Name = name .. "List"
			list.Size = UDim2.new(1, 0, 1, -36)
			list.Position = UDim2.fromOffset(0, 34)
			list.BackgroundColor3 = palette.CARD
			list.BackgroundTransparency = 0.08
			list.BorderSizePixel = 0
			list.ScrollBarThickness = 4
			list.ScrollBarImageColor3 = accent
			list.CanvasSize = UDim2.new()
			list.AutomaticCanvasSize = Enum.AutomaticSize.Y
			list.ScrollingDirection = Enum.ScrollingDirection.Y
			list.Parent = panel
			Instance.new("UICorner", list).CornerRadius = UDim.new(0, 9)
			Instance.new("UIStroke", list).Color = palette.BORDER
			local padding = Instance.new("UIPadding")
			padding.PaddingTop = UDim.new(0, 7)
			padding.PaddingBottom = UDim.new(0, 7)
			padding.PaddingLeft = UDim.new(0, 7)
			padding.PaddingRight = UDim.new(0, 7)
			padding.Parent = list
			local layout = Instance.new("UIListLayout")
			layout.Padding = UDim.new(0, 5)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = list

			return panel, count, refresh, list, layout, padding
		end

		local function BuildUI(palette)
			local page = configuration.CreatePage("Teleport", false)
			configuration.AddPageHeading(page, "Teleport", "Travel to a door location or game waypoint")
			state.UI.Page = page

			local tabs = Instance.new("Frame")
			tabs.Name = "TeleportTabs"
			tabs.Size = UDim2.new(1, 0, 0, 38)
			tabs.LayoutOrder = 2
			tabs.BackgroundColor3 = palette.CARD
			tabs.BorderSizePixel = 0
			tabs.Parent = page
			Instance.new("UICorner", tabs).CornerRadius = UDim.new(0, 9)

			local content = Instance.new("Frame")
			content.Name = "TeleportContent"
			content.Size = UDim2.new(1, 0, 0, 314)
			content.LayoutOrder = 3
			content.BackgroundTransparency = 1
			content.Parent = page

			local doorPanel, doorCount, doorRefresh, doorList, doorLayout, doorPadding =
				buildPanel(content, "DoorLocations", "AVAILABLE LOCATIONS", palette.ACCENT, 1, palette)
			local waypointPanel, waypointCount, waypointRefresh, waypointList, waypointLayout, waypointPadding =
				buildPanel(content, "GameWaypoints", "WAYPOINTS", Color3.fromRGB(105, 155, 220), 1, palette)
			state.UI.DoorCount = doorCount
			state.UI.DoorRefresh = doorRefresh
			state.UI.DoorList = doorList
			state.UI.DoorLayout = doorLayout
			state.UI.DoorPadding = doorPadding
			state.UI.WaypointCount = waypointCount
			state.UI.WaypointRefresh = waypointRefresh
			state.UI.WaypointList = waypointList
			state.UI.WaypointLayout = waypointLayout
			state.UI.WaypointPadding = waypointPadding

			local function makeTab(name, text, xScale, color)
				local button = Instance.new("TextButton")
				button.Name = name
				button.Size = UDim2.new(0.5, -6, 1, -6)
				button.Position = UDim2.new(xScale, 3, 0, 3)
				button.BackgroundColor3 = color
				button.BorderSizePixel = 0
				button.Text = text
				button.TextColor3 = palette.TEXT
				button.TextSize = 11
				button.Font = Enum.Font.GothamBold
				button.Parent = tabs
				Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
				return button
			end

			local doorTab = makeTab("DoorsTab", "DOORS", 0, palette.ACCENT_DIM)
			local waypointTab = makeTab("WaypointsTab", "WAYPOINTS", 0.5, palette.INPUT)
			local function selectTab(showDoors)
				doorPanel.Visible = showDoors
				waypointPanel.Visible = not showDoors
				doorTab.BackgroundColor3 = showDoors and palette.ACCENT_DIM or palette.INPUT
				waypointTab.BackgroundColor3 = showDoors and palette.INPUT or palette.ACCENT_DIM
			end
			doorTab.MouseButton1Click:Connect(function() selectTab(true) end)
			waypointTab.MouseButton1Click:Connect(function() selectTab(false) end)
			selectTab(true)

			local status = Instance.new("TextLabel")
			status.Name = "TeleportStatus"
			status.Size = UDim2.new(1, 0, 0, 20)
			status.LayoutOrder = 4
			status.BackgroundTransparency = 1
			status.Text = getRemote() and "Select a destination." or "TeleportEvent is unavailable."
			status.TextColor3 = palette.MUTED
			status.TextSize = 11
			status.Font = Enum.Font.Gotham
			status.TextXAlignment = Enum.TextXAlignment.Left
			status.Parent = page
			state.UI.Status = status

			local function clearRows(list, layout, padding)
				for _, child in ipairs(list:GetChildren()) do
					if child ~= layout and child ~= padding then child:Destroy() end
				end
			end

			local function addEmpty(list, text, paletteText)
				local empty = Instance.new("TextLabel")
				empty.Name = "Empty"
				empty.Size = UDim2.new(1, -8, 0, 38)
				empty.BackgroundTransparency = 1
				empty.Text = text
				empty.TextColor3 = paletteText
				empty.TextSize = 10
				empty.Font = Enum.Font.GothamBold
				empty.Parent = list
			end

			local function makeDoorRow(door, order)
				if not door:IsA("Model") or door.Name ~= "Door" then return false end
				local place = door:FindFirstChild("Place")
				if not place or not place:IsA("ValueBase") then return false end
				local points = {}
				for _, pointName in ipairs({ "T1", "T2" }) do
					local point = door:FindFirstChild(pointName)
					if point and point:IsA("BasePart") then
						table.insert(points, { Name = pointName, Object = point })
					end
				end
				if #points == 0 then return false end

				local row = Instance.new("Frame")
				row.Name = "Door_" .. tostring(place.Value)
				row.Size = UDim2.new(1, -2, 0, 54)
				row.LayoutOrder = order
				row.BackgroundColor3 = palette.INPUT
				row.BorderSizePixel = 0
				row.Parent = doorList
				Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)

				local title = Instance.new("TextLabel")
				title.Size = UDim2.new(1, -100, 0, 21)
				title.Position = UDim2.fromOffset(10, 5)
				title.BackgroundTransparency = 1
				title.Text = tostring(place.Value)
				title.TextColor3 = palette.TEXT
				title.TextSize = 12
				title.Font = Enum.Font.GothamMedium
				title.TextXAlignment = Enum.TextXAlignment.Left
				title.TextTruncate = Enum.TextTruncate.AtEnd
				title.Parent = row

				local sub = Instance.new("TextLabel")
				sub.Size = UDim2.new(1, -100, 0, 16)
				sub.Position = UDim2.fromOffset(10, 28)
				sub.BackgroundTransparency = 1
				local names = {}
				for _, point in ipairs(points) do table.insert(names, point.Name) end
				sub.Text = table.concat(names, " / ") .. " / READY"
				sub.TextColor3 = palette.MUTED
				sub.TextSize = 9
				sub.Font = Enum.Font.Gotham
				sub.TextXAlignment = Enum.TextXAlignment.Left
				sub.Parent = row

				local buttonWidth, gap = 38, 5
				local totalWidth = #points * buttonWidth + (#points - 1) * gap
				for index, point in ipairs(points) do
					local pointName, teleportObject = point.Name, point.Object
					local button = Instance.new("TextButton")
					button.Name = pointName
					button.Size = UDim2.fromOffset(buttonWidth, 30)
					button.Position = UDim2.new(1, -8 - totalWidth + (index - 1) * (buttonWidth + gap), 0.5, -15)
					button.BackgroundColor3 = palette.ACCENT_DIM
					button.BorderSizePixel = 0
					button.Text = pointName
					button.TextColor3 = palette.TEXT
					button.TextSize = 10
					button.Font = Enum.Font.GothamBold
					button.Parent = row
					Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
					button.MouseButton1Click:Connect(function()
						if teleportObject.Parent then fireTeleport(teleportObject.Position) end
					end)
				end
				return true
			end

			local refreshingDoors = false
			local function refreshDoors()
				if refreshingDoors then return end
				refreshingDoors = true
				findFolders()
				clearRows(doorList, doorLayout, doorPadding)
				local count = 0
				if state.Interactions then
					local doors = state.Interactions:GetChildren()
					table.sort(doors, function(a, b)
						local aPlace = a:FindFirstChild("Place")
						local bPlace = b:FindFirstChild("Place")
						local aValue = aPlace and aPlace:IsA("ValueBase") and aPlace.Value
						local bValue = bPlace and bPlace:IsA("ValueBase") and bPlace.Value
						return tostring(aValue or a.Name) < tostring(bValue or b.Name)
					end)
					for _, door in ipairs(doors) do
						if makeDoorRow(door, count + 1) then count += 1 end
					end
				end
				doorCount.Text = tostring(count) .. " LOCATIONS"
				if count == 0 then addEmpty(doorList, state.Interactions and "No door locations found." or "Interactions folder not found.", palette.MUTED) end
				refreshingDoors = false
				if not getRemote() then status.Text = "TeleportEvent is unavailable." end
			end

			local refreshingWaypoints = false
			local function refreshWaypoints()
				if refreshingWaypoints then return end
				refreshingWaypoints = true
				findFolders()
				clearRows(waypointList, waypointLayout, waypointPadding)
				local defaultButton = Instance.new("TextButton")
				defaultButton.Name = "Waypoint_0"
				defaultButton.Size = UDim2.new(1, -2, 0, 48)
				defaultButton.LayoutOrder = 0
				defaultButton.BackgroundColor3 = palette.INPUT
				defaultButton.BorderSizePixel = 0
				defaultButton.Text = "DEFAULT  ·  Waypoint #0"
				defaultButton.TextColor3 = palette.TEXT
				defaultButton.TextSize = 12
				defaultButton.Font = Enum.Font.GothamMedium
				defaultButton.Parent = waypointList
				Instance.new("UICorner", defaultButton).CornerRadius = UDim.new(0, 7)
				defaultButton.MouseButton1Click:Connect(function() fireTeleport(0) end)

				local numbers = {}
				if state.Waypoints then
					for _, waypoint in ipairs(state.Waypoints:GetChildren()) do
						local number = tonumber(waypoint.Name)
						if number and number % 1 == 0 and number ~= 0 then table.insert(numbers, number) end
					end
				end
				table.sort(numbers)
				for _, number in ipairs(numbers) do
					local waypointNumber = number
					local button = Instance.new("TextButton")
					button.Name = "Waypoint_" .. tostring(waypointNumber)
					button.Size = UDim2.new(1, -2, 0, 48)
					button.LayoutOrder = waypointNumber
					button.BackgroundColor3 = palette.INPUT
					button.BorderSizePixel = 0
					button.Text = "WAYPOINT  ·  #" .. tostring(waypointNumber)
					button.TextColor3 = palette.TEXT
					button.TextSize = 12
					button.Font = Enum.Font.GothamMedium
					button.Parent = waypointList
					Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
					button.MouseButton1Click:Connect(function() fireTeleport(waypointNumber) end)
				end
				waypointCount.Text = tostring(#numbers + 1) .. " WAYPOINTS"
				if not state.Waypoints then addEmpty(waypointList, "Waypoints folder not found.", palette.MUTED) end
				refreshingWaypoints = false
				if not getRemote() then status.Text = "TeleportEvent is unavailable." end
			end

			doorRefresh.MouseButton1Click:Connect(refreshDoors)
			waypointRefresh.MouseButton1Click:Connect(refreshWaypoints)

			local function unbindFolders()
				for _, connection in ipairs(state.FolderConnections) do connection:Disconnect() end
				table.clear(state.FolderConnections)
			end
			local function bindFolders()
				unbindFolders()
				findFolders()
				if state.Interactions then
					table.insert(state.FolderConnections, state.Interactions.ChildAdded:Connect(function() task.defer(refreshDoors) end))
					table.insert(state.FolderConnections, state.Interactions.ChildRemoved:Connect(function() task.defer(refreshDoors) end))
				end
				if state.Waypoints then
					table.insert(state.FolderConnections, state.Waypoints.ChildAdded:Connect(function() task.defer(refreshWaypoints) end))
					table.insert(state.FolderConnections, state.Waypoints.ChildRemoved:Connect(function() task.defer(refreshWaypoints) end))
				end
				refreshDoors()
				refreshWaypoints()
			end

			table.insert(state.WorldConnections, world.ChildAdded:Connect(function(child)
				if child.Name == "Interactions" or child.Name == "Waypoints" then task.defer(bindFolders) end
			end))
			table.insert(state.WorldConnections, world.ChildRemoved:Connect(function(child)
				if child.Name == "Interactions" or child.Name == "Waypoints" then task.defer(bindFolders) end
			end))
			bindFolders()
		end

		return { BuildUI = BuildUI }
	end,
}
