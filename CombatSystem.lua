-- Combat movement system.
-- Intentionally uses Humanoid:MoveTo() only.
return {
	Initialize = function(configuration, dependencies)
		local combat = configuration.CombatSystem
		local mobsFolder = dependencies.MobsFolder
		local unreachableUntil = setmetatable({}, { __mode = "k" })
		local bladeCache = setmetatable({}, { __mode = "k" })
		local safeDistance = 4

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
					if (position - closestWorld).Magnitude < safeDistance then
						return false
					end
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
			if not state then return end
			state.Active = false
			state.Goal = nil
			state.LastMoveAt = 0
			state.NavigationMode = nil
			state.ApproachAngle = nil
			state.RepositionUntil = nil
			state.LastApproachPoint = nil
			state.ApproachTarget = nil
			state.PursuitOrbitAngle = nil
			state.PursuitOrbitAt = nil
			state.StuckRetries = 0
			state.ProgressPosition = nil
			state.ProgressAt = nil
			state.Path = nil
			state.Waypoints = nil
			state.WaypointIndex = nil
			state.PathGoal = nil
			state.PathMoveGoal = nil
			state.PathComputedAt = nil
			state.PathComputing = false
			state.DirectPathBlocked = nil
			state.PathRequestId = (state.PathRequestId or 0) + 1
		end

		local function flatDistance(a, b)
			local dx = a.X - b.X
			local dz = a.Z - b.Z
			return math.sqrt(dx * dx + dz * dz)
		end

		local function flatDirection(fromPosition, toPosition, fallback)
			local delta = Vector3.new(
				toPosition.X - fromPosition.X,
				0,
				toPosition.Z - fromPosition.Z
			)
			if delta.Magnitude > 0.01 then
				return delta.Unit
			end
			if fallback and fallback.Magnitude > 0.01 then
				return fallback.Unit
			end
			return Vector3.new(1, 0, 0)
		end

		-- MoveTo-only navigation.
		-- The caller keeps the target-selection / attack logic. This function only
		-- tells Humanoid where to walk and reports whether that destination is reached.
		function combat.NavigateMoveTo(humanoid, root, goal, targetModel, state, minInterval, stopRadius, checkVertical)
			if not humanoid or not root or not goal then
				return false, "unavailable"
			end

			state = state or {}
			local now = os.clock()
			local radius = stopRadius or 1.9
			local distance = checkVertical and (root.Position - goal).Magnitude
				or flatDistance(root.Position, goal)

			if distance <= radius then
				if state.Active then
					humanoid:MoveTo(root.Position)
				end
				state.Active = false
				state.Goal = nil
				state.LastMoveAt = now
				state.NavigationMode = "direct"
				state.ProgressPosition = root.Position
				state.ProgressAt = now
				return true, "direct"
			end

			local point = checkVertical
				and goal
				or Vector3.new(goal.X, root.Position.Y, goal.Z)

			local sameGoal = state.Goal
				and (state.Goal - goal).Magnitude <= 0.75
			local interval = minInterval or 0.15

			-- Re-issue MoveTo periodically so long walks do not expire.
			if not state.Active
				or not sameGoal
				or now - (state.LastMoveAt or 0) >= interval then
				humanoid:MoveTo(point)
				state.Active = true
				state.Goal = goal
				state.LastMoveAt = now
				state.ProgressPosition = root.Position
				state.ProgressAt = now
			end

			state.NavigationMode = "direct"
			return false, "direct"
		end

		function combat.SelectApproachPoint(localRoot, targetRoot, standoff, targetModel, state, attackRange)
			if not localRoot or not targetRoot then
				return localRoot and localRoot.Position or nil
			end

			state = state or {}
			local desired = math.max(1.5, tonumber(standoff) or 4)
			local maxAttackDistance = tonumber(attackRange) or desired + 3

			-- Never make the goal farther away just because the mob's root part is large.
			-- The desired point is always between the player and the mob when approaching.
			local currentDistance = flatDistance(localRoot.Position, targetRoot.Position)
			local awayFromMob = flatDirection(
				targetRoot.Position,
				localRoot.Position,
				Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
			)

			if currentDistance <= desired then
				if combat.ShouldEvadeTarget(targetModel, localRoot.Position) then
					-- While the enemy is using a blade skill, make a small lateral
					-- MoveTo destination instead of walking deeper into the mob.
					local right = Vector3.new(-awayFromMob.Z, 0, awayFromMob.X)
					local candidates = {
						localRoot.Position + right * 5,
						localRoot.Position - right * 5,
						localRoot.Position + awayFromMob * 4,
					}
					for _, candidate in ipairs(candidates) do
						if combat.IsPositionSafeFromBlades(candidate, targetModel) then
							return candidate
						end
					end
				end
				return localRoot.Position
			end

			-- Normal approach: walk directly toward the target until standoff distance.
			local goalDistance = math.min(desired, math.max(1.5, currentDistance - 0.5))
			goalDistance = math.min(goalDistance, math.max(1.5, maxAttackDistance - 1))

			local goal = targetRoot.Position + awayFromMob * goalDistance

			-- If the target is currently using a blade skill, prefer a nearby safe
			-- side at roughly the same combat distance. This is still MoveTo-only.
			if combat.ShouldEvadeTarget(targetModel, localRoot.Position) then
				local right = Vector3.new(-awayFromMob.Z, 0, awayFromMob.X)
				local directions = {
					awayFromMob,
					(awayFromMob + right).Magnitude > 0.01 and (awayFromMob + right).Unit or awayFromMob,
					(awayFromMob - right).Magnitude > 0.01 and (awayFromMob - right).Unit or awayFromMob,
					right,
					-right,
				}

				local best, bestDistance = nil, math.huge
				for _, direction in ipairs(directions) do
					local candidate = targetRoot.Position + direction * goalDistance
					if combat.IsPositionSafeFromBlades(candidate, targetModel) then
						local travel = flatDistance(localRoot.Position, candidate)
						if travel < bestDistance then
							best = candidate
							bestDistance = travel
						end
					end
				end
				if best then
					goal = best
				end
			end

			return Vector3.new(goal.X, localRoot.Position.Y, goal.Z)
		end

		function combat.FaceTargetSmooth(root, targetPos, alpha)
			if not root or not targetPos then return end
			local flatTarget = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
			local delta = flatTarget - root.Position
			if delta.Magnitude < 0.05 then return end

			local look = CFrame.lookAt(root.Position, flatTarget)
			local blend = math.clamp(alpha or 0.35, 0.05, 1)
			root.CFrame = root.CFrame:Lerp(look, blend)
		end
	end,
}