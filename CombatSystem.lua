-- Combat helpers adapted from Automated-Industry-Complex-main/Combat.
-- Loaded as its own Luau chunk so combat state and navigation do not add
-- top-level registers to Iamrich.lua.
return {
	Initialize = function(configuration, dependencies)
		local combat = configuration.CombatSystem
		local mobsFolder = dependencies.MobsFolder
		local pathfindingService = dependencies.PathfindingService
		local smoothMoveTo = dependencies.SmoothMoveTo
		local unreachableUntil = setmetatable({}, { __mode = "k" })
		local bladeCache = setmetatable({}, { __mode = "k" })
		local safeDistance = 4 -- AIC: 2 studs attack distance + 2 studs blade padding.

		function combat.IsTargetCoolingDown(mob)
			local expiry = mob and unreachableUntil[mob]
			if not expiry then return false end
			if os.clock() >= expiry then
				unreachableUntil[mob] = nil
				return false
			end
			return true
		end

		function combat.GetBladeParts(mob)
			if not mob or not mob:IsA("Model") then return {} end
			local now = os.clock()
			local cached = bladeCache[mob]
			if cached and now - cached.At < 0.2 then return cached.Parts end
			local parts = {}
			for _, item in ipairs(mob:GetDescendants()) do
				if item:IsA("BasePart") and item.Name == "BladePart" then
					table.insert(parts, item)
				end
			end
			bladeCache[mob] = { At = now, Parts = parts }
			return parts
		end

		function combat.IsEnemyUsingSkill(mob)
			if not mob then return false end
			local sword = mob:FindFirstChild("Sword")
			local blade = sword and sword:FindFirstChild("BladePart")
			local skillSound = mob:FindFirstChild("Skill", true)
			local sparkles = blade and blade:FindFirstChild("Sparkles", true)
			return (skillSound and skillSound:IsA("Sound") and skillSound.IsPlaying)
				or (sparkles and sparkles:IsA("ParticleEmitter") and sparkles.Enabled)
				or false
		end

		function combat.IsPositionSafeFromBlades(position, mob)
			for _, blade in ipairs(combat.GetBladeParts(mob)) do
				if blade:IsDescendantOf(workspace) then
					local localPosition = blade.CFrame:PointToObjectSpace(position)
					local halfSize = blade.Size * 0.5
					local closestLocal = Vector3.new(
						math.clamp(localPosition.X, -halfSize.X, halfSize.X),
						math.clamp(localPosition.Y, -halfSize.Y, halfSize.Y),
						math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
					)
					local closestWorld = blade.CFrame:PointToWorldSpace(closestLocal)
					if (position - closestWorld).Magnitude < safeDistance then return false end
				end
			end
			return true
		end

		function combat.ShouldEvadeTarget(mob, position)
			if not position or not combat.IsEnemyUsingSkill(mob) then return false end
			local blades = combat.GetBladeParts(mob)
			return #blades > 0 and not combat.IsPositionSafeFromBlades(position, mob)
		end

		function combat.ResetNavigationState(state)
			state.PathRequestId = (state.PathRequestId or 0) + 1
			state.PathComputing = false
			state.Active, state.Goal, state.Path, state.Waypoints = false, nil, nil, nil
			state.WaypointIndex, state.PathGoal, state.PathComputedAt = nil, nil, nil
			state.PathMoveGoal, state.LastRaycastAt, state.DirectPathBlocked = nil, nil, nil
			state.ProgressPosition, state.ProgressAt, state.StuckRetries = nil, nil, nil
			state.ApproachAngle, state.RepositionUntil, state.NavigationMode = nil, nil, nil
			state.PursuitOrbitAngle, state.PursuitOrbitAt = nil, nil
			state.LastApproachPoint, state.ApproachTarget = nil, nil
		end

		-- AIC probes low and high before jumping, so flat path waypoints do not
		-- trigger unnecessary jumps. Mobs are excluded because they are targets,
		-- not obstacles.
		local function jumpIfObstacleAhead(root, humanoid, targetPosition)
			if not root or not humanoid or not targetPosition then return false end
			local offset = targetPosition - root.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude < 0.01 then return false end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { root.Parent, mobsFolder }
			params.RespectCanCollide = true
			local direction = flat.Unit * math.min(4.5, flat.Magnitude)
			local feet = root.Position - Vector3.new(0, root.Size.Y * 0.5, 0)
			local low = workspace:Raycast(feet + Vector3.new(0, 0.6, 0), direction, params)
			local high = workspace:Raycast(feet + Vector3.new(0, 3.2, 0), direction, params)
			if low and not high and humanoid.FloorMaterial ~= Enum.Material.Air then
				humanoid.Jump = true
				return true
			end
			return false
		end

		function combat.NavigateMoveTo(humanoid, root, goal, targetModel, state, minInterval, stopRadius, checkVertical)
			if not humanoid or not root or not goal then return false, "unavailable" end
			local now = os.clock()
			if state.Active and now - (state.ProgressAt or 0) >= 1.4 then
				if state.ProgressPosition and (root.Position - state.ProgressPosition).Magnitude < 0.45 then
					state.Path, state.Waypoints, state.WaypointIndex = nil, nil, nil
					state.PathGoal, state.PathComputedAt = goal, 0
					state.LastRaycastAt, state.DirectPathBlocked = nil, true
					state.StuckRetries = (state.StuckRetries or 0) + 1
					if state.MarkUnreachableEligible and state.StuckRetries >= 3 and targetModel
						and targetModel:IsDescendantOf(mobsFolder) then
						unreachableUntil[targetModel] = now + 12
						state.MarkUnreachableEligible = false
					end
				else
					state.StuckRetries = 0
				end
				state.ProgressPosition, state.ProgressAt = root.Position, now
			elseif not state.ProgressAt then
				state.ProgressPosition, state.ProgressAt = root.Position, now
			end

			local flatOffset = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
			local distanceToGoal = checkVertical and (root.Position - goal).Magnitude or flatOffset.Magnitude
			if distanceToGoal <= (stopRadius or 1.9) then
				if state.Active then humanoid:MoveTo(root.Position) end
				state.PathRequestId = (state.PathRequestId or 0) + 1
				state.PathComputing = false
				state.Active, state.Goal, state.Path, state.Waypoints = false, nil, nil, nil
				state.WaypointIndex = nil
				state.StuckRetries, state.ProgressPosition, state.ProgressAt = 0, root.Position, now
				return true, "arrived"
			end

			local pathGoalChanged = not state.PathGoal or (state.PathGoal - goal).Magnitude > 4
			if state.LastRaycastAt == nil or now - state.LastRaycastAt >= 0.2 then
				state.LastRaycastAt = now
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				local filter = { root.Parent }
				if targetModel then table.insert(filter, targetModel) end
				params.FilterDescendantsInstances = filter
				params.RespectCanCollide = true
				local direction = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
				local ok, hit = pcall(function() return workspace:Raycast(root.Position, direction, params) end)
				local verticalDelta = math.abs(root.Position.Y - goal.Y)
				local needsVerticalRoute = verticalDelta > math.max(checkVertical and 0.5 or 3, root.Size.Y * 0.5)
				state.DirectPathBlocked = (ok and hit ~= nil) or needsVerticalRoute
			end

			if not state.DirectPathBlocked then
				if state.PathComputing then
					state.PathRequestId = (state.PathRequestId or 0) + 1
					state.PathComputing = false
				end
				state.Path, state.Waypoints, state.WaypointIndex, state.PathGoal = nil, nil, nil, nil
				return smoothMoveTo(humanoid, root, goal, state, minInterval, stopRadius), "direct"
			end

			if pathGoalChanged then
				state.Path, state.Waypoints, state.WaypointIndex = nil, nil, nil
				state.PathGoal, state.PathComputedAt = goal, 0
				state.PathRequestId = (state.PathRequestId or 0) + 1
				state.PathComputing = false
			end
			if not state.Waypoints and not state.PathComputing and now - (state.PathComputedAt or 0) >= 1.2 then
				state.PathComputedAt = now
				state.PathComputing = true
				local requestId = state.PathRequestId or 0
				local routeStart, routeGoal = root.Position, goal
				task.spawn(function()
					local path
					local ok, result = pcall(function()
						path = pathfindingService:CreatePath({
							AgentRadius = math.max(1.5, root.Size.X * 0.5),
							AgentHeight = math.max(4, root.Size.Y),
							AgentCanJump = true,
							WaypointSpacing = 4,
						})
						path:ComputeAsync(routeStart, routeGoal)
						return path.Status == Enum.PathStatus.Success and path:GetWaypoints() or nil
					end)
					if state.PathRequestId ~= requestId then return end
					state.PathComputing = false
					if ok and result and #result >= 2 then
						state.Path, state.Waypoints, state.WaypointIndex = path, result, 2
					end
				end)
			end

			local waypoints = state.Waypoints
			if waypoints then
				while state.WaypointIndex and state.WaypointIndex <= #waypoints do
					local waypoint = waypoints[state.WaypointIndex]
					local offset = checkVertical and (root.Position - waypoint.Position)
						or Vector3.new(root.Position.X - waypoint.Position.X, 0, root.Position.Z - waypoint.Position.Z)
					if offset.Magnitude > 2.5 then break end
					state.WaypointIndex += 1
				end
				local waypoint = state.WaypointIndex and waypoints[state.WaypointIndex]
				if waypoint then
					local interval = minInterval or 0.25
					local sameWaypoint = state.PathMoveGoal and (state.PathMoveGoal - waypoint.Position).Magnitude < 1
					if not state.Active or not sameWaypoint or now - (state.LastMoveAt or 0) >= interval then
						if waypoint.Action == Enum.PathWaypointAction.Jump then
							jumpIfObstacleAhead(root, humanoid, waypoint.Position)
						end
						humanoid:MoveTo(waypoint.Position)
						state.Active, state.LastMoveAt, state.PathMoveGoal = true, now, waypoint.Position
					end
					return false, "path"
				end
				state.Path, state.Waypoints, state.WaypointIndex = nil, nil, nil
				state.PathComputedAt = 0
			end

			if not state.Active or now - (state.LastMoveAt or 0) >= 1.2 then
				humanoid:MoveTo(checkVertical and goal or Vector3.new(goal.X, root.Position.Y, goal.Z))
				state.Active, state.LastMoveAt, state.Goal = true, now, goal
			end
			return false, "retrying route"
		end

		function combat.SelectApproachPoint(localRoot, targetRoot, standoff, targetModel, state, attackRange)
			-- Combat approach distance must describe where the player should stand,
			-- not the physical size of the mob's RootPart. A large RootPart can be
			-- dozens of studs wide; using targetRoot.Size here can put the destination
			-- behind the player and make pursuit appear to be completely stuck.
			if not localRoot or not targetRoot then
				return localRoot and localRoot.Position or targetRoot and targetRoot.Position
			end

			local targetPosition = targetRoot.Position
			local flatDelta = Vector3.new(
				localRoot.Position.X - targetPosition.X,
				0,
				localRoot.Position.Z - targetPosition.Z
			)
			local currentDistance = flatDelta.Magnitude
			local fallbackLook = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
			local away = flatDelta.Magnitude > 0.01
				and flatDelta.Unit
				or (fallbackLook.Magnitude > 0.01 and fallbackLook.Unit or Vector3.new(1, 0, 0))

			-- Always approach to a distance that is inside the attack range. This
			-- guarantees the goal is between the player and the mob when too far away.
			local maxAttackDistance = math.max(2, (attackRange or 5) - 1)
			local desiredDistance = math.clamp(tonumber(standoff) or 4, 2, maxAttackDistance)

			-- Active BladePart skill takes priority over normal pursuit. Keep the safe
			-- destination close enough to continue combat, but never use mob RootPart size.
			if combat.ShouldEvadeTarget(targetModel, localRoot.Position) then
				local safeRadius = desiredDistance
				for _, blade in ipairs(combat.GetBladeParts(targetModel)) do
					local offset = blade.Position - targetPosition
					local flatOffset = Vector3.new(offset.X, 0, offset.Z)
					if flatOffset.Magnitude > 0.01 then
						safeRadius = math.max(safeRadius, flatOffset.Magnitude + safeDistance)
					end
				end
				-- Do not allow the evade radius to exceed the distance where attacks can
				-- still resume; if every candidate is unsafe, fall back to direct pursuit.
				local cappedRadius = math.min(safeRadius, maxAttackDistance)
				local bestPoint, bestScore = nil, math.huge
				for _, angle in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
					local radians = math.rad(angle)
					local direction = Vector3.new(
						away.X * math.cos(radians) - away.Z * math.sin(radians),
						0,
						away.X * math.sin(radians) + away.Z * math.cos(radians)
					)
					local candidate = targetPosition + direction * cappedRadius
					if combat.IsPositionSafeFromBlades(candidate, targetModel) then
						local travel = (Vector3.new(candidate.X, 0, candidate.Z)
							- Vector3.new(localRoot.Position.X, 0, localRoot.Position.Z)).Magnitude
						local score = travel + math.abs(angle) * 0.015
						if score < bestScore then
							bestPoint, bestScore = candidate, score
						end
					end
				end
				if bestPoint then
					state.ApproachAngle = nil
					state.RepositionUntil = os.clock() + 0.35
					return bestPoint
				end
			end

			-- If already inside the desired combat distance, hold position. Iamrich
			-- can still attack while the navigation state reports arrival.
			if currentDistance <= desiredDistance + 0.25 then
				state.PursuitOrbitAngle, state.PursuitOrbitAt = nil, nil
				return localRoot.Position
			end

			-- If we are outside the desired distance, the destination is guaranteed
			-- to lie along the current player->mob line, closer to the mob than the
			-- player's current position. This is the important anti-stall behavior.
			state.PursuitOrbitAngle, state.PursuitOrbitAt = nil, nil
			local approachPoint = targetPosition + away * desiredDistance

			-- After a genuine navigation stall, try alternate sides around the mob.
			-- These candidates keep the same combat radius instead of using RootPart size.
			local now = os.clock()
			if (state.StuckRetries or 0) > 0 and now >= (state.RepositionUntil or 0) then
				local bestPoint, bestScore = approachPoint, math.huge
				for _, angle in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
					local radians = math.rad(angle)
					local direction = Vector3.new(
						away.X * math.cos(radians) - away.Z * math.sin(radians),
						0,
						away.X * math.sin(radians) + away.Z * math.cos(radians)
					)
					local candidate = targetPosition + direction * desiredDistance
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { localRoot.Parent, targetModel }
					params.RespectCanCollide = true
					local ray = Vector3.new(candidate.X - localRoot.Position.X, 0, candidate.Z - localRoot.Position.Z)
					local ok, hit = pcall(function() return workspace:Raycast(localRoot.Position, ray, params) end)
					local score = ray.Magnitude + ((ok and hit) and 20 or 0) + math.abs(angle) * 0.015
					if score < bestScore then
						bestPoint, bestScore = candidate, score
					end
				end
				approachPoint = bestPoint
				state.RepositionUntil = now + 3.5
			end

			return approachPoint
		end

		function combat.FaceTargetSmooth(root, targetPos, alpha)
			if not root or not targetPos then return end
			local flatTarget = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
			local delta = flatTarget - root.Position
			if delta.Magnitude < 0.05 then return end
			local _, goalYaw, _ = CFrame.lookAt(root.Position, flatTarget):ToOrientation()
			local pos = root.Position
			local blended = root.CFrame:Lerp(CFrame.new(pos) * CFrame.Angles(0, goalYaw, 0), math.clamp(alpha or 0.35, 0.05, 1))
			root.CFrame = CFrame.new(pos) * (blended - blended.Position)
		end
	end,
}
