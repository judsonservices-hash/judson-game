--!strict
--[[
	Deep Tide — server bootstrap
	Source: GDD Appendix B ("Services (server, Knit.CreateService)" — all nine must register),
	        §11 acceptance ("Knit boots with zero errors and all services in Appendix B registered").

	The only Script on the server. Order of business:
	  1. create ReplicatedStorage.DeepTide.Remotes and its 12 RemoteEvents (Appendix B)
	  2. run the config consistency check and surface any problem as a warning
	  3. register every ModuleScript in ServerScriptService.DeepTide.Services with Knit
	  4. start Knit and print exactly one boot line
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Configs = require(ReplicatedStorage.DeepTide.Modules.Configs)
local ConfigCheck = require(ReplicatedStorage.DeepTide.Modules.ConfigCheck)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)

local BUILD_VERSION = "0.1.0"

local DeepTide = script.Parent -- ServerScriptService.DeepTide
local Services = DeepTide:WaitForChild("Services")
local PlayerStore = require(DeepTide.Modules.PlayerStore)

Remotes.ensure()

local report = ConfigCheck.run()
for _, problem in report.problems do
	warn("[Deep Tide] config: " .. problem)
end

local serviceCount = 0
for _, child in Services:GetChildren() do
	if child:IsA("ModuleScript") then
		serviceCount += 1
	end
end

Knit.AddServices(Services)

Knit.Start():andThen(function()
	print(
		("[Deep Tide] v%s booted — %d services · %s · %d remotes · persistence: %s"):format(
			BUILD_VERSION,
			serviceCount,
			ConfigCheck.summary(report, #Configs.Fish.Order, Configs.Fish.TotalLiveAtServerStart),
			#Remotes.Names,
			PlayerStore.mode
		)
	)
end):catch(function(err: any)
	warn("[Deep Tide] Knit failed to start: " .. tostring(err))
end)
