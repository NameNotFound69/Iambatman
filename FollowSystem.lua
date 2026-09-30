-- Direct player follow controller with a Follow-specific MoveTo route search.
local VERSION = "1.16.0"
print("[FollowSystem] Version " .. VERSION .. " (stable live-goal detours + crowd avoidance)")

return {
	Initialize = function(configuration, dependencies)
		local Players = dependencies.Players
		local MobsFolder = dependencies.MobsFolder
		local ClaimMovement = dependencies.ClaimMovement
		local ReleaseMovement = dependencies.ReleaseMovement
		local targetLineFolderName = "IamrichFollowTargetLine_" .. tostring(Players.LocalPlayer.UserId)
		for _, oldName in ipairs({
			"IamrichFollowTrail_" .. tostring(Players.LocalPlayer.UserId),
			targetLineFolderName,
		}) do
			local oldFolder = workspace:FindFirstChild(oldName)
			if oldFolder then oldFolder:Destroy() end
		end
		local targetLineFolder = Instance.new("Folder")
		targetLineFolder.Name = targetLineFolderName
		targetLineFolder.Parent = workspace
		local state = {
			TargetUserId = nil,
			LastUpdateAt = 0,
			LastProgressAt = 0,
			ProgressPosition = nil,
			RecoveryAttempts = 0,
			RecoveryGoal = nil,
			RecoveryUntil = 0,
			LastJumpRecoveryAt = 0,
			FollowDirection = nil,
			LastHeadingAt = 0,
			AvoidUserId = nil,
			AvoidOffset = nil,
			AvoidClearSince = nil,
			FormationSlotIndex = nil,
			FormationPendingSlot = nil,
			FormationPendingSince = 0,
			TargetLineVisible = configuration.FollowTargetVisible == true,
			TargetLine = nil,
			Interaction = {
				LeaderMoved = false,
				LeaderMovingSince = nil,
				LeaderStoppedSince = nil,
				StopPosition = nil,
				PendingUntil = 0,
				StopEventCreated = false,
				LastAttemptAt = 0,
			},
			Navigation = {
				Active = false,
				Goal = nil,
				LastMoveAt = 0,
				DetourGoal = nil,
				DetourFor = nil,
				DetourSearchAt = 0,
				DetourClearSince = nil,
				ForceDetourUntil = 0,
				DetourSideBias = 1,
				DetourDistance = 8,
				GoalTolerance = 10,
			},
		}

		local FOLLOW_INTERACTION_INTERVAL = 1.5
		local FOLLOW_MOVE_INTERVAL = 0.38
		local FOLLOW_SEARCH_INTERVAL = 0.45
		local FOLLOW_DETOUR_REACHED_RADIUS = 3
		local FOLLOW_DIRECT_CLEAR_CONFIRMATION = 0.6
		local LEADER_STOP_CONFIRM_TIME = 0.65
		local LEADER_MOVE_CONFIRM_TIME = 0.35
		local INTERACTION_PENDING_TIME = 8

		local function clearTargetLine()
			if state.TargetLine then
				state.TargetLine:Destroy()
				state.TargetLine = nil
			end
		end

		local function renderTargetLine(root, goal)
			if state.TargetLineVisible ~= true or not root or not goal then
				clearTargetLine()
				return
			end
			local fromPosition = root.Position - Vector3.new(0, 2.4, 0)
			local toPosition = goal - Vector3.new(0, 2.4, 0)
			local delta = toPosition - fromPosition
			local length = delta.Magnitude
			if length < 0.1 then
				clearTargetLine()
				return
			end
			local line = state.TargetLine
			if not line or not line.Parent then
				line = Instance.new("Part")
				line.Name = "FollowTargetLine"
				line.Anchored = true
				line.CanCollide = false
				line.CanTouch = false
				line.CanQuery = false
				line.CastShadow = false
				line.Material = Enum.Material.Neon
				line.Color = Color3.fromRGB(70, 190, 255)
				line.Transparency = 0.18
				line.Parent = targetLineFolder
				state.TargetLine = line
			end
			line.Size = Vector3.new(0.16, 0.16, length)
			line.CFrame = CFrame.lookAt((fromPosition + toPosition) * 0.5, toPosition)
		end

		local function clearFollowState()
			state.LastProgressAt = 0
			state.ProgressPosition = nil
			state.RecoveryAttempts = 0
			state.RecoveryGoal = nil
			state.RecoveryUntil = 0
			state.LastJumpRecoveryAt = 0
			state.FollowDirection = nil
			state.LastHeadingAt = 0
			state.AvoidUserId = nil
			state.AvoidOffset = nil
			state.AvoidClearSince = nil
			state.FormationSlotIndex = nil
			state.FormationPendingSlot = nil
			state.FormationPendingSince = 0
		end

		local function resetNavigation()
			local navigation = state.Navigation
			navigation.Active = false
			navigation.Goal = nil
			navigation.LastMoveAt = 0
			navigation.DetourGoal = nil
			navigation.DetourFor = nil
			navigation.DetourSearchAt = 0
			navigation.DetourClearSince = nil
			navigation.ForceDetourUntil = 0
			navigation.NavigationMode = nil
		end

		local function reset(humanoid, root)
			ReleaseMovement("Follow", humanoid, root)
			resetNavigation()
			clearFollowState()
			clearTargetLine()
			state.TargetUserId = nil
			state.LastUpdateAt = 0
			state.Navigation.DetourSideBias = 1
			state.Navigation.DetourDistance = 8
			state.Navigation.GoalTolerance = 10
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

		local function makeNavigationRaycastParams(root)
			local excluded = { root.Parent }
			if MobsFolder and MobsFolder.Parent then
				table.insert(excluded, MobsFolder)
			end
			for _, player in ipairs(Players:GetPlayers()) do
				local character = player.Character
				if character and character ~= root.Parent then
					table.insert(excluded, character)
				end
			end

			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = excluded
			params.RespectCanCollide = true
			return params
		end

		local function getWalkableGround(point, params)
			local hit = workspace:Raycast(
				Vector3.new(point.X, point.Y + 60, point.Z),
				Vector3.new(0, -250, 0),
				params
			)
			if not hit or hit.Material == Enum.Material.Water or hit.Normal.Y < 0.5 then
				return nil
			end
			return hit
		end

		local function chooseFollowDetour(root, goal, params)
			local toward = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			if toward.Magnitude < 0.1 then return nil end
			toward = toward.Unit

			local rootGround = getWalkableGround(root.Position, params)
			local rootHeight = rootGround
				and math.max(root.Position.Y - rootGround.Position.Y, root.Size.Y * 0.5)
				or root.Size.Y
			local preferredDistance = math.clamp(state.Navigation.DetourDistance or 8, 8, 20)
			local preferredSide = state.Navigation.DetourSideBias or 1
			local bestVisible, bestVisibleScore = nil, math.huge
			local bestFallback, bestFallbackScore = nil, math.huge
			local radii = {}
			for _, requested in ipairs({ preferredDistance, preferredDistance + 4, preferredDistance + 8, 20 }) do
				local radius = math.min(requested, 20)
				if #radii == 0 or radii[#radii] ~= radius then
					table.insert(radii, radius)
				end
			end

			for _, radius in ipairs(radii) do
				for _, degrees in ipairs({ 40, -40, 70, -70, 105, -105, 140, -140, 180 }) do
					local angle = math.rad(degrees)
					local direction = Vector3.new(
						toward.X * math.cos(angle) - toward.Z * math.sin(angle),
						0,
						toward.X * math.sin(angle) + toward.Z * math.cos(angle)
					)
					local offset = direction * radius
					local candidateXZ = root.Position + offset
					local legHit = workspace:Raycast(
						root.Position + Vector3.new(0, 1.5, 0),
						offset,
						params
					)
					if not legHit then
						local ground = getWalkableGround(candidateXZ, params)
						if ground and (not rootGround or math.abs(ground.Position.Y - rootGround.Position.Y) <= 12) then
							local candidate = Vector3.new(
								candidateXZ.X,
							ground.Position.Y + rootHeight,
							candidateXZ.Z
							)
							local towardGoal = Vector3.new(goal.X - candidate.X, 0, goal.Z - candidate.Z)
							local goalHit = towardGoal.Magnitude > 0.1
								and workspace:Raycast(candidate + Vector3.new(0, 1.5, 0), towardGoal, params)
							local side = degrees > 0 and 1 or -1
							local sidePenalty = degrees ~= 180 and side ~= preferredSide and 3 or 0
							local score = towardGoal.Magnitude + math.abs(degrees) * 0.035 + sidePenalty
								+ (radius - preferredDistance) * 0.2
							if not goalHit and score < bestVisibleScore then
								bestVisible, bestVisibleScore = candidate, score
							end
							if score < bestFallbackScore then
								bestFallback, bestFallbackScore = candidate, score
							end
						end
					end
				end
				if bestVisible then return bestVisible end
			end
			return bestFallback
		end

		local function navigateFollow(humanoid, root, goal, now)
			local navigation = state.Navigation
			local params = makeNavigationRaycastParams(root)
			local direction = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			local obstruction = direction.Magnitude > 0.1
				and workspace:Raycast(root.Position + Vector3.new(0, 1.5, 0), direction, params)
			local destination = goal
			local mode = "direct"

			local forceDetour = now < navigation.ForceDetourUntil
			if obstruction or forceDetour then
				navigation.DetourClearSince = nil
				local sameGoal = navigation.DetourFor
					and flatDistance(navigation.DetourFor, goal) <= navigation.GoalTolerance
				if not sameGoal then
					navigation.DetourGoal = nil
					navigation.DetourFor = nil
					navigation.DetourSearchAt = 0
				end
				local keepDetour = sameGoal and navigation.DetourGoal
					and flatDistance(root.Position, navigation.DetourGoal) > FOLLOW_DETOUR_REACHED_RADIUS
				if keepDetour then
					destination = navigation.DetourGoal
				else
					if sameGoal and navigation.DetourGoal then
						navigation.DetourGoal = nil
						navigation.DetourFor = nil
						navigation.DetourSearchAt = 0
					end
					if now - navigation.DetourSearchAt >= FOLLOW_SEARCH_INTERVAL then
						navigation.DetourGoal = chooseFollowDetour(root, goal, params)
						navigation.DetourFor = goal
						navigation.DetourSearchAt = now
					end
					destination = navigation.DetourGoal or goal
				end
				mode = navigation.DetourGoal and "detouring" or "direct"
			else
				local sameGoal = navigation.DetourFor
					and flatDistance(navigation.DetourFor, goal) <= navigation.GoalTolerance
				local detourStillAhead = sameGoal and navigation.DetourGoal
					and flatDistance(root.Position, navigation.DetourGoal) > FOLLOW_DETOUR_REACHED_RADIUS
				if detourStillAhead then
					navigation.DetourClearSince = navigation.DetourClearSince or now
					if now - navigation.DetourClearSince < FOLLOW_DIRECT_CLEAR_CONFIRMATION then
						destination = navigation.DetourGoal
						mode = "detouring"
					else
						navigation.DetourGoal = nil
						navigation.DetourFor = nil
						navigation.DetourSearchAt = 0
						navigation.DetourClearSince = nil
					end
				else
					navigation.DetourGoal = nil
					navigation.DetourFor = nil
					navigation.DetourSearchAt = 0
					navigation.DetourClearSince = nil
				end
			end

			if not navigation.Active or now - navigation.LastMoveAt >= FOLLOW_MOVE_INTERVAL then
				humanoid:MoveTo(destination)
				navigation.Active = true
				navigation.Goal = destination
				navigation.LastMoveAt = now
			end
			navigation.NavigationMode = mode
			return mode
		end

		local function getDirectFollowGoal(leaderRoot, spacing, now)
			local velocity = leaderRoot.AssemblyLinearVelocity
			local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
			local desiredDirection = nil
			if flatVelocity.Magnitude > 2 then
				desiredDirection = flatVelocity.Unit
			elseif state.FollowDirection then
				desiredDirection = state.FollowDirection
			else
				local look = leaderRoot.CFrame.LookVector
				desiredDirection = Vector3.new(look.X, 0, look.Z)
			end
			if desiredDirection.Magnitude < 0.1 then desiredDirection = Vector3.new(0, 0, -1) end
			desiredDirection = desiredDirection.Unit

			if state.FollowDirection then
				local elapsed = state.LastHeadingAt > 0 and (now - state.LastHeadingAt) or 0.14
				local alpha = math.clamp(elapsed * 3.5, 0.12, 0.5)
				local blended = state.FollowDirection:Lerp(desiredDirection, alpha)
				state.FollowDirection = blended.Magnitude > 0.15 and blended.Unit or desiredDirection
			else
				state.FollowDirection = desiredDirection
			end
			state.LastHeadingAt = now
			return leaderRoot.Position - state.FollowDirection * spacing
		end

		local function getFormationOffset(root, leaderRoot, spacing, followedPlayer, snapshots, now)
			local crowdRadius = math.max(24, spacing + 16)
			if flatDistance(root.Position, leaderRoot.Position) > crowdRadius then
				state.FormationSlotIndex = nil
				state.FormationPendingSlot = nil
				state.FormationPendingSince = 0
				return Vector3.new(0, 0, 0)
			end

			local nearby = {{
				UserId = Players.LocalPlayer.UserId,
				DistanceBand = math.floor(flatDistance(root.Position, leaderRoot.Position) * 2 + 0.5),
			}}
			for _, snapshot in ipairs(snapshots or {}) do
				local player, otherRoot = snapshot.Player, snapshot.Root
				if player ~= Players.LocalPlayer and player ~= followedPlayer and otherRoot and otherRoot.Parent then
					local distance = flatDistance(otherRoot.Position, leaderRoot.Position)
					if distance <= crowdRadius then
						table.insert(nearby, {
							UserId = player.UserId,
							DistanceBand = math.floor(distance * 2 + 0.5),
						})
					end
				end
			end
			table.sort(nearby, function(a, b)
				if a.DistanceBand ~= b.DistanceBand then
					return a.DistanceBand < b.DistanceBand
				end
				return a.UserId < b.UserId
			end)

			local desiredSlot = 1
			for index, member in ipairs(nearby) do
				if member.UserId == Players.LocalPlayer.UserId then
					desiredSlot = index
					break
				end
			end

			if not state.FormationSlotIndex then
				state.FormationSlotIndex = desiredSlot
			elseif state.FormationSlotIndex ~= desiredSlot then
				if state.FormationPendingSlot ~= desiredSlot then
					state.FormationPendingSlot = desiredSlot
					state.FormationPendingSince = now
				elseif now - state.FormationPendingSince >= 0.7 then
					state.FormationSlotIndex = desiredSlot
					state.FormationPendingSlot = nil
					state.FormationPendingSince = 0
				end
			else
				state.FormationPendingSlot = nil
				state.FormationPendingSince = 0
			end

			local slot = state.FormationSlotIndex - 1
			if slot <= 0 then return Vector3.new(0, 0, 0) end
			local row = math.ceil(slot / 2)
			local side = slot % 2 == 1 and 1 or -1
			local direction = state.FollowDirection or Vector3.new(
				leaderRoot.CFrame.LookVector.X, 0, leaderRoot.CFrame.LookVector.Z
			)
			if direction.Magnitude < 0.1 then direction = Vector3.new(0, 0, -1) end
			direction = direction.Unit
			local right = Vector3.new(-direction.Z, 0, direction.X)
			return right * (side * row * 3.5) - direction * (row * 1.5)
		end

		local function findBlockingPlayer(root, goal, followedPlayer, snapshots, preferredUserId)
			local route = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			local routeLength = route.Magnitude
			local direction = routeLength >= 0.1 and route.Unit
				or Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			if direction.Magnitude < 0.1 then direction = Vector3.new(0, 0, -1) end
			direction = direction.Unit
			local nearest, nearestScore, preferred = nil, math.huge, nil
			for _, snapshot in ipairs(snapshots or {}) do
				local player = snapshot.Player
				local otherRoot = snapshot.Root
				if player ~= Players.LocalPlayer and player ~= followedPlayer and otherRoot and otherRoot.Parent then
					local velocity = otherRoot.AssemblyLinearVelocity
					local predictedPosition = otherRoot.Position + Vector3.new(velocity.X, 0, velocity.Z) * 0.35
					local relative = predictedPosition - root.Position
					local along = Vector3.new(relative.X, 0, relative.Z):Dot(direction)
					local clearance = math.clamp(root.Size.X * 0.5 + otherRoot.Size.X * 0.5 + 1.75, 3.5, 6.5)
					local blocksRoute = routeLength >= 1.5 and along > 0.5 and along <= routeLength + 2
						and flatDistance(predictedPosition, root.Position + direction * along) <= clearance
					local blocksDestination = flatDistance(predictedPosition, goal) <= clearance
					local score = blocksDestination and 0 or (blocksRoute and along or math.huge)
					if score < math.huge and tostring(player.UserId) == preferredUserId then
						preferred = player
					elseif score < nearestScore then
						nearest, nearestScore = player, score
					end
				end
			end
			return preferred or nearest, direction
		end

		local function updateAvoidance(root, goal, followedPlayer, snapshots, now)
			local blockingPlayer, forward = findBlockingPlayer(
				root,
				goal,
				followedPlayer,
				snapshots,
				state.AvoidUserId
			)
			if state.AvoidUserId then
				if blockingPlayer and tostring(blockingPlayer.UserId) == state.AvoidUserId then
					state.AvoidClearSince = nil
					return goal + state.AvoidOffset
				end

				state.AvoidClearSince = state.AvoidClearSince or now
				local fade = math.clamp((now - state.AvoidClearSince) / 0.5, 0, 1)
				if fade < 1 then
					return goal + state.AvoidOffset * (1 - fade)
				end
				state.AvoidUserId, state.AvoidOffset, state.AvoidClearSince = nil, nil, nil
			end

			if blockingPlayer then
				-- Sidestep only for someone inside the actual route corridor. Nearby
				-- players off to the side no longer pull the follower away from its leader.
				local side = Vector3.new(-forward.Z, 0, forward.X)
				local sideSign = Players.LocalPlayer.UserId < blockingPlayer.UserId and 1 or -1
				state.AvoidOffset = side * (3.5 * sideSign) + forward * 1.25
				state.AvoidUserId = tostring(blockingPlayer.UserId)
				state.AvoidClearSince = nil
				return goal + state.AvoidOffset
			end
			return goal
		end

		local function updateRecovery(root, humanoid, goal, now)
			if state.RecoveryGoal then
				if now <= state.RecoveryUntil
					and flatDistance(root.Position, state.RecoveryGoal) > 2.2 then
					return state.RecoveryGoal
				end
				state.RecoveryGoal = nil
				-- Recheck as soon as a recovery action ends instead of waiting for the
				-- ordinary progress sampling interval to elapse again.
				state.LastProgressAt = 0
			end
			if now - state.LastProgressAt < 1.35 then return goal end

			local moved = state.ProgressPosition and flatDistance(root.Position, state.ProgressPosition) or math.huge
			local stuck = moved < 0.55 and flatDistance(root.Position, goal) > 3
			state.ProgressPosition = root.Position
			state.LastProgressAt = now
			if not stuck then
				state.RecoveryAttempts = 0
				return goal
			end

			state.RecoveryAttempts += 1
			if state.RecoveryAttempts == 1 then
				-- A grounded jump can clear short barriers or get the character out of
				-- a player pile. Apply a cooldown so a persistent wall does not cause hopping.
				if humanoid.FloorMaterial ~= Enum.Material.Air
					and (state.LastJumpRecoveryAt == 0 or now - state.LastJumpRecoveryAt >= 4.5) then
					humanoid.Jump = true
					state.LastJumpRecoveryAt = now
				end
				state.RecoveryGoal = goal
				state.RecoveryUntil = now + 0.85
				resetNavigation()
				return goal
			elseif state.RecoveryAttempts == 2 then
				local forward = goal - root.Position
				forward = Vector3.new(forward.X, 0, forward.Z)
				if forward.Magnitude < 0.1 then
					forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
				end
				if forward.Magnitude < 0.1 then forward = Vector3.new(0, 0, -1) end
				forward = forward.Unit
				local side = Vector3.new(-forward.Z, 0, forward.X) * -1
				state.RecoveryGoal = root.Position + side * 4 + forward * 2
				state.RecoveryGoal = Vector3.new(state.RecoveryGoal.X, root.Position.Y, state.RecoveryGoal.Z)
				state.RecoveryUntil = now + 1.1
				return state.RecoveryGoal
			end

			-- Force MoveTo to choose a fresh detour on the opposite side of the
			-- obstruction, then keep following the player's live position.
			state.Navigation.DetourSideBias = -(state.Navigation.DetourSideBias or 1)
			state.Navigation.DetourDistance = math.min((state.Navigation.DetourDistance or 8) + 4, 20)
			resetNavigation()
			state.Navigation.ForceDetourUntil = now + 1.5
			state.RecoveryAttempts = 0
			state.RecoveryGoal = goal
			state.RecoveryUntil = now + 1.2
			return goal
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
		function api.SetTargetLineVisible(enabled)
			configuration.FollowTargetVisible = enabled == true
			state.TargetLineVisible = configuration.FollowTargetVisible
			if not state.TargetLineVisible then clearTargetLine() end
		end

		function api.Reset(humanoid, root)
			reset(humanoid, root)
			clearTargetLine()
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
			updateFollowInteraction(root, followedCharacter, leaderRoot, baseSpacing, now)
			local leaderVelocity = leaderRoot.AssemblyLinearVelocity
			local leaderFlatSpeed = Vector3.new(leaderVelocity.X, 0, leaderVelocity.Z).Magnitude
			state.Navigation.GoalTolerance = math.clamp(6 + leaderFlatSpeed * 0.22, 8, 16)
			local goal = getDirectFollowGoal(leaderRoot, baseSpacing, now)
			goal += getFormationOffset(root, leaderRoot, baseSpacing, followedPlayer, snapshots, now)
			goal = updateRecovery(root, humanoid, goal, now)
			goal = updateAvoidance(root, goal, followedPlayer, snapshots, now)
			renderTargetLine(root, goal)

			ClaimMovement("Follow", humanoid, root)
			if flatDistance(root.Position, goal) <= 2.2 then
				if state.Navigation.Active then humanoid:MoveTo(root.Position) end
				state.Navigation.Active = false
				state.Navigation.Goal = nil
				state.Navigation.DetourGoal = nil
				state.Navigation.DetourFor = nil
				state.Navigation.DetourClearSince = nil
				state.Navigation.ForceDetourUntil = 0
				return true, "arrived"
			end
			return true, navigateFollow(humanoid, root, goal, now)
		end

		return api
	end,
}
