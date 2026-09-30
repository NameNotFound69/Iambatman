-- Iamrich adapter for AIC's SafeBoosterReset feature.
local VERSION = "1.0.0"
print("[SafeBoosterReset] Version " .. VERSION)

return {
	Initialize = function(configuration, dependencies)
		local player = dependencies.Player
		local replicatedStorage = dependencies.ReplicatedStorage
		local notify = dependencies.Notify
		local boostConnection
		local statsChildConnection
		local statsRemovedConnection
		local boostChildConnection
		local boostRemovedConnection
		local boundStats
		local watchedBoost
		local warnedMissingTags = false

		local function handleBoostChanged(boost)
			if configuration.SafeBoosterResetEnabled ~= true then return end

			local value = tonumber(boost.Value)
			if not value then return end
			if value <= 0 then
				if notify then notify("Safe booster reset", "Boost is empty; no reset.") end
				return
			end

			local damageTags = replicatedStorage:FindFirstChild("PlayerDamageTags")
			if not damageTags then
				if not warnedMissingTags then
					warnedMissingTags = true
					warn("[SafeBoosterReset] Reset skipped: PlayerDamageTags is unavailable.")
				end
				return
			end
			if damageTags:FindFirstChild(player.Name .. "MobDamaged") then return end

			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = 0
			end
		end

		local function bindBoost(stats)
			if boundStats == stats then return end
			if boostConnection then boostConnection:Disconnect() end
			if boostChildConnection then boostChildConnection:Disconnect() end
			if boostRemovedConnection then boostRemovedConnection:Disconnect() end
			boundStats = stats
			watchedBoost = nil
			boostConnection = nil
			boostChildConnection = nil
			boostRemovedConnection = nil

			local function connect(valueObject)
				if not valueObject or valueObject.Name ~= "Boost" or not valueObject:IsA("ValueBase") then return end
				if watchedBoost == valueObject then return end
				if boostConnection then boostConnection:Disconnect() end
				watchedBoost = valueObject
				boostConnection = valueObject:GetPropertyChangedSignal("Value"):Connect(function()
					handleBoostChanged(valueObject)
				end)
			end

			connect(stats:FindFirstChild("Boost"))
			boostChildConnection = stats.ChildAdded:Connect(connect)
			boostRemovedConnection = stats.ChildRemoved:Connect(function(child)
				if child ~= watchedBoost then return end
				if boostConnection then boostConnection:Disconnect() end
				boostConnection = nil
				watchedBoost = nil
			end)
		end

		local function watchPlayerStats(child)
			if child and child.Name == "PlayerStats" then bindBoost(child) end
		end

		watchPlayerStats(player:FindFirstChild("PlayerStats"))
		statsChildConnection = player.ChildAdded:Connect(watchPlayerStats)
		statsRemovedConnection = player.ChildRemoved:Connect(function(child)
			if child ~= boundStats then return end
			if boostConnection then boostConnection:Disconnect() end
			if boostChildConnection then boostChildConnection:Disconnect() end
			if boostRemovedConnection then boostRemovedConnection:Disconnect() end
			boostConnection = nil
			boostChildConnection = nil
			boostRemovedConnection = nil
			boundStats = nil
			watchedBoost = nil
		end)

		local api = {}
		function api.SetEnabled(enabled)
			configuration.SafeBoosterResetEnabled = enabled == true
			return configuration.SafeBoosterResetEnabled
		end

		function api.Destroy()
			if boostConnection then boostConnection:Disconnect() end
			if boostChildConnection then boostChildConnection:Disconnect() end
			if boostRemovedConnection then boostRemovedConnection:Disconnect() end
			if statsChildConnection then statsChildConnection:Disconnect() end
			if statsRemovedConnection then statsRemovedConnection:Disconnect() end
			boostConnection = nil
			boostChildConnection = nil
			boostRemovedConnection = nil
			statsChildConnection = nil
			statsRemovedConnection = nil
			boundStats = nil
			watchedBoost = nil
		end

		return api
	end,
}
