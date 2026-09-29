-- Reversible client-side graphics reductions for lower rendering load.
local VERSION = "1.2.0"
print("[FPSBoostSystem] Version " .. VERSION .. " (reversible visual reductions + preserved scene lighting)")

return {
	Initialize = function(_, dependencies)
		local Lighting = dependencies.Lighting or game:GetService("Lighting")
		local originalValues = setmetatable({}, { __mode = "k" })
		local descendantAddedConnections = nil
		local enabled = false

		local function setTrackedProperty(instance, property, value)
			local properties = originalValues[instance]
			if not properties then
				properties = {}
				originalValues[instance] = properties
			end
			if properties[property] == nil then
				local ok, original = pcall(function() return instance[property] end)
				if not ok then return end
				properties[property] = original
			end
			pcall(function() instance[property] = value end)
		end

		local function reduceVisuals(instance)
			if instance:IsA("BasePart") then
				setTrackedProperty(instance, "CastShadow", false)
			elseif (instance:IsA("PostEffect")
				and not instance:IsA("BloomEffect")
				and not instance:IsA("ColorCorrectionEffect"))
				or instance:IsA("ParticleEmitter")
				or instance:IsA("Beam")
				or instance:IsA("Trail")
				or instance:IsA("Fire")
				or instance:IsA("Smoke")
				or instance:IsA("Sparkles") then
				setTrackedProperty(instance, "Enabled", false)
			end
		end

		local function apply()
			setTrackedProperty(Lighting, "GlobalShadows", false)
			for _, instance in ipairs(Lighting:GetDescendants()) do
				reduceVisuals(instance)
			end
			for _, instance in ipairs(workspace:GetDescendants()) do
				reduceVisuals(instance)
			end
			if not descendantAddedConnections then
				local function onDescendantAdded(instance)
					if not enabled then return end
					if instance:IsA("BasePart")
					or (instance:IsA("PostEffect")
						and not instance:IsA("BloomEffect")
						and not instance:IsA("ColorCorrectionEffect"))
						or instance:IsA("ParticleEmitter")
						or instance:IsA("Beam")
						or instance:IsA("Trail")
						or instance:IsA("Fire")
						or instance:IsA("Smoke")
						or instance:IsA("Sparkles") then
						reduceVisuals(instance)
					end
				end
				descendantAddedConnections = {
					workspace.DescendantAdded:Connect(onDescendantAdded),
					Lighting.DescendantAdded:Connect(onDescendantAdded),
				}
			end
		end

		local function restore()
			if descendantAddedConnections then
				for _, connection in ipairs(descendantAddedConnections) do
					connection:Disconnect()
				end
				descendantAddedConnections = nil
			end
			for instance, properties in pairs(originalValues) do
				for property, original in pairs(properties) do
					pcall(function() instance[property] = original end)
				end
			end
			table.clear(originalValues)
		end

		local api = {}
		function api.SetEnabled(value)
			enabled = value == true
			if enabled then
				apply()
			else
				restore()
			end
			return enabled
		end

		function api.IsEnabled()
			return enabled
		end

		return api
	end,
}
