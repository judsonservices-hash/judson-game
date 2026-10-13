--!strict
--[[
	Deep Tide — client bootstrap
	Source: GDD Appendix B (the client mirrors the server: controllers registered with Knit).

	The only LocalScript on the client. It waits for the server-created Remotes folder,
	registers every ModuleScript in StarterPlayerScripts.DeepTide.Controllers and starts Knit.
	It prints nothing: the contract is one startup line, and the server owns it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)

local DeepTide = script.Parent -- StarterPlayerScripts.DeepTide
local Controllers = DeepTide:WaitForChild("Controllers")

-- Blocks until the server has created ReplicatedStorage.DeepTide.Remotes (Appendix B),
-- so no controller can fire into a missing remote during a slow join.
Remotes.getFolder()

Knit.AddControllers(Controllers)

Knit.Start():catch(function(err: any)
	warn("[Deep Tide] Knit client failed to start: " .. tostring(err))
end)
