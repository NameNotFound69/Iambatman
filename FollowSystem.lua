-- Breadcrumb follow controller. Uses MoveTo through CombatSystem.Navigation.
local VERSION = "1.7.0"
print("[FollowSystem] Version " .. VERSION .. " (curve-aware trail + follow queue + yielding + route display + paced interact)")

return {
	Initialize = function(configuration, dependencies)
		local Players = dependencies.Players
		local CombatSystem = configuration.CombatSystem
		local ClaimMovement = dependencies.ClaimMovement
		local ReleaseMovement = dependencies.ReleaseMovement
		local trailFolderName = "IamrichFollowTrail_" .. tostring(Players.LocalPlayer.UserId)
		local oldTrailFolder = workspace:FindFirstChild(trailFolderName)
		if oldTrailFolder then oldTrailFolder:Destroy() end
		local trailFolder = Instance.new("Folder")
		trailFolder.Name = trailFolderName
		trailFolder.Parent = workspace
		local state = {
			Trail = {},
			Cursor = 1,
			TargetUserId = nil,
			LastSampleAt = 0,
			LastUpdateAt = 0,
			LastProgressAt = 0,
			ProgressPosition = nil,
			RecoveryAttempts = 0,
			RecoveryGoal = nil,
			RecoveryUntil = 0,
			AvoidUserId = nil,
			AvoidOffset = nil,
			TrailVisible = configuration.FollowTrailVisible == true,
			VisualPointCount = 0,
			VisualNeedsRebuild = false,
			Interaction = {
				LeaderMoved = false,
				LeaderMovingSince = nil,
				LeaderStoppedSince = nil,
				StopPosition = nil,
				PendingUntil = 0,
				StopEventCreated = false,
				LastAttemptAt = 0,
			},
			Navigation = { Active = false, Goal = nil, LastMoveAt = 0 },
		}

		local FOLLOW_INTERACTION_INTERVAL = 1.5
		local LEADER_STOP_CONFIRM_TIME = 0.65
		local LEADER_MOVE_CONFIRM_TIME = 0.35
		local INTERACTION_PENDING_TIME = 8
		local FOLLOWER_GAP = 5.5
		local FOLLOWER_TRAIL_RADIUS = 6

		local function clearVisualTrail()
			for _, segment in ipairs(trailFolder:GetChildren()) do
				segment:Destroy()
			end
			state.VisualPointCount = 0
			state.VisualNeedsRebuild = false
		end

		local function createVisualSegment(fromPosition, toPosition, index)
			-- Keep the route near foot level instead of drawing it through the leader's torso.
			fromPosition -= Vector3.new(0, 2.4, 0)
			toPosition -= Vector3.new(0, 2.4, 0)
			local delta = toPosition - fromPosition
			local length = delta.Magnitude
			if length < 0.1 then return end
			local segment = Instance.new("Part")
			segment.Name = string.format("Trail_%03d", index)
			segment.Anchored = true
			segment.CanCollide = false
			segment.CanTouch = false
			segment.CanQuery = false
			segment.CastShadow = false
			segment.Material = Enum.Material.Neon
			segment.Color = Color3.fromRGB(70, 190, 255)
			segment.Transparency = 0.18
			segment.Size = Vector3.new(0.16, 0.16, length)
			segment.CFrame = CFrame.lookAt((fromPosition + toPosition) * 0.5, toPosition)
			segment.Parent = trailFolder
		end

		local function renderTrail()
			local visible = configuration.FollowTrailVisible == true
			if visible ~= state.TrailVisible then
				state.TrailVisible = visible
				state.VisualNeedsRebuild = true
			end
			if not state.TrailVisible then
				if state.VisualPointCount > 0 or #trailFolder:GetChildren() > 0 then clearVisualTrail() end
				return
			end
			if state.VisualNeedsRebuild then clearVisualTrail() end
			local trail = state.Trail
			local firstSegment = math.max(1, state.VisualPointCount)
			for index = firstSegment, #trail - 1 do
				local fromPoint, toPoint = trail[index], trail[index + 1]
				-- The first breadcrumb is a synthetic spacing seed, not a place the
				-- leader actually walked through.
				if not fromPoint.Synthetic and not toPoint.Synthetic then
					createVisualSegment(fromPoint.Position, toPoint.Position, index)
				end
			end
			state.VisualPointCount = #trail
		end

		local function clearTrail()
			table.clear(state.Trail)
			state.VisualNeedsRebuild = true
			state.Cursor = 1
			state.LastSampleAt = 0
			state.LastProgressAt = 0
			state.ProgressPosition = nil
			state.RecoveryAttempts = 0
			state.RecoveryGoal = nil
			state.RecoveryUntil = 0
			state.AvoidUserId = nil
			state.AvoidOffset = nil
		end

		local function resetNavigation()
			CombatSystem.ResetNavigationState(state.Navigation)
		end

		local function reset(humanoid, root)
			ReleaseMovement("Follow", humanoid, root)
			resetNavigation()
			clearTrail()
			state.TargetUserId = nil
			state.LastUpdateAt = 0
			state.Interaction.LeaderMoved = false
			state.Interaction.LeaderMovingSince = nil
			state.Interaction.LeaderStoppedSince = nil
			state.Interaction.StopPosition = nil
			state.Interaction.PendingUntil = 0
			state.Interaction.StopEventCreated = false
		end

		local function flatDistance(a, b)
			local delta = a - b
			return Vector3.new(delta.X, 0, delta.Z).Magnitude
		end

		local function pushTrailPoint(position, now)
			local trail = state.Trail
			local last = trail[#trail]
			if last then
				local moved = (position - last.Position).Magnitude
				local elapsed = now - last.Time
				if moved > 120 then
					clearTrail()
					trail = state.Trail
					last = nil
				elseif moved < 1.25 or elapsed < 0.12 then
					return
				end
			end
			table.insert(trail, { Position = position, Time = now })
			state.LastSampleAt = now
			while #trail > 160 or (#trail > 2 and now - trail[1].Time > 45) do
				table.remove(trail, 1)
				state.Cursor = math.max(1, state.Cursor - 1)
				state.VisualNeedsRebuild = true
			end
		end

		local function seedTrail(root, leaderRoot, spacing, now)
			local outward = root.Position - leaderRoot.Position
			outward = Vector3.new(outward.X, 0, outward.Z)
			if outward.Magnitude < 0.35 then
				local behind = -leaderRoot.CFrame.LookVector
				outward = Vector3.new(behind.X, 0, behind.Z)
			end
			if outward.Magnitude < 0.1 then outward = Vector3.new(0, 0, -1) end
			local slot = leaderRoot.Position + outward.Unit * spacing
			table.insert(state.Trail, { Position = slot, Time = now, Synthetic = true })
			table.insert(state.Trail, { Position = leaderRoot.Position, Time = now })
			state.LastSampleAt = now
		end

		-- Return the point at a given path distance behind the leader and the
		-- last trail sample that the follower may walk toward before that point.
		local function pointBehindLeader(distance)
			local trail = state.Trail
			local remaining = distance
			for index = #trail, 2, -1 do
				local newer = trail[index].Position
				local older = trail[index - 1].Position
				local segment = (newer - older).Magnitude
				if segment >= remaining and segment > 0.01 then
					return newer:Lerp(older, remaining / segment), index - 1
				end
				remaining -= segment
			end
			return nil, nil
		end

		local function isNearFollowTrail(candidateRoot, maxDistance)
			local trail = state.Trail
			local routeDistance = 0
			for index = #trail, 2, -1 do
				local newer = trail[index]
				local older = trail[index - 1]
				if not newer.Synthetic and not older.Synthetic then
					local direction = older.Position - newer.Position
					direction = Vector3.new(direction.X, 0, direction.Z)
					local length = direction.Magnitude
					if length > 0.1 then
						local available = maxDistance - routeDistance
						if available <= 0 then break end
						local relative = candidateRoot.Position - newer.Position
						relative = Vector3.new(relative.X, 0, relative.Z)
						local progress = math.clamp(relative:Dot(direction) / (length * length), 0, 1)
						progress = math.min(progress, available / length)
						local nearestPoint = newer.Position + direction * progress
						if flatDistance(candidateRoot.Position, nearestPoint) <= FOLLOWER_TRAIL_RADIUS then
							return true
						end
						routeDistance += length
					end
				end
				if routeDistance >= maxDistance then break end
			end
			return false
		end

		local function getFormationSpacing(followedPlayer, snapshots, baseSpacing, leaderRoot)
			local candidates = { Players.LocalPlayer }
			local routeSpan = baseSpacing + FOLLOWER_GAP * 14
			local leaderClusterRadius = math.clamp(baseSpacing + 4, 12, 20)
			for _, snapshot in ipairs(snapshots or {}) do
				local player = snapshot.Player
				local otherRoot = snapshot.Root
				if player ~= Players.LocalPlayer and player ~= followedPlayer
					and otherRoot and otherRoot.Parent
					and (flatDistance(otherRoot.Position, leaderRoot.Position) <= leaderClusterRadius
						or isNearFollowTrail(otherRoot, routeSpan)) then
					table.insert(candidates, player)
				end
			end
			table.sort(candidates, function(a, b)
				return a.UserId < b.UserId
			end)

			for rank, player in ipairs(candidates) do
				if player == Players.LocalPlayer then
					return baseSpacing + (rank - 1) * FOLLOWER_GAP
				end
			end
			return baseSpacing
		end

		local function trailGoal(root, leaderRoot, spacing)
			local trail = state.Trail
			local endpoint, endIndex = pointBehindLeader(spacing)
			if not endpoint then
				if #trail > 1 then return trail[1].Position end
				local look = leaderRoot.CFrame.LookVector
				local backward = Vector3.new(-look.X, 0, -look.Z)
				if backward.Magnitude < 0.1 then backward = Vector3.new(0, 0, -1) end
				return leaderRoot.Position + backward.Unit * spacing
			end

			state.Cursor = math.clamp(state.Cursor, 1, math.max(1, endIndex))
			while state.Cursor <= endIndex and flatDistance(root.Position, trail[state.Cursor].Position) <= 2.6 do
				state.Cursor += 1
			end
			if state.Cursor > endIndex then return endpoint end

			-- Keep a long lead on straight segments, but cap it at an upcoming bend.
			-- Otherwise MoveTo cuts across curves and can strand the follower outside
			-- the route where the trail cursor never advances.
			local lookAhead = math.clamp(spacing * 1.25, 8, 14)
			local turnTotal = 0
			local distanceToVertex = flatDistance(root.Position, trail[state.Cursor].Position)
			for index = state.Cursor, endIndex - 1 do
				if index > state.Cursor then
					distanceToVertex += flatDistance(trail[index - 1].Position, trail[index].Position)
				end
				if distanceToVertex > lookAhead + 2.2 then break end

				local before = trail[index - 1]
				local vertex = trail[index]
				local after = trail[index + 1]
				if before and not before.Synthetic and not vertex.Synthetic and not after.Synthetic then
					local incoming = vertex.Position - before.Position
					local outgoing = after.Position - vertex.Position
					incoming = Vector3.new(incoming.X, 0, incoming.Z)
					outgoing = Vector3.new(outgoing.X, 0, outgoing.Z)
					if incoming.Magnitude > 0.1 and outgoing.Magnitude > 0.1 then
						local dot = math.clamp(incoming.Unit:Dot(outgoing.Unit), -1, 1)
						turnTotal += math.acos(dot)
						if dot < 0.72 or turnTotal >= math.rad(40) then
							return vertex.Position
						end
					end
				end
			end

			local remaining = lookAhead
			local from = root.Position
			for index = state.Cursor, endIndex do
				local point = trail[index].Position
				local segmentLength = flatDistance(from, point)
				if segmentLength >= remaining and segmentLength > 0.01 then
					return from:Lerp(point, remaining / segmentLength)
				end
				remaining -= segmentLength
				from = point
			end
			local finalLength = flatDistance(from, endpoint)
			if finalLength >= remaining and finalLength > 0.01 then
				return from:Lerp(endpoint, remaining / finalLength)
			end
			return endpoint
		end

		local function findCrowdingPlayer(root, goal, followedPlayer, snapshots)
			local nearest, nearestDistance, avoidFromGoal = nil, math.huge, false
			for _, snapshot in ipairs(snapshots or {}) do
				local player = snapshot.Player
				local otherRoot = snapshot.Root
				-- Deterministic right-of-way prevents cooperative followers from
				-- sidestepping each other in opposite directions at the same time.
				if player ~= Players.LocalPlayer and player ~= followedPlayer
					and player.UserId < Players.LocalPlayer.UserId and otherRoot.Parent then
					local rootDistance = flatDistance(root.Position, otherRoot.Position)
					local goalDistance = flatDistance(goal, otherRoot.Position)
					local distance = math.min(rootDistance, goalDistance)
					if distance < nearestDistance then
						nearest, nearestDistance = player, distance
						avoidFromGoal = goalDistance <= rootDistance
					end
				end
			end
			return nearest, nearestDistance, avoidFromGoal
		end

		local function updateAvoidance(root, goal, followedPlayer, snapshots)
			if state.AvoidUserId then
				local player = Players:GetPlayerByUserId(tonumber(state.AvoidUserId))
				local character = player and player.Character
				local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
				if not otherRoot then
					state.AvoidUserId, state.AvoidOffset = nil, nil
				else
					local distance = math.min(
						flatDistance(root.Position, otherRoot.Position),
						flatDistance(goal, otherRoot.Position)
					)
					if distance >= 6.5 then state.AvoidUserId, state.AvoidOffset = nil, nil end
				end
			end

			if not state.AvoidUserId then
				local player, distance, useGoal = findCrowdingPlayer(root, goal, followedPlayer, snapshots)
				if player and distance < 3.75 then
					local character = player.Character
					local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local away = (useGoal and goal or root.Position) - otherRoot.Position
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
						state.AvoidOffset = away.Unit * 4
						state.AvoidUserId = tostring(player.UserId)
					end
				end
			end
			return goal + (state.AvoidOffset or Vector3.zero)
		end

		local function updateRecovery(root, leaderRoot, goal, now, spacing)
			if state.RecoveryGoal and now <= state.RecoveryUntil
				and flatDistance(root.Position, state.RecoveryGoal) > 2.2 then
				return state.RecoveryGoal
			end
			state.RecoveryGoal = nil
			if now - state.LastProgressAt < 1.35 then return goal end

			local moved = state.ProgressPosition and (root.Position - state.ProgressPosition).Magnitude or math.huge
			local stuck = moved < 0.55 and flatDistance(root.Position, goal) > 3
			state.ProgressPosition = root.Position
			state.LastProgressAt = now
			if not stuck then
				state.RecoveryAttempts = 0
				return goal
			end

			state.RecoveryAttempts += 1
			if state.RecoveryAttempts <= 2 then
				local forward = goal - root.Position
				forward = Vector3.new(forward.X, 0, forward.Z)
				if forward.Magnitude < 0.1 then
					forward = leaderRoot.Position - root.Position
					forward = Vector3.new(forward.X, 0, forward.Z)
				end
				if forward.Magnitude < 0.1 then forward = Vector3.new(0, 0, -1) end
				forward = forward.Unit
				local side = Vector3.new(-forward.Z, 0, forward.X) * (state.RecoveryAttempts == 1 and 1 or -1)
				state.RecoveryGoal = root.Position + side * 4 + forward * 2
				state.RecoveryGoal = Vector3.new(state.RecoveryGoal.X, root.Position.Y, state.RecoveryGoal.Z)
				state.RecoveryUntil = now + 1.5
				return state.RecoveryGoal
			end

			-- After local sidesteps fail, advance only one sample. Skipping several
			-- samples can jump across a sharp bend; discard the stale detour and retry.
			state.Cursor = math.min(state.Cursor + 1, #state.Trail)
			resetNavigation()
			state.RecoveryAttempts = 0
			return trailGoal(root, leaderRoot, math.max(3, spacing or configuration.FollowDistance or 8))
		end

		local function updateFollowInteraction(root, followedCharacter, leaderRoot, spacing, now)
			local interaction = state.Interaction
			local leaderHumanoid = followedCharacter:FindFirstChildOfClass("Humanoid")
			local moveDirection = leaderHumanoid and leaderHumanoid.MoveDirection.Magnitude or 0
			local velocity = leaderRoot.AssemblyLinearVelocity
			local flatSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			local leaderMoving = moveDirection > 0.08 or flatSpeed > 1.5

			if leaderMoving then
				interaction.LeaderStoppedSince = nil
				if not interaction.LeaderMovingSince then
					interaction.LeaderMovingSince = now
				end
				if now - interaction.LeaderMovingSince >= LEADER_MOVE_CONFIRM_TIME then
					interaction.LeaderMoved = true
					if interaction.PendingUntil <= 0 then
						interaction.StopEventCreated = false
						interaction.StopPosition = nil
					end
				end
			else
				interaction.LeaderMovingSince = nil
				if not interaction.LeaderStoppedSince then
					interaction.LeaderStoppedSince = now
					if interaction.PendingUntil <= 0 then
						interaction.StopPosition = leaderRoot.Position
					end
				end
				if interaction.LeaderMoved
					and now - interaction.LeaderStoppedSince >= LEADER_STOP_CONFIRM_TIME
					and not interaction.StopEventCreated then
					interaction.PendingUntil = now + INTERACTION_PENDING_TIME
					interaction.StopEventCreated = true
					interaction.StopPosition = leaderRoot.Position
				end
			end

			local stopPosition = interaction.StopPosition
			local nearLeaderStop = stopPosition
				and (root.Position - stopPosition).Magnitude <= math.clamp(spacing + 2, 8, 14)
			local pending = interaction.LeaderMoved
				and now <= interaction.PendingUntil
				and nearLeaderStop

			if pending
				and now - interaction.LastAttemptAt >= FOLLOW_INTERACTION_INTERVAL then
				-- AIC calls this BindableFunction action as well. One press per leader
				-- stop plus a cooldown prevents repeated door/portal activation.
				interaction.LastAttemptAt = now
				if dependencies.Interact then
					local ok, invoked = pcall(dependencies.Interact)
					if ok and invoked == true then
						interaction.PendingUntil = 0
						interaction.StopPosition = nil
					end
				end
			end

			if now > interaction.PendingUntil then
				interaction.PendingUntil = 0
				interaction.StopPosition = nil
			end
		end

		local api = {}
		function api.SetTrailVisible(enabled)
			configuration.FollowTrailVisible = enabled == true
			state.TrailVisible = configuration.FollowTrailVisible
			if state.TrailVisible then
				state.VisualNeedsRebuild = true
				renderTrail()
			else
				clearVisualTrail()
			end
		end

		function api.Reset(humanoid, root)
			reset(humanoid, root)
			clearVisualTrail()
		end

		function api.Update(root, humanoid, followedPlayer, snapshots)
			local followedCharacter = followedPlayer and followedPlayer.Character
			local leaderRoot = followedCharacter and followedCharacter:FindFirstChild("HumanoidRootPart")
			if not root or not humanoid or not followedPlayer or not leaderRoot then
				reset(humanoid, root)
				return false, "unavailable"
			end

			local now = os.clock()
			local userId = tostring(followedPlayer.UserId)
			if state.TargetUserId ~= userId then
				reset(humanoid, root)
				state.TargetUserId = userId
			end
			if now - state.LastUpdateAt < 0.14 then return true, "throttled" end
			state.LastUpdateAt = now

			local baseSpacing = math.max(3, configuration.FollowDistance or 8)
			local spacing = getFormationSpacing(followedPlayer, snapshots, baseSpacing, leaderRoot)
			if #state.Trail == 0 then
				seedTrail(root, leaderRoot, spacing, now)
			else
				pushTrailPoint(leaderRoot.Position, now)
			end
			updateFollowInteraction(root, followedCharacter, leaderRoot, baseSpacing, now)
			renderTrail()
			local goal = trailGoal(root, leaderRoot, spacing)
			goal = updateRecovery(root, leaderRoot, goal, now, spacing)
			goal = updateAvoidance(root, goal, followedPlayer, snapshots)

			ClaimMovement("Follow", humanoid, root)
			local _, navigationState = CombatSystem.NavigateMoveTo(
				humanoid,
				root,
				goal,
				followedCharacter,
				state.Navigation,
				0.32,
				2.2
			)
			state.Navigation.NavigationMode = navigationState
			return true, navigationState
		end

		return api
	end,
}
