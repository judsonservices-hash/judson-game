--!strict
--[[
    HudController — GDD §9 (HUD requirements), §1 step 6 (Catch Log row appears the instant a
    fish lands), §9 (cash, rod, catch log, failure explainer, zone banner), §5.3 (the tension
    track: safe zone, needle, red over-tension line, hold meter).

    Owns the always-visible readouts EXCEPT air/depth/rating (DepthController owns those, so
    the alarm and the vignette live in exactly one place):
      * cash `C 295` top-right
      * Catch Log panel, collapsible with Tab, running TOTAL
      * `ROD: RUSTY` readout
      * the 2 s explainer line (failure and catch)
      * the zone entry banner
      * the §5.3 tension track, cast prompt and catch prompt

    Explicitly NOT here (§9): minimap, quest log, XP bar, leaderboard, friend list,
    Robux button, settings cog, any social feature.

    STYLING IS NOT DONE HERE. Every element is a plain, unstyled Frame/TextLabel with a visible
    background, sized from FightConfig (§5.3's 360 px track at 45% screen height) so the loop is
    playable and the UI/UX designer can restyle it without moving a single number.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local RarityConfig = require(ReplicatedStorage.DeepTide.Config.RarityConfig)

local HudController = Knit.CreateController({
	Name = "HudController",
})

local player = Players.LocalPlayer

local gui: ScreenGui? = nil
local coinsLabel: TextLabel? = nil
local rodLabel: TextLabel? = nil
local logPanel: Frame? = nil
local logList: Frame? = nil
local logTotal: TextLabel? = nil
local messageLabel: TextLabel? = nil
local bannerLabel: TextLabel? = nil
local castLabel: TextLabel? = nil
local track: Frame? = nil
local zoneBand: Frame? = nil
local needle: Frame? = nil
local limitLine: Frame? = nil
local holdFill: Frame? = nil
local fightLabel: TextLabel? = nil
local messageToken = 0
local bannerToken = 0

local function newFrame(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

local function newLabel(parent: Instance, name: string, size: UDim2, position: UDim2, text: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.Position = position
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextScaled = false
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(240, 240, 245)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = parent
	return label
end

--- §9/§5.3: the whole HUD tree. Plain Frames, no styling: the UI/UX pass restyles this.
local function buildGui(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "DeepTideHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.Parent = player:WaitForChild("PlayerGui")

	coinsLabel = newLabel(screen, "Coins", UDim2.fromOffset(180, 28), UDim2.new(1, -190, 0, 12), "C 0")

	rodLabel = newLabel(screen, "Rod", UDim2.fromOffset(240, 24), UDim2.new(1, -250, 0, 44), "ROD: RUSTY")

	-- §9: the cast prompt sits above the track and names the fish and its rarity colour, so the
	-- player knows what they are casting at before committing air.
	castLabel = newLabel(screen, "CastPrompt", UDim2.fromOffset(420, 26), UDim2.new(0.5, -210, 0.72, 0), "[E] CAST")
	castLabel.TextXAlignment = Enum.TextXAlignment.Center
	castLabel.Visible = false

	-- §5.3: track 360 px wide at 45% screen height.
	local trackWidth = FightConfig.TrackWidthPixels
	track = newFrame(
		screen,
		"TensionTrack",
		UDim2.fromOffset(trackWidth, 20),
		UDim2.new(0.5, -trackWidth / 2, FightConfig.TrackScreenHeightFraction, 0),
		Color3.fromRGB(20, 22, 28)
	)
	zoneBand =
		newFrame(track, "SafeZone", UDim2.fromOffset(10, 20), UDim2.fromOffset(0, 0), Color3.fromRGB(40, 200, 90))
	needle = newFrame(track, "Needle", UDim2.fromOffset(3, 24), UDim2.fromOffset(0, -2), Color3.fromRGB(245, 245, 250))
	limitLine = newFrame(
		track,
		"OverTensionLine",
		UDim2.fromOffset(2, 24),
		UDim2.fromOffset(trackWidth - 2, -2),
		Color3.fromRGB(230, 60, 60)
	)
	holdFill = newFrame(
		screen,
		"HoldMeter",
		UDim2.fromOffset(0, 8),
		UDim2.new(0.5, -trackWidth / 2, FightConfig.TrackScreenHeightFraction, 26),
		Color3.fromRGB(90, 200, 255)
	)
	fightLabel = newLabel(
		screen,
		"FightStake",
		UDim2.fromOffset(300, 22),
		UDim2.new(0.5, -150, FightConfig.TrackScreenHeightFraction, 40),
		""
	)
	fightLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- §9: the explainer line. Wide enough for the longest line the server can push — the §5.4
	-- rating wall prints the player's own rating *and* the tier that opens the deeper water
	-- ("GEAR RATING EXCEEDED — RATING 90m — SURFACED · REINFORCED TANK 240m (280 C)").
	messageLabel = newLabel(screen, "Message", UDim2.fromOffset(1040, 30), UDim2.new(0.5, -520, 0.38, 0), "")
	messageLabel.TextSize = 16
	messageLabel.TextXAlignment = Enum.TextXAlignment.Center
	messageLabel.Visible = false

	bannerLabel = newLabel(screen, "ZoneBanner", UDim2.fromOffset(420, 34), UDim2.new(0.5, -210, 0.06, 0), "")
	bannerLabel.TextXAlignment = Enum.TextXAlignment.Center
	bannerLabel.Visible = false

	-- §9: the Catch Log panel — species, rarity colour, count, running TOTAL.
	logPanel =
		newFrame(screen, "CatchLog", UDim2.fromOffset(250, 200), UDim2.new(1, -260, 0, 80), Color3.fromRGB(16, 18, 24))
	logList = newFrame(logPanel, "Rows", UDim2.new(1, -10, 1, -40), UDim2.fromOffset(5, 5), Color3.fromRGB(16, 18, 24))
	logTotal = newLabel(logPanel, "Total", UDim2.fromOffset(240, 24), UDim2.new(0, 5, 1, -30), "TOTAL 0 C")

	track.Visible = false
	holdFill.Visible = false
	fightLabel.Visible = false

	return screen
end

local function showMessage(text: string, color: Color3, seconds: number)
	if messageLabel == nil then
		return
	end
	messageToken += 1
	local token = messageToken
	messageLabel.Text = text
	messageLabel.TextColor3 = color
	messageLabel.Visible = true
	task.delay(seconds, function()
		if messageToken == token and messageLabel ~= nil then
			messageLabel.Visible = false
		end
	end)
end

-- Public API ------------------------------------------------------------------

--- §9: top-right cash. (The fly-in animation is the UI pass; the value is never silent.)
function HudController:SetCoins(coins: number, delta: number?)
	if coinsLabel == nil then
		return
	end
	if delta ~= nil and delta ~= 0 then
		coinsLabel.Text = ("C %d  (%+d)"):format(coins, delta)
	else
		coinsLabel.Text = ("C %d"):format(coins)
	end
end

--- §9: the Catch Log panel — species, rarity colour, count, running TOTAL.
function HudController:SetCatchLog(entries: { Types.CatchLogEntry }, totalCoins: number?)
	if logList == nil or logTotal == nil then
		return
	end
	for _, child in logList:GetChildren() do
		child:Destroy()
	end

	local index = 0
	for _, entry in entries do
		local row = newLabel(
			logList,
			"Row_" .. entry.speciesId,
			UDim2.new(1, 0, 0, 20),
			UDim2.fromOffset(0, index * 22),
			("%s  x%d"):format(entry.name, entry.count)
		)
		row.TextColor3 = RarityConfig.Color[entry.rarity] or Color3.fromRGB(240, 240, 245)
		row.BackgroundTransparency = 1
		index += 1
	end

	local total = if totalCoins ~= nil then totalCoins else self:ComputeTotalCoins(entries)
	logTotal.Text = ("TOTAL %d C"):format(total)
end

--- §9: `ROD: RUSTY / BRASS`.
function HudController:SetRodLabel(label: string)
	if rodLabel ~= nil then
		rodLabel.Text = label
	end
end

--- §9: the centred explainer line, verbatim from FightConfig.FailMessages, shown for
--- FightConfig.FailureMessageSeconds. Never a loss without a reason and a next step.
function HudController:ShowFailureMessage(text: string)
	showMessage(text, Color3.fromRGB(255, 120, 120), FightConfig.FailureMessageSeconds)
end

--- §1 step 6: the landed-fish line (the server formats it from FightConfig.CatchMessageFormat).
function HudController:ShowCatchMessage(text: string)
	showMessage(text, Color3.fromRGB(255, 214, 120), FightConfig.CatchMessageSeconds)
end

--- §9: `THE SHALLOWS` / `THE SHELF`, top-centre, ZoneConfig.ZoneEntryBannerSeconds, fading.
function HudController:ShowZoneBanner(zoneId: string)
	local zone = ZoneConfig.Zones[zoneId]
	if zone == nil or bannerLabel == nil then
		return
	end
	bannerToken += 1
	local token = bannerToken
	bannerLabel.Text = zone.displayName
	bannerLabel.Visible = true
	task.delay(ZoneConfig.ZoneEntryBannerSeconds, function()
		if bannerToken == token and bannerLabel ~= nil then
			bannerLabel.Visible = false
		end
	end)
end

--- §5.1 step 1 / §9: the `[E] CAST` prompt naming the fish and its rarity colour.
function HudController:ShowCastPrompt(text: string, color: Color3?)
	if castLabel == nil then
		return
	end
	castLabel.Text = text
	castLabel.TextColor3 = color or Color3.fromRGB(240, 240, 245)
	castLabel.Visible = true
end

function HudController:HideCastPrompt()
	if castLabel ~= nil then
		castLabel.Visible = false
	end
end

--- §5.3: draw the track from the fight view, in track fractions (the maths is the server's).
function HudController:ShowFight(view: { [string]: any })
	if track == nil or zoneBand == nil or needle == nil or holdFill == nil or limitLine == nil then
		return
	end
	local trackWidth = FightConfig.TrackWidthPixels
	local width = math.clamp((view.zoneHalfWidth or 0) * 2, 0, 1)
	local centre = math.clamp(view.zoneCentre or 0.5, 0, 1)

	track.Visible = true
	holdFill.Visible = true
	zoneBand.Size = UDim2.fromOffset(math.max(4, width * trackWidth), 20)
	zoneBand.Position = UDim2.fromOffset((centre - width / 2) * trackWidth, 0)
	needle.Position = UDim2.fromOffset(math.clamp(view.needle or 0, 0, 1) * trackWidth - 1.5, -2)

	local overTension = view.overTension == true or (view.needle or 0) >= (view.tensionMax or 1) - FightConfig.SnapBand
	needle.BackgroundColor3 = if overTension then Color3.fromRGB(255, 90, 90) else Color3.fromRGB(245, 245, 250)
	limitLine.Position = UDim2.fromOffset(math.clamp(view.tensionMax or 1, 0, 1) * trackWidth - 1, -2)

	local hold = math.clamp((view.hold or 0) / FightConfig.HoldMeterMax, 0, 1)
	holdFill.Size = UDim2.fromOffset(math.max(1, hold * trackWidth), 8)
	-- Clear feedback on strain (§5.3 step 5): the meter changes colour the moment the needle
	-- leaves the green, and deepens the further out it is.
	holdFill.BackgroundColor3 = if view.inZone == false
		then (if (view.hold or 0) < FightConfig.HoldMeterMax / 3
			then Color3.fromRGB(255, 90, 90)
			else Color3.fromRGB(255, 170, 60))
		else Color3.fromRGB(90, 200, 255)

	if view.name ~= nil then
		fightLabel.Visible = true
		fightLabel.Text = ("%s — %d C"):format(view.name, view.value or 0)
		fightLabel.TextColor3 = RarityConfig.Color[view.rarity] or Color3.fromRGB(240, 240, 245)
	end
end

function HudController:HideFight()
	if track ~= nil then
		track.Visible = false
	end
	if holdFill ~= nil then
		holdFill.Visible = false
	end
	if fightLabel ~= nil then
		fightLabel.Visible = false
	end
end

--- §9: the first-session tutorial prompts (5, one at a time, dismissible, never repeating).
function HudController:ShowTutorialPrompt(index: number)
	showMessage(("TIP %d/%d"):format(index, 5), Color3.fromRGB(200, 220, 255), FightConfig.FailureMessageSeconds)
end

--- §9: collapse/expand the Catch Log with Tab.
function HudController:ToggleCatchLog()
	if logPanel ~= nil then
		logPanel.Visible = not logPanel.Visible
	end
end

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
	-- §9: first build the ScreenGui under PlayerGui (above the world, below the tension track),
	-- then the following wiring is what keeps it true.
	if player ~= nil then
		gui = buildGui()
	end

	Remotes.get("CoinsChanged").OnClientEvent:Connect(function(coins: number, delta: number?)
		self:SetCoins(coins, delta)
	end)

	Remotes.get("CatchLogChanged").OnClientEvent:Connect(function(entries: { Types.CatchLogEntry }, totalCoins: number?)
		self:SetCatchLog(entries, totalCoins)
	end)

	Remotes.get("Notify").OnClientEvent:Connect(function(payload: Types.NotifyPayload)
		self:ShowFailureMessage(payload.text)
	end)

	Remotes.get("ZoneChanged").OnClientEvent:Connect(function(zoneId: string)
		self:ShowZoneBanner(zoneId)
	end)

	-- EconomyConfig.StartingCoins seeds the very first draw so the HUD is never blank.
	self:SetCoins(EconomyConfig.StartingCoins)

	-- §9: Tab collapses the Catch Log.
	local UserInputService = game:GetService("UserInputService")
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Tab then
			self:ToggleCatchLog()
		end
	end)
end

return HudController
