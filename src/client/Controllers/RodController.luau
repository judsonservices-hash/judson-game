--!strict
--[[
	RodController — GDD §1 step 2 (take the Rusty Rod from the Rod Rack), §5.4 + §9
	(`ROD: RUSTY / BRASS` — the rod is why a line snaps, so the player must be able to
	blame it correctly), §6.3 (the Brass Rod purchase changes this readout).

	Owns: the rod the local player is holding, and the character-side rod model. The rod *verb*
	(taking it from the rack, buying the Brass Rod) is server work: GearService owns the equipped
	rod and stamps it on the Player as an attribute, which replicates here with no extra remote.

	The rod is a Tool with a single Handle Part (§Appendix A: primitives only) — enough for the
	cast line to start at a believable tip, and enough for the UI/art pass to replace later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local RodController = Knit.CreateController({
	Name = "RodController",
})

local TOOL_NAME = "DeepTideRod"

local player = Players.LocalPlayer

-- §Appendix A: the two rod tiers, in primitives. Rusty is a plain driftwood shaft; Brass is a
-- longer, brighter one (§6.3 is a visible upgrade as well as a statistical one).
local ROD_LOOK = {
	RustyRod = { length = 6, color = Color3.fromRGB(122, 88, 62), material = Enum.Material.Wood },
	BrassRod = { length = 7.5, color = Color3.fromRGB(198, 160, 74), material = Enum.Material.Metal },
}

local function hud(): any
	local ok, controller = pcall(function()
		return Knit.GetController("HudController")
	end)
	return if ok then controller else nil
end

-- Public API ------------------------------------------------------------------

--- The rod id the HUD is showing. Read from the Player attribute GearService stamps.
function RodController:GetEquippedRodId(): string
	local rodId = if player ~= nil then player:GetAttribute(GearConfig.PlayerAttributes.RodId) else nil
	if type(rodId) ~= "string" or RodConfig.Rods[rodId] == nil then
		return EconomyConfig.StartingRodId
	end
	return rodId
end

--- "RUSTY" / "BRASS" for the HUD line (§9).
function RodController:GetRodTierLabel(): string
	local rod = RodConfig.Rods[self:GetEquippedRodId()]
	return string.upper(rod.name:gsub(" Rod$", ""))
end

--- §5.4: the reason a cast is about to snap, ready for the HUD to print verbatim.
function RodController:GetMaxRarity(): string
	return RodConfig.Rods[self:GetEquippedRodId()].maxRarity
end

function RodController:GetRodConstants(): { [string]: any }
	return RodConfig.Rods[self:GetEquippedRodId()]
end

--- Swap the visible rod (§1 step 2 for the free Rusty Rod, §6.3 for the Brass Rod) and
--- hand the model to the character.
function RodController:SetEquippedRod(rodId: string)
	if RodConfig.Rods[rodId] == nil then
		return
	end
	self:UnequipRod()
	self:AttachToCharacter(rodId)
	local label = hud()
	if label ~= nil then
		label:SetRodLabel(("ROD: %s"):format(self:GetRodTierLabel()))
	end
end

--- Takes the rod out of the character's hands (the model only — the server still knows what the
--- player owns, so nothing about their stats changes).
function RodController:UnequipRod()
	local character = player.Character
	if character == nil then
		return
	end
	local existing = character:FindFirstChild(TOOL_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
	local backpack = player:FindFirstChild("Backpack")
	local stashed = if backpack ~= nil then backpack:FindFirstChild(TOOL_NAME) else nil
	if stashed ~= nil then
		stashed:Destroy()
	end
end

--- Builds the rod Tool for the equipped rod and equips it on the character. Safe to call on every
--- spawn — it destroys whatever it made last time.
function RodController:AttachToCharacter(rodId: string?)
	local character = player.Character
	if character == nil then
		return
	end
	local id = rodId or self:GetEquippedRodId()
	local look = ROD_LOOK[id] or ROD_LOOK[EconomyConfig.StartingRodId]

	self:UnequipRod()

	local tool = Instance.new("Tool")
	tool.Name = TOOL_NAME
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, look.length, 0.4)
	handle.Color = look.color
	handle.Material = look.material
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.CastShadow = false
	handle.Parent = tool

	local backpack = player:FindFirstChild("Backpack")
	if backpack ~= nil then
		tool.Parent = backpack
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			pcall(function()
				local grabbed = humanoid :: Humanoid
				grabbed:EquipTool(tool)
			end)
		end
	else
		tool.Parent = character
	end

	local label = hud()
	if label ~= nil then
		label:SetRodLabel(("ROD: %s"):format(self:GetRodTierLabel()))
	end
end

-- Knit lifecycle --------------------------------------------------------------

function RodController:KnitStart()
	if player ~= nil then
		player:GetAttributeChangedSignal(GearConfig.PlayerAttributes.RodId):Connect(function()
			self:SetEquippedRod(self:GetEquippedRodId())
		end)
	end

	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.wait(1)
		self:AttachToCharacter()
	end)

	if player.Character ~= nil then
		self:AttachToCharacter()
	end

	local label = hud()
	if label ~= nil then
		label:SetRodLabel(("ROD: %s"):format(self:GetRodTierLabel()))
	end
end

return RodController
