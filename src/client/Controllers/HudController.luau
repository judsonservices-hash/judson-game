--!strict
--[[
	HudController — GDD §9 (HUD requirements), §1 step 6 (Catch Log row appears the instant a
	fish lands), §9 (cash, rod, catch log, failure explainer, zone banner).

	Owns the always-visible readouts EXCEPT air/depth/rating (DepthController owns those, so
	the alarm and the vignette live in exactly one place):
	  * cash `C 295` top-right, changes animate
	  * Catch Log panel, collapsible with Tab, running TOTAL
	  * `ROD: RUSTY` readout
	  * the 2 s failure explainer line
	  * the zone entry banner
	Explicitly NOT here (§9): minimap, quest log, XP bar, leaderboard, friend list,
	Robux button, settings cog, any social feature.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)

local HudController = Knit.CreateController {
	Name = "HudController",
}

local player = Players.LocalPlayer

-- Public API ------------------------------------------------------------------

--- §9: top-right cash, animating the delta into the counter so income is felt.
function HudController:SetCoins(coins: number, delta: number?)
	-- TODO(§9): animate the delta into the counter — no Coin change may ever be silent.
end

--- §9: the Catch Log panel — species, rarity colour, count, running TOTAL.
function HudController:SetCatchLog(entries: { Types.CatchLogEntry })
	-- TODO(§9): rebuild the rows, using RarityConfig.Color for each row's rarity colour.
end

--- §9: `ROD: RUSTY / BRASS`.
function HudController:SetRodLabel(label: string) end

--- §9: the centred explainer line, verbatim from FightConfig.FailMessages, shown for
--- FightConfig.FailureMessageSeconds. Never a loss without a reason and a next step.
function HudController:ShowFailureMessage(text: string) end

--- §9: `THE SHALLOWS` / `THE SHELF`, top-centre, ZoneConfig.ZoneEntryBannerSeconds, fading.
function HudController:ShowZoneBanner(zoneId: string)
	local zone = ZoneConfig.Zones[zoneId]
	if zone == nil then
		return
	end
	-- TODO(§9): show zone.displayName for ZoneConfig.ZoneEntryBannerSeconds.
end

--- §9: the first-session tutorial prompts (5, one at a time, dismissible, never repeating).
function HudController:ShowTutorialPrompt(index: number) end

--- §9: collapse/expand the Catch Log with Tab.
function HudController:ToggleCatchLog() end

--- The `TOTAL 295 C` under the log. Display only — EconomyService owns the real payment.
function HudController:ComputeTotalCoins(entries: { Types.CatchLogEntry }): number
	local total = 0
	for _, entry in entries do
		local value = EconomyConfig.SellValues[entry.speciesId]
		if value ~= nil then
			total += value * entry.count
		end
	end
	return total
end

-- Knit lifecycle --------------------------------------------------------------

function HudController:KnitStart()
	-- TODO(§9): first build the ScreenGui under PlayerGui (above the world, below the
	-- tension track), then the following wiring is what keeps it true.

	Remotes.get("CoinsChanged").OnClientEvent:Connect(function(coins: number, delta: number?)
		self:SetCoins(coins, delta)
	end)

	Remotes.get("CatchLogChanged").OnClientEvent:Connect(function(entries: { Types.CatchLogEntry })
		self:SetCatchLog(entries)
	end)

	Remotes.get("Notify").OnClientEvent:Connect(function(payload: Types.NotifyPayload)
		self:ShowFailureMessage(payload.text)
	end)

	Remotes.get("ZoneChanged").OnClientEvent:Connect(function(zoneId: string)
		self:ShowZoneBanner(zoneId)
	end)

	-- EconomyConfig.StartingCoins seeds the very first draw so the HUD is never blank.
	local _startingCoins = EconomyConfig.StartingCoins
end

return HudController
