--!strict
--[[
	RodController — GDD §1 step 2 (take the Rusty Rod from the Rod Rack), §5.4 + §9
	(`ROD: RUSTY / BRASS` — the rod is why a line snaps, so the player must be able to
	blame it correctly), §6.3 (the Brass Rod purchase changes this readout).

	Owns: the rod the local player is holding, and the Rod Rack prompt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local RodController = Knit.CreateController {
	Name = "RodController",
}


-- Public API ------------------------------------------------------------------

--- The rod id the HUD is showing.
function RodController:GetEquippedRodId(): string
	-- TODO(§1 step 2): the server is authoritative — GearService:GetRodReadout.
	return EconomyConfig.StartingRodId
end

--- "RUSTY" / "BRASS" for the HUD line (§9).
function RodController:GetRodTierLabel(): string
	local rod = RodConfig.Rods[self:GetEquippedRodId()]
	return string.upper(rod.name:gsub(" Rod$", ""))
end

--- Swap the visible rod (§1 step 2 for the free Rusty Rod, §6.3 for the Brass Rod) and
--- hand the model to the character.
function RodController:SetEquippedRod(rodId: string)
	-- TODO: validate against RodConfig.Rods, attach the rod to the character, refresh the HUD.
end

--- §5.4: the reason a cast is about to snap, ready for the HUD to print verbatim.
function RodController:GetMaxRarity(): string
	return RodConfig.Rods[self:GetEquippedRodId()].maxRarity
end

-- Knit lifecycle --------------------------------------------------------------

function RodController:KnitStart()
	-- TODO(§1 step 2): find the Rod Rack ProximityPrompt under Workspace.DeepTide.Spawns,
	-- label it "E — Take Rusty Rod", and hand out the rod on trigger.
	-- TODO(§9): keep RodController:GetRodTierLabel the single source for the HUD readout.
end

return RodController
