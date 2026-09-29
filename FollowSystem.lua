-- Direct player follow controller. Uses MoveTo through CombatSystem.Navigation.
local VERSION = "1.13.0"
print("[FollowSystem] Version " .. VERSION .. " (direct follow + stuck jump + detour retry)")

return {
	Initialize = function(configuration, dependencies)
		local Players = dependencies.Players
		local CombatSystem = configuration.CombatSystem
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
			FormationOrder = {},
			FormationSignature = nil,
			FormationCandidateSignature = nil,
			FormationCandidateSince = 0,
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
			Navigation = { Active = false, Goal = nil, LastMoveAt = 0, DetourSideBias = 1, DetourDistance = 8 },
		}

		local FOLLOW_INTERACTION_INTERVAL = 1.5
		local LEADER_STOP_CONFIRM_TIME = 0.65
		local LEADER_MOVE_CONFIRM_TIME = 0.35
		local INTERACTION_PENDING_TIME = 8
		local FOLLOWER_GAP = 5.5
		local FORMATION_RECHECK_DELAY = 2

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
		end

		local function resetNavigation()
			CombatSystem.ResetNavigationState(state.Navigation)
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
			state.FormationOrder = {}
			state.FormationSignature = nil
			state.FormationCandidateSignature = nil
			state.FormationCandidateSince = 0
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

		local function getFormationCandidates(root, followedPlayer, snapshots, baseSpacing, leaderRoot)
			local leaderClusterRadius = math.clamp(baseSpacing + 44, 36, 80)
			local localDistance = flatDistance(root.Position, leaderRoot.Position)
			local localInCluster = localDistance <= leaderClusterRadius
			local candidates = {
				{
					Player = Players.LocalPlayer,
					Distance = localInCluster and localDistance or (leaderClusterRadius + 1000000),
				},
			}
			for _, snapshot in ipairs(snapshots or {}) do
				local player = snapshot.Player
				local otherRoot = snapshot.Root
				if player ~= Players.LocalPlayer and player ~= followedPlayer and otherRoot and otherRoot.Parent then
					local distance = flatDistance(otherRoot.Position, leaderRoot.Position)
					if distance <= leaderClusterRadius then
						table.insert(candidates, {
							Player = player,
							Distance = distance,
						})
					end
				end
			end
			local memberIds = table.create(#candidates)
			for index, candidate in ipairs(candidates) do
				memberIds[index] = tostring(candidate.Player.UserId)
			end
			table.sort(memberIds)
			local signature = table.concat(memberIds, ",")
			if not localInCluster then signature ..= "|local-out" end
			return candidates, signature, localInCluster
		end

		local function updateFormationSpacing(root, followedPlayer, snapshots, baseSpacing, leaderRoot, now)
			local candidates, signature, localInCluster = getFormationCandidates(
				root,
				followedPlayer,
				snapshots,
				baseSpacing,
				leaderRoot
			)
			local function sortByDistance(a, b)
				-- Quantizing to two-stud bands makes nearly equal distances stable;
				-- UserId is only a deterministic tie-breaker.
				local aBand = math.floor(a.Distance / 2 + 0.5)
				local bBand = math.floor(b.Distance / 2 + 0.5)
				if aBand ~= bBand then return aBand < bBand end
				return a.Player.UserId < b.Player.UserId
			end

			local function spacingForLocalOrder()
				for rank, userId in ipairs(state.FormationOrder) do
					if userId == Players.LocalPlayer.UserId then
						return baseSpacing + (rank - 1) * FOLLOWER_GAP
					end
				end
				return baseSpacing
			end

			if not state.FormationSignature then
				table.sort(candidates, sortByDistance)
				state.FormationOrder = {}
				for _, candidate in ipairs(candidates) do
					table.insert(state.FormationOrder, candidate.Player.UserId)
				end
				state.FormationSignature = signature
				return spacingForLocalOrder()
			end

			if signature == state.FormationSignature then
				state.FormationCandidateSignature = nil
				state.FormationCandidateSince = 0
			elseif signature ~= state.FormationCandidateSignature then
				state.FormationCandidateSignature = signature
				state.FormationCandidateSince = now
			elseif now - state.FormationCandidateSince >= FORMATION_RECHECK_DELAY then
				-- Keep existing queue positions. Stable newcomers join the back in
				-- nearest-to-leader order; departed players are removed after the same
				-- delay so brief character/root streaming gaps do not reshuffle the line.
				local present = {}
				for _, candidate in ipairs(candidates) do
					present[candidate.Player.UserId] = candidate
				end
				local nextOrder = {}
				local localUserId = Players.LocalPlayer.UserId
				for _, userId in ipairs(state.FormationOrder) do
					if present[userId] and (userId ~= localUserId or localInCluster) then
						table.insert(nextOrder, userId)
						present[userId] = nil
					end
				end
				local newcomers = {}
				for _, candidate in pairs(present) do
					table.insert(newcomers, candidate)
				end
				table.sort(newcomers, sortByDistance)
				for _, candidate in ipairs(newcomers) do
					table.insert(nextOrder, candidate.Player.UserId)
				end
				state.FormationOrder = nextOrder
				state.FormationSignature = signature
				state.FormationCandidateSignature = nil
				state.FormationCandidateSince = 0
			end
			return spacingForLocalOrder()
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

		local function findCrowdingPlayer(root, goal, followedPlayer, snapshots)
			local nearest, nearestDistance = nil, math.huge
			for _, snapshot in ipairs(snapshots or {}) do
				local player = snapshot.Player
				local otherRoot = snapshot.Root
				if player ~= Players.LocalPlayer and player ~= followedPlayer and otherRoot and otherRoot.Parent then
					local rootDistance = flatDistance(root.Position, otherRoot.Position)
					local goalDistance = flatDistance(goal, otherRoot.Position)
					local distance = math.min(rootDistance, goalDistance)
					if distance < nearestDistance
						or (math.abs(distance - nearestDistance) < 0.05
							and nearest and player.UserId < nearest.UserId) then
						nearest, nearestDistance = player, distance
					end
				end
			end
			return nearest, nearestDistance
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
				local player, distance = findCrowdingPlayer(root, goal, followedPlayer, snapshots)
				if player and distance < 4.5 then
					-- Both participants sidestep, on opposite sides selected from the
					-- same UserId pair. The older one no longer gets to block traffic.
					local forward = goal - root.Position
					forward = Vector3.new(forward.X, 0, forward.Z)
					if forward.Magnitude < 0.1 then
						forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
					end
					if forward.Magnitude < 0.1 then forward = Vector3.new(0, 0, -1) end
					forward = forward.Unit
					local side = Vector3.new(-forward.Z, 0, forward.X)
					local sideSign = Players.LocalPlayer.UserId < player.UserId and 1 or -1
					state.AvoidOffset = side * (5 * sideSign) + forward * 3
					state.AvoidUserId = tostring(player.UserId)
				end
			end
			return goal + (state.AvoidOffset or Vector3.zero)
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

			local moved = state.ProgressPosition and (root.Position - state.ProgressPosition).Magnitude or math.huge
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
			local spacing = updateFormationSpacing(
				root,
				followedPlayer,
				snapshots,
				baseSpacing,
				leaderRoot,
				now
			)
			updateFollowInteraction(root, followedCharacter, leaderRoot, baseSpacing, now)
			local goal = getDirectFollowGoal(leaderRoot, spacing, now)
			goal = updateRecovery(root, humanoid, goal, now)
			goal = updateAvoidance(root, goal, followedPlayer, snapshots)
			renderTargetLine(root, goal)

			ClaimMovement("Follow", humanoid, root)
			local _, navigationState = CombatSystem.NavigateMoveTo(
				humanoid,
				root,
				goal,
				followedCharacter,
				state.Navigation,
				0.32,
				2.2,
				false,
				true
			)
			state.Navigation.NavigationMode = navigationState
			return true, navigationState
		end

		return api
	end,
}
