-- Bounded local grid search for waypoint/follow movement. This intentionally
-- uses raycasts and Humanoid:MoveTo instead of Roblox PathfindingService.
local VERSION = "1.0.0"
print("[LocalRoutePlanner] Version " .. VERSION .. " (bounded local A* + route smoothing)")

local CELL_SIZE = 4.5
local GRID_RADIUS = 4
local MAX_EXPANSIONS = 56
local MAX_DIRECT_GOAL_DISTANCE = 22

local CARDINAL_AND_DIAGONAL = {
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 1, 1.4142 }, { 1, -1, 1.4142 }, { -1, 1, 1.4142 }, { -1, -1, 1.4142 },
}

local function flatDistance(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function makeKey(x, z)
	return tostring(x) .. ":" .. tostring(z)
end

local function heuristic(x, z, goalX, goalZ, cellSize)
	local dx, dz = math.abs(goalX - x), math.abs(goalZ - z)
	local diagonal = math.min(dx, dz)
	return cellSize * (diagonal * 1.4142 + math.max(dx, dz) - diagonal)
end

return {
	VERSION = VERSION,
	FindRoute = function(root, goal, params, options)
		if not root or not goal or not params then return nil, false end
		options = options or {}
		local cellSize = math.clamp(tonumber(options.CellSize) or CELL_SIZE, 3, 7)
		local gridRadius = math.clamp(math.floor(tonumber(options.GridRadius) or GRID_RADIUS), 3, 6)
		local maxExpansions = math.clamp(math.floor(tonumber(options.MaxExpansions) or MAX_EXPANSIONS), 24, 120)
		local directDistance = tonumber(options.MaxDirectGoalDistance) or MAX_DIRECT_GOAL_DISTANCE

		local rootFloor = workspace:Raycast(
			root.Position + Vector3.new(0, 18, 0),
			Vector3.new(0, -55, 0),
			params
		)
		if not rootFloor or rootFloor.Material == Enum.Material.Water or rootFloor.Normal.Y < 0.5 then
			return nil, false
		end
		local bodyHeight = math.clamp(
			root.Position.Y - rootFloor.Position.Y,
			root.Size.Y * 0.5,
			math.max(root.Size.Y * 0.5, root.Size.Y * 2.5)
		)
		local start = Vector3.new(root.Position.X, rootFloor.Position.Y + bodyHeight, root.Position.Z)
		local startDistance = flatDistance(start, goal)
		if startDistance <= 1 then return { goal }, true end

		local goalX = math.floor((goal.X - start.X) / cellSize + 0.5)
		local goalZ = math.floor((goal.Z - start.Z) / cellSize + 0.5)
		local groundCache, edgeCache = {}, {}
		local nodeByKey = {}

		local function pointAt(x, z)
			return Vector3.new(start.X + x * cellSize, start.Y, start.Z + z * cellSize)
		end

		local function groundNode(x, z)
			local key = makeKey(x, z)
			if groundCache[key] ~= nil then
				local cached = groundCache[key]
				return cached ~= false and cached or nil
			end
			local xz = pointAt(x, z)
			local hit = workspace:Raycast(
				Vector3.new(xz.X, root.Position.Y + 18, xz.Z),
				Vector3.new(0, -55, 0),
				params
			)
			if not hit or hit.Material == Enum.Material.Water or hit.Normal.Y < 0.5 then
				groundCache[key] = false
				return nil
			end
			local node = {
				X = x,
				Z = z,
				GroundY = hit.Position.Y,
				Position = Vector3.new(xz.X, hit.Position.Y + bodyHeight, xz.Z),
			}
			if math.abs(node.GroundY - rootFloor.Position.Y) > 24 then
				groundCache[key] = false
				return nil
			end
			groundCache[key] = node
			return node
		end

		local function legClear(fromNode, toNode)
			local from, to = fromNode.Position, toNode.Position
			local keyA, keyB = makeKey(fromNode.X, fromNode.Z), makeKey(toNode.X, toNode.Z)
			local cacheKey = keyA < keyB and (keyA .. "|" .. keyB) or (keyB .. "|" .. keyA)
			if edgeCache[cacheKey] ~= nil then return edgeCache[cacheKey] end
			local delta = to - from
			local horizontal = Vector3.new(delta.X, 0, delta.Z)
			if horizontal.Magnitude > 0.1 then
				for _, height in ipairs({ 1.25, 3.1 }) do
					if workspace:Raycast(from + Vector3.new(0, height, 0), delta, params) then
						edgeCache[cacheKey] = false
						return false
					end
				end
			end
			local groundDelta = toNode.GroundY - fromNode.GroundY
			local clear = groundDelta <= 4.5 and groundDelta >= -7
			edgeCache[cacheKey] = clear
			return clear
		end

		local function directLegClear(from, to)
			local delta = to - from
			local horizontal = Vector3.new(delta.X, 0, delta.Z)
			if horizontal.Magnitude <= 0.1 then return true end
			for _, height in ipairs({ 1.25, 3.1 }) do
				if workspace:Raycast(from + Vector3.new(0, height, 0), delta, params) then
					return false
				end
			end
			local samples = math.max(1, math.ceil(horizontal.Magnitude / (cellSize * 0.65)))
			for i = 1, samples - 1 do
				local alpha = i / samples
				local point = from:Lerp(to, alpha)
				local floorHit = workspace:Raycast(
					Vector3.new(point.X, point.Y + 10, point.Z),
					Vector3.new(0, -30, 0),
					params
				)
				local expectedGroundY = point.Y - bodyHeight
				if not floorHit or floorHit.Material == Enum.Material.Water or floorHit.Normal.Y < 0.5
					or math.abs(floorHit.Position.Y - expectedGroundY) > 6 then
					return false
				end
			end
			return true
		end

		local function visibilityClear(from, to)
			local delta = to - from
			if Vector3.new(delta.X, 0, delta.Z).Magnitude <= 0.1 then return true end
			for _, height in ipairs({ 1.25, 3.1 }) do
				if workspace:Raycast(from + Vector3.new(0, height, 0), delta, params) then
					return false
				end
			end
			return true
		end

		local startNode = { X = 0, Z = 0, GroundY = rootFloor.Position.Y, Position = start, G = 0 }
		nodeByKey[makeKey(0, 0)] = startNode
		groundCache[makeKey(0, 0)] = startNode
		local open = { startNode }
		local closed = {}
		local cameFrom = {}
		local bestVisible, bestVisibleScore
		local bestFrontier, bestFrontierScore
		local expansions = 0

		local function considerEndpoint(node)
			local distance = flatDistance(node.Position, goal)
			if distance < startDistance - 1.5 then
				local score = node.G + distance * 0.8
				if not bestFrontierScore or score < bestFrontierScore then
					bestFrontier, bestFrontierScore = node, score
				end
			end
			if distance <= directDistance and visibilityClear(node.Position, goal) then
				local score = node.G + distance
				if not bestVisibleScore or score < bestVisibleScore then
					if not directLegClear(node.Position, goal) then return false end
					bestVisible, bestVisibleScore = node, score
					return true
				end
			end
			return false
		end

		while #open > 0 and expansions < maxExpansions do
			local bestIndex, bestF = 1, math.huge
			for index, node in ipairs(open) do
				local f = node.G + heuristic(node.X, node.Z, goalX, goalZ, cellSize)
				if f < bestF then bestIndex, bestF = index, f end
			end
			local current = table.remove(open, bestIndex)
			local currentKey = makeKey(current.X, current.Z)
			if not closed[currentKey] then
				closed[currentKey] = true
				expansions += 1
				if considerEndpoint(current) then break end

				for _, offset in ipairs(CARDINAL_AND_DIAGONAL) do
					local nx, nz = current.X + offset[1], current.Z + offset[2]
					if math.abs(nx) <= gridRadius and math.abs(nz) <= gridRadius then
						local neighbor = nodeByKey[makeKey(nx, nz)] or groundNode(nx, nz)
						if neighbor then
							nodeByKey[makeKey(nx, nz)] = neighbor
							local groundStep = neighbor.GroundY - current.GroundY
							if groundStep <= 4.5 and groundStep >= -7 and legClear(current, neighbor) then
								local diagonal = offset[1] ~= 0 and offset[2] ~= 0
								local canTurn = true
								if diagonal then
									local sideX = nodeByKey[makeKey(nx, current.Z)] or groundNode(nx, current.Z)
									local sideZ = nodeByKey[makeKey(current.X, nz)] or groundNode(current.X, nz)
									canTurn = sideX ~= nil and sideZ ~= nil
										and legClear(current, sideX) and legClear(current, sideZ)
								end
								if canTurn then
									local neighborKey = makeKey(nx, nz)
									local newG = current.G + cellSize * offset[3]
									if not closed[neighborKey] and (neighbor.G == nil or newG < neighbor.G) then
										neighbor.G = newG
										cameFrom[neighborKey] = currentKey
										table.insert(open, neighbor)
									end
								end
							end
						end
					end
				end
			end
		end

		local endpoint = bestVisible or bestFrontier
		if not endpoint or endpoint == startNode then return nil, false end
		local path = {}
		local cursorKey = makeKey(endpoint.X, endpoint.Z)
		while cursorKey and cursorKey ~= makeKey(0, 0) do
			local node = nodeByKey[cursorKey]
			if not node then break end
			table.insert(path, 1, node)
			cursorKey = cameFrom[cursorKey]
		end
		if #path == 0 then return nil, false end

		local reachesGoal = bestVisible ~= nil
		local routePoints = {}
		for _, node in ipairs(path) do table.insert(routePoints, node.Position) end
		if reachesGoal then table.insert(routePoints, goal) end

		local route = {}
		local cursor = start
		local index = 1
		while index <= #routePoints do
			local furthest = index
			for candidateIndex = #routePoints, index, -1 do
				if directLegClear(cursor, routePoints[candidateIndex]) then
					furthest = candidateIndex
					break
				end
			end
			local selected = routePoints[furthest]
			if (selected - cursor).Magnitude > 1 then
				table.insert(route, selected)
				cursor = selected
			end
			index = furthest + 1
		end
		if #route == 0 then return nil, false end
		return route, reachesGoal
	end,
}
