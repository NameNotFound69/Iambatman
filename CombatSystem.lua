-- Direct-movement controller for selected-mob combat.
local VERSION = "2.2.3"
print("[CombatSystem] Version " .. VERSION .. " (MoveTo + jump recovery)")
return {
	Initialize = function(configuration, dependencies)
		local combat = configuration.CombatSystem
		local mobsFolder = dependencies.MobsFolder
		local function flatDistance(a, b)
			local offset = b - a
			return Vector3.new(offset.X, 0, offset.Z).Magnitude
		end
		local function raycastParams(root, target, includeMobs)
			local filter = { root.Parent }
			if mobsFolder and not includeMobs then table.insert(filter, mobsFolder) end
			if target then table.insert(filter, target) end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = filter
			params.RespectCanCollide = true
			return params
		end
		local function floorAt(root, point, target)
			local params = raycastParams(root, target)
			return workspace:Raycast(point + Vector3.new(0, 24, 0), Vector3.new(0, -160, 0), params)
		end

		function combat.ResetNavigationState(state)
			state.Active, state.Goal, state.LastMoveAt = false, nil, 0
			state.DetourGoal, state.DetourFor = nil, nil
			state.DetourSearchAt = nil
			state.PursuitOrbitAngle, state.PursuitOrbitAt = nil, nil
			state.NavigationMode = nil
			state.ProgressAt, state.ProgressGoal, state.ProgressDistance = nil, nil, nil
			state.StuckJumpUntil, state.LastStuckJumpAt = 0, 0
			state.LastJumpAt = 0
		end

		function combat.GroundAlignGoal(root, goal, target)
			if not root or not goal then return goal end
			local rootFloor = floorAt(root, root.Position, target)
			local goalFloor = floorAt(root, goal, target)
			if not rootFloor or not goalFloor then return goal end
			local rootHeight = math.max(root.Position.Y - rootFloor.Position.Y, root.Size.Y * 0.5)
			return Vector3.new(goal.X, goalFloor.Position.Y + rootHeight, goal.Z)
		end

		function combat.SelectApproachPoint(root, targetRoot, standoff, target, state, attackRange)
			if not root or not targetRoot then return root and root.Position or nil end
			local flat = Vector3.new(root.Position.X - targetRoot.Position.X, 0, root.Position.Z - targetRoot.Position.Z)
			local distance = flat.Magnitude
			local away = distance > 0.05 and flat.Unit or Vector3.new(-targetRoot.CFrame.LookVector.X, 0, -targetRoot.CFrame.LookVector.Z)
			if away.Magnitude < 0.05 then away = Vector3.new(1, 0, 0) else away = away.Unit end
			local range = math.max(3, tonumber(attackRange) or 7)
			local radius = math.clamp(tonumber(standoff) or 4, 2.5, math.max(2.5, range - 1))

			if distance <= range + 2 then
				local now = os.clock()
				local previous = state.PursuitOrbitAt or now
				local angle = state.PursuitOrbitAngle or math.atan2(away.Z, away.X)
				angle += math.clamp(now - previous, 0, 0.15) * 1.6
				state.PursuitOrbitAngle, state.PursuitOrbitAt = angle, now
				local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
				return targetRoot.Position + direction * radius
			end

			state.PursuitOrbitAngle, state.PursuitOrbitAt = nil, nil
			return targetRoot.Position + away * radius
		end

		local function chooseDetour(root, goal, target, state, includeMobs)
			local toward = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			if toward.Magnitude < 0.1 then return nil end
			toward = toward.Unit
			local params = raycastParams(root, target, includeMobs)
			local rootFloor = floorAt(root, root.Position, target)
			local rootHeight = rootFloor and math.max(root.Position.Y - rootFloor.Position.Y, root.Size.Y * 0.5) or root.Size.Y
			local best, bestScore = nil, math.huge
			local preferredDistance = math.clamp(state and tonumber(state.DetourDistance) or 8, 8, 20)
			local preferredSide = state and state.DetourSideBias or 0
			for _, extraDistance in ipairs({ 0, 4, 8, 12 }) do
				local radius = preferredDistance + extraDistance
				for _, degrees in ipairs({ 40, -40, 75, -75, 110, -110, 145, -145, 180 }) do
					local angle = math.rad(degrees)
					local direction = Vector3.new(
						toward.X * math.cos(angle) - toward.Z * math.sin(angle), 0,
						toward.X * math.sin(angle) + toward.Z * math.cos(angle)
					)
					local candidateXZ = root.Position + direction * radius
					local obstacle = workspace:Raycast(
						root.Position + Vector3.new(0, 1.5, 0),
						direction * radius,
						params
					)
					local floor = not obstacle and floorAt(root, candidateXZ, target) or nil
					if floor and (not rootFloor or math.abs(floor.Position.Y - rootFloor.Position.Y) <= 12) then
						local candidate = Vector3.new(candidateXZ.X, floor.Position.Y + rootHeight, candidateXZ.Z)
						local remaining = flatDistance(candidate, goal)
						local candidateSide = degrees > 0 and 1 or -1
						local sidePenalty = preferredSide ~= 0 and degrees ~= 180
							and candidateSide ~= preferredSide and 6 or 0
						local distancePenalty = (radius - preferredDistance) * 0.25
						local score = remaining + math.abs(degrees) * 0.035 + sidePenalty + distancePenalty
						if score < bestScore then best, bestScore = candidate, score end
					end
				end
				if best then return best end
			end
			return best
		end

		function combat.NavigateMoveTo(humanoid, root, goal, target, state, minInterval, stopRadius, checkVertical, includeMobs)
			if not humanoid or not root or not goal then return false, "unavailable" end
			local now = os.clock()
			local interval = minInterval or 0.2
			local offset = root.Position - goal
			local distance = checkVertical and offset.Magnitude or flatDistance(root.Position, goal)
			if distance <= (stopRadius or 1.8) then
				if state.Active then humanoid:MoveTo(root.Position) end
				state.Active, state.Goal, state.DetourGoal = false, nil, nil
				state.DetourFor, state.DetourSearchAt = nil, nil
				state.ProgressAt, state.ProgressGoal, state.ProgressDistance = nil, nil, nil
				state.StuckJumpUntil, state.LastStuckJumpAt = 0, 0
				state.LastJumpAt = 0
				return true, "arrived"
			end

			local flatGoalDistance = flatDistance(root.Position, goal)
			if not state.ProgressAt or not state.ProgressGoal
				or flatDistance(state.ProgressGoal, goal) > 2.5 then
				state.ProgressAt = now
				state.ProgressGoal = goal
				state.ProgressDistance = flatGoalDistance
			elseif now - state.ProgressAt >= 1 then
				local progress = (state.ProgressDistance or flatGoalDistance) - flatGoalDistance
				state.ProgressAt = now
				state.ProgressGoal = goal
				state.ProgressDistance = flatGoalDistance
				if progress < 0.45 and flatGoalDistance > (stopRadius or 1.8) + 2 then
					state.StuckJumpUntil = now + 1.6
				else
					state.StuckJumpUntil = 0
				end
			end

			local stuckJumping = now <= (state.StuckJumpUntil or 0)
				and humanoid.FloorMaterial ~= Enum.Material.Air
			if stuckJumping and now - (state.LastStuckJumpAt or 0) >= 0.25 then
				humanoid.Jump = true
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
				state.LastStuckJumpAt = now
			end

			local params = raycastParams(root, target, includeMobs)
			local direction = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			local obstruction = direction.Magnitude > 0.1
				and workspace:Raycast(root.Position + Vector3.new(0, 1.5, 0), direction, params)
			local destination = goal
			local mode = "direct"
			if stuckJumping then
				destination = goal
				mode = "jumping"
				state.DetourGoal, state.DetourFor = nil, nil
			elseif obstruction then
				local flat = direction.Magnitude > 0.1 and direction.Unit or Vector3.zero
				local probe = flat * math.min(4.5, direction.Magnitude)
				local feet = root.Position - Vector3.new(0, root.Size.Y * 0.5, 0)
				local lowHit = workspace:Raycast(feet + Vector3.new(0, 0.6, 0), probe, params)
				local highHit = workspace:Raycast(feet + Vector3.new(0, 3.2, 0), probe, params)
				if lowHit and not highHit and humanoid.FloorMaterial ~= Enum.Material.Air
					and now - (state.LastJumpAt or 0) >= 0.25 then
					humanoid.Jump = true
					pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
					state.LastJumpAt = now
					mode = "jumping"
					state.DetourGoal, state.DetourFor = nil, nil
				else
					local sameGoal = state.DetourFor and flatDistance(state.DetourFor, goal) < 5
					destination = sameGoal and state.DetourGoal or nil
					if destination and flatDistance(root.Position, destination) <= 2.5 then destination = nil end
					if not destination then
						local canSearch = not state.DetourSearchAt
							or now - state.DetourSearchAt >= interval
						if canSearch then
							destination = chooseDetour(root, goal, target, state, includeMobs)
							state.DetourGoal, state.DetourFor = destination, goal
							state.DetourSearchAt = now
						else
							destination = state.DetourGoal
								and state.DetourFor
								and flatDistance(state.DetourFor, goal) < 5
								and state.DetourGoal
							or goal
						end
					end
					if destination then
						mode = "detouring"
					else
						-- Keep pressing toward the target if no safe local sidestep is available.
						state.DetourGoal, state.DetourFor = nil, nil
						destination = goal
					end
				end
			else
				state.DetourGoal, state.DetourFor = nil, nil
				state.DetourSearchAt = nil
			end

			-- Treat minInterval as an actual MoveTo rate limit. A moving follow target
			-- can shift every frame; issuing a new command for each shift causes jitter.
			if not state.Active or now - (state.LastMoveAt or 0) >= interval then
				humanoid:MoveTo(destination)
				state.Active, state.Goal, state.LastMoveAt = true, destination, now
			end
			state.NavigationMode = mode
			return false, mode
		end

	end,
}
