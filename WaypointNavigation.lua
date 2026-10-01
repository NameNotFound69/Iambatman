-- Dedicated waypoint movement. Uses Humanoid:MoveTo and local obstacle probes only.
local VERSION = "1.2.1"
print("[WaypointNavigation] Version " .. VERSION .. " (waypoint-distance progress + repeated jump recovery)")

return {
	Initialize = function(_configuration, dependencies)
		local players = dependencies.Players
		local mobsFolder = dependencies.MobsFolder
		local state = {
			Active = false,
			Goal = nil,
			CommandGoal = nil,
			LastCommandAt = 0,
			DetourGoal = nil,
			DetourFor = nil,
			LastSearchAt = 0,
			ProgressAt = 0,
			ProgressGoal = nil,
			ProgressDistance = nil,
			DetourSideBias = 1,
			DetourDistance = 8,
			DirectClearSince = nil,
			JumpUntil = 0,
			LastJumpAt = 0,
			StuckJumpUntil = 0,
			LastStuckJumpAt = 0,
		}

		local SEARCH_INTERVAL = 0.45
		local PROGRESS_INTERVAL = 1.0
		local MOVE_REFRESH_INTERVAL = 5
		local ARRIVAL_RADIUS = 0.75
		local DETOUR_REACHED_RADIUS = 3
		local DIRECT_CLEAR_CONFIRMATION = 0.75
		local MIN_PROGRESS = 0.4
		local STUCK_JUMP_REPEAT_INTERVAL = 0.3
		local STUCK_JUMP_WINDOW = 1.1

		local function flatDistance(a, b)
			local offset = b - a
			return Vector3.new(offset.X, 0, offset.Z).Magnitude
		end

		local function clearState()
			state.Active = false
			state.Goal = nil
			state.CommandGoal = nil
			state.LastCommandAt = 0
			state.DetourGoal = nil
			state.DetourFor = nil
			state.LastSearchAt = 0
			state.ProgressAt = 0
			state.ProgressGoal = nil
			state.ProgressDistance = nil
			state.DetourSideBias = 1
			state.DetourDistance = 8
			state.DirectClearSince = nil
			state.JumpUntil = 0
			state.LastJumpAt = 0
			state.StuckJumpUntil = 0
			state.LastStuckJumpAt = 0
		end

		local function makeRaycastParams(root)
			local excluded = { root.Parent }
			if mobsFolder and mobsFolder.Parent then
				table.insert(excluded, mobsFolder)
			end
			if players then
				for _, player in ipairs(players:GetPlayers()) do
					local character = player.Character
					if character and character ~= root.Parent then
						table.insert(excluded, character)
					end
				end
			end

			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = excluded
			params.RespectCanCollide = true
			return params
		end

		local function floorAt(point, params)
			local result = workspace:Raycast(
				Vector3.new(point.X, point.Y + 60, point.Z),
				Vector3.new(0, -250, 0),
				params
			)
			if not result or result.Material == Enum.Material.Water or result.Normal.Y < 0.5 then
				return nil
			end
			return result
		end

		local function directObstruction(root, goal, params)
			local direction = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			if direction.Magnitude <= 0.1 then return nil, direction end
			local hit = workspace:Raycast(root.Position + Vector3.new(0, 1.5, 0), direction, params)
			return hit, direction
		end

		local function canJumpOver(root, humanoid, direction, params, now)
			if now < state.JumpUntil or now - state.LastJumpAt < 1 then return false end
			if humanoid.FloorMaterial == Enum.Material.Air or direction.Magnitude <= 0.1 then return false end

			local probe = direction.Unit * math.min(4.5, direction.Magnitude)
			local feet = root.Position - Vector3.new(0, root.Size.Y * 0.5, 0)
			local lowHit = workspace:Raycast(feet + Vector3.new(0, 0.6, 0), probe, params)
			local highHit = workspace:Raycast(feet + Vector3.new(0, 3.2, 0), probe, params)
			local stepUp = false
			local ahead = root.Position + probe
			local groundAhead = floorAt(ahead, params)
			if groundAhead then
				stepUp = groundAhead.Position.Y - feet.Y >= 1.2
			end
			if (lowHit and not highHit) or stepUp then
				humanoid.Jump = true
				state.LastJumpAt = now
				state.JumpUntil = now + 0.6
				state.DetourGoal = nil
				state.DetourFor = nil
				return true
			end
			return false
		end

		local function chooseDetour(root, goal, params)
			local toward = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			if toward.Magnitude < 0.1 then return nil end
			toward = toward.Unit

			local rootFloor = floorAt(root.Position, params)
			local rootHeight = rootFloor
				and math.max(root.Position.Y - rootFloor.Position.Y, root.Size.Y * 0.5)
				or root.Size.Y
			local preferredDistance = math.clamp(state.DetourDistance or 8, 8, 20)
			local preferredSide = state.DetourSideBias or 1
			local bestVisible, bestVisibleScore = nil, math.huge
			local bestFallback, bestFallbackScore = nil, math.huge

			local radii = {}
			for _, requestedRadius in ipairs({ preferredDistance, preferredDistance + 4, preferredDistance + 8, 20 }) do
				local radius = math.min(requestedRadius, 20)
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
						local floor = floorAt(candidateXZ, params)
						if floor and (not rootFloor or math.abs(floor.Position.Y - rootFloor.Position.Y) <= 12) then
							local candidate = Vector3.new(candidateXZ.X, floor.Position.Y + rootHeight, candidateXZ.Z)
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

		local function updateProgress(root, fallbackGoal, now)
			-- Judge progress against the pinned waypoint itself. Progress toward a
			-- detour alone must not hide pacing or backtracking around the same spot.
			local trackedGoal = fallbackGoal
			local distanceNow = flatDistance(root.Position, trackedGoal)
			if not state.ProgressAt or not state.ProgressGoal
				or flatDistance(state.ProgressGoal, trackedGoal) > 1.5 then
				state.ProgressAt = now
				state.ProgressGoal = trackedGoal
				state.ProgressDistance = distanceNow
				return false
			end
			if now - state.ProgressAt < PROGRESS_INTERVAL then return false end

			-- Measure progress toward the active MoveTo destination in XZ. Vertical
			-- bobbing on uneven terrain must not count as forward movement.
			local progress = (state.ProgressDistance or distanceNow) - distanceNow
			state.ProgressAt = now
			state.ProgressGoal = trackedGoal
			state.ProgressDistance = distanceNow
			if progress >= MIN_PROGRESS or distanceNow <= ARRIVAL_RADIUS + 0.5 then
				state.StuckJumpUntil = 0
				return false
			end

			state.StuckJumpUntil = now + STUCK_JUMP_WINDOW
			state.DetourSideBias = -(state.DetourSideBias or 1)
			state.DetourDistance = math.min((state.DetourDistance or 8) + 4, 20)
			state.DetourGoal = nil
			state.DetourFor = nil
			state.LastSearchAt = 0
			state.LastCommandAt = 0
			return true
		end

		local function pulseStuckJump(humanoid, now)
			if now > state.StuckJumpUntil
				or now - state.LastStuckJumpAt < STUCK_JUMP_REPEAT_INTERVAL
				or humanoid.FloorMaterial == Enum.Material.Air then
				return
			end
			humanoid.Jump = true
			state.LastStuckJumpAt = now
		end

		local controller = {}
		function controller.Reset()
			clearState()
		end

		function controller.Update(humanoid, root, goal)
			if not humanoid or not root or not goal then
				clearState()
				return false, "unavailable"
			end

			local now = os.clock()
			local goalChanged = not state.Goal
				or flatDistance(state.Goal, goal) > 1
				or math.abs(state.Goal.Y - goal.Y) > 1
			if goalChanged then
				clearState()
				state.Goal = goal
				state.ProgressAt = now
				state.ProgressGoal = goal
				state.ProgressDistance = flatDistance(root.Position, goal)
			end

			if (root.Position - goal).Magnitude <= ARRIVAL_RADIUS then
				if state.Active then humanoid:MoveTo(root.Position) end
				clearState()
				return true, "arrived"
			end

			local stalled = updateProgress(root, goal, now)
			pulseStuckJump(humanoid, now)
			local params = makeRaycastParams(root)
			local obstruction = directObstruction(root, goal, params)
			local destination = goal
			local mode = "direct"
			local activeGoal = state.CommandGoal or goal
			local recoveryDirection = Vector3.new(
				activeGoal.X - root.Position.X,
				0,
				activeGoal.Z - root.Position.Z
			)
			local shouldRecover = obstruction ~= nil or stalled
			local shouldJump = now < state.JumpUntil
				or (shouldRecover and canJumpOver(root, humanoid, recoveryDirection, params, now))

			if shouldJump then
				state.DirectClearSince = nil
				mode = "jumping"
				destination = activeGoal
			elseif shouldRecover then
				state.DirectClearSince = nil
				local sameGoal = state.DetourFor and flatDistance(state.DetourFor, goal) < 2
				local stillOnDetour = sameGoal and state.DetourGoal
					and flatDistance(root.Position, state.DetourGoal) > DETOUR_REACHED_RADIUS
				if stillOnDetour and not stalled then
					destination = state.DetourGoal
				else
					if sameGoal and state.DetourGoal then
						state.DetourGoal = nil
						state.DetourFor = nil
						state.LastSearchAt = 0
					end
					local canSearch = now - state.LastSearchAt >= SEARCH_INTERVAL
					if canSearch then
						state.DetourGoal = chooseDetour(root, goal, params)
						state.DetourFor = goal
						state.LastSearchAt = now
					end
					destination = state.DetourGoal or goal
				end
				mode = state.DetourGoal and "detouring" or "direct"
			else
				local detourStillAhead = state.DetourGoal
					and flatDistance(root.Position, state.DetourGoal) > DETOUR_REACHED_RADIUS
				if detourStillAhead then
					state.DirectClearSince = state.DirectClearSince or now
					if now - state.DirectClearSince < DIRECT_CLEAR_CONFIRMATION then
						destination = state.DetourGoal
						mode = "detouring"
					else
						state.DetourGoal = nil
						state.DetourFor = nil
						state.LastSearchAt = 0
						state.DirectClearSince = nil
					end
				else
					state.DetourGoal = nil
					state.DetourFor = nil
					state.LastSearchAt = 0
					state.DirectClearSince = nil
				end
			end

			local destinationChanged = not state.CommandGoal
				or (state.CommandGoal - destination).Magnitude > 1.5
			local refreshDue = now - state.LastCommandAt >= MOVE_REFRESH_INTERVAL
			if not state.Active or destinationChanged or refreshDue or stalled then
				humanoid:MoveTo(destination)
				state.Active = true
				state.CommandGoal = destination
				state.LastCommandAt = now
				state.ProgressAt = now
				state.ProgressGoal = goal
				state.ProgressDistance = flatDistance(root.Position, goal)
			end
			return false, mode
		end

		return controller
	end,
}
