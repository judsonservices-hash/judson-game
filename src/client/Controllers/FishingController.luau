--!strict
--[[
	FishingController — GDD §5.1 (cast and its [E] CAST prompt), §5.2 (hook set), §5.3 (hold /
	release / abort input), §5.6 (cooldowns shown to the player), §9 (the in-fight prompt shows
	the same key as the cast prompt, plus the species name and rarity colour).

	Owns: local input and the client half of the Tension mini-game. The maths is
	server-authoritative at 30 Hz — this controller sends input and mirrors the state the
	server pushes. HudController draws the track from GetFightView().

	The feel hooks §5.3 asks for, and why they are here:
	  * the input is a *state*, sent on change only ("hold"/"release"), so a dropped or late
	    packet costs the player at most the time until their next input event, never the fight;
	  * the needle is dead-reckoned between server packets from the same FightConfig rates the
	    server uses, so input does not visibly lag the bar the player is watching;
	  * the strain is on screen the instant it happens: the hold meter changes colour out of zone,
	    and the needle turns red at the over-tension line.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local RarityConfig = require(ReplicatedStorage.DeepTide.Config.RarityConfig)
local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)

local FishingController = Knit.CreateController({
	Name = "FishingController",
})

-- Mirrors the server's FightStateChanged payload (§5.3): needle T, zone centre S, zone
-- half-width W, hold meter H, over-tension ceiling.
export type FightView = {
	needle: number,
	zoneCentre: number,
	zoneHalfWidth: number,
	hold: number,
	tensionMax: number,
	speciesId: string,
	name: string?,
	value: number?,
	rarity: string?,
	phase: string?,
	ring: number?,
	inZone: boolean?,
	overTension: boolean?,
}

local remotes: { [string]: RemoteEvent } = {}

local player = Players.LocalPlayer
local fightView: FightView? = nil
local serverView: FightView? = nil
local predictedZone = 0.5
local phase: string? = nil
local held = false
local currentTarget: BasePart? = nil
local promptTarget: BasePart? = nil
local lastScan = 0
local castLine: BasePart? = nil
local worldPrompt: BillboardGui? = nil
local cooldownUntil: { [string]: number } = {}

local CASTABLE_EXCLUDED: { [string]: boolean } = {
	Fleeing = true,
	Lunging = true,
	Hooked_Pending = true,
	Fighting = true,
}

local function hud(): any
	return Knit.GetController("HudController")
end

local function rod(): any
	return Knit.GetController("RodController")
end

local function character(): Model?
	return player.Character
end

local function rootPosition(): Vector3?
	local model = character()
	local root = if model ~= nil then model:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil then (root :: BasePart).Position else nil
end

local function rodTipPosition(): Vector3?
	local model = character()
	if model == nil then
		return nil
	end
	local tool = model:FindFirstChild("DeepTideRod")
	local handle = if tool ~= nil then tool:FindFirstChild("Handle") else nil
	if handle ~= nil then
		return (handle :: BasePart).Position
	end
	local hand = model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
	return if hand ~= nil then (hand :: BasePart).Position else rootPosition()
end

--- §5.1 step 1: the fish the player may cast at — nearest eligible fish within CastRange that is
--- in front of the camera. Uses the replicated `State` attribute (§4), so the prompt disappears
--- the moment the server says a fish is fleeing or already hooked.
local function scanForTarget(now: number): BasePart?
	if now - lastScan < 0.1 then
		return promptTarget
	end
	lastScan = now

	local origin = rootPosition()
	if origin == nil then
		return nil
	end
	local camera = workspace.CurrentCamera
	local look = if camera ~= nil then camera.CFrame.LookVector else nil

	local root = workspace:FindFirstChild("DeepTide")
	local folder = if root ~= nil then root:FindFirstChild("Fish") else nil
	if folder == nil or look == nil then
		promptTarget = nil
		return nil
	end

	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and not child.Name:match("_Lure$") then
			local part = child :: BasePart
			local state = part:GetAttribute("State")
			if CASTABLE_EXCLUDED[tostring(state)] ~= true then
				local offset = part.Position - origin
				local distance = offset.Magnitude
				if distance <= FightConfig.CastRange and distance < bestDistance and distance > 0 then
					local unit = offset / distance
					local dot = unit.X * look.X + unit.Y * look.Y + unit.Z * look.Z
					if dot >= FightConfig.CastFacingDot then
						best, bestDistance = part, distance
					end
				end
			end
		end
	end

	promptTarget = best
	return best
end

--- The `[E] CAST` prompt over the fish, with the species name and rarity colour (§9).
local function refreshPrompt(target: BasePart?)
	if hud() == nil then
		return
	end
	if target == nil then
		hud():HideCastPrompt()
		if worldPrompt ~= nil then
			worldPrompt.Enabled = false
		end
		return
	end

	local speciesId = tostring(target:GetAttribute("Species"))
	local species = FishConfig.Species[speciesId]
	local label = ("[%s] CAST — %s"):format(FightConfig.Keys.Cast, if species ~= nil then species.name else speciesId)
	local color = if species ~= nil then RarityConfig.Color[species.rarity] else nil

	hud():ShowCastPrompt(label, color)

	-- The world-anchored half: a plain, unstyled BillboardGui riding the fish (§9: a world
	-- prompt above the eligible fish).
	if worldPrompt == nil then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "DeepTideCastPrompt"
		billboard.Size = UDim2.fromScale(12, 3)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
		billboard.AlwaysOnTop = true
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.Code
		text.TextScaled = true
		text.TextColor3 = color or Color3.fromRGB(240, 240, 245)
		text.Text = label
		text.Parent = billboard
		worldPrompt = billboard
	end
	if worldPrompt ~= nil then
		worldPrompt.Adornee = target
		worldPrompt.Enabled = true
		local text = worldPrompt:FindFirstChild("Text")
		if text ~= nil then
			local textLabel = text :: TextLabel
			textLabel.Text = label
			textLabel.TextColor3 = color or Color3.fromRGB(240, 240, 245)
		end
	end
end

--- §5.1 step 2: the line from the rod tip to the fish. Plain Part, client-side, no replication.
local function updateCastLine(target: BasePart?)
	local tip = rodTipPosition()
	if target == nil or tip == nil then
		if castLine ~= nil then
			castLine.Transparency = 1
		end
		return
	end
	if castLine == nil or castLine.Parent == nil then
		local part = Instance.new("Part")
		part.Name = "DeepTideCastLine"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(220, 225, 235)
		part.Size = Vector3.new(0.12, 0.12, 1)
		part.Parent = workspace
		castLine = part
	end
	local line = castLine :: BasePart
	local targetPosition = target.Position
	local delta = targetPosition - tip
	local length = math.max(delta.Magnitude, 0.1)
	line.Size = Vector3.new(0.12, 0.12, length)
	line.CFrame = CFrame.lookAt(tip + delta / 2, targetPosition) * CFrame.Angles(math.rad(90), 0, 0)
	line.Transparency = 0
end

-- Public API ------------------------------------------------------------------

--- §5.1 step 2: ask the server to cast at the fish the player is aiming at.
--- The server validates range, facing and eligibility — this is a request, not a command.
function FishingController:RequestCast(target: BasePart?): boolean
	local remote = remotes.CastRequest
	if remote == nil then
		return false
	end
	remote:FireServer(target or promptTarget)
	return true
end

--- §5.2 step 6: the second press, inside the species' hook-set window.
function FishingController:RequestHookSet(): boolean
	local remote = remotes.HookSetRequest
	if remote == nil then
		return false
	end
	remote:FireServer()
	return true
end

--- §5.3: hold (E, left mouse or R2) to pull, release to slack. One button, nothing else.
--- The input is sent only when it changes, which is what makes a late packet harmless.
function FishingController:SetFightInput(next: boolean)
	if next == held then
		return
	end
	held = next
	local remote = remotes.FightInput
	if remote == nil then
		return
	end
	remote:FireServer(if next then "hold" else "release")
end

--- §5.3 step 10: abort at any time — a player must never feel trapped in the UI minigame.
function FishingController:AbortFight()
	held = false
	local remote = remotes.FightInput
	if remote == nil then
		return
	end
	remote:FireServer("abort")
end

--- Is a cast or fight in flight? (§5.6: drives the greyed rod and the countdown.)
function FishingController:IsBusy(): boolean
	return fightView ~= nil
end

--- The live fight view for the HUD track (§5.3), or nil when not fighting.
function FishingController:GetFightView(): FightView?
	return fightView
end

function FishingController:GetPhase(): string?
	return phase
end

--- §5.6: how long the current cooldown still has to run, for the HUD countdown.
function FishingController:GetCooldownRemaining(kind: string): number
	local until_ = cooldownUntil[kind]
	if until_ == nil then
		return 0
	end
	return math.max(0, until_ - os.clock())
end

--- §9: name + rarity colour for the prompt, so the player knows what they are casting at
--- BEFORE committing air.
function FishingController:GetSpeciesLabel(speciesId: string): { name: string, color: Color3 }
	local species = FishConfig.Species[speciesId]
	if species == nil then
		return { name = speciesId, color = Color3.fromRGB(240, 240, 245) }
	end
	return {
		name = species.name,
		color = RarityConfig.Color[species.rarity],
	}
end

--- §5.4 / §9: show the exact failure line — never a loss without a reason and a next step.
function FishingController:ShowFailure(result: Types.FightResult, reason: string?)
	local text = reason
	if text == nil then
		if result == "WeakLine" then
			text = FightConfig.FailMessages.weakLine
		elseif result == "Snapped" then
			text = FightConfig.FailMessages.snap
		elseif result == "Escaped" then
			text = FightConfig.FailMessages.escape
		end
	end
	if hud() ~= nil and text ~= nil then
		hud():ShowFailureMessage(text)
	end
end

-- Input -----------------------------------------------------------------------

--- One key does every verb (§1 step 5, §9): what it means depends on the phase the server has
--- told us we are in.
local function onPress()
	if phase == "Fighting" then
		FishingController:SetFightInput(true)
	elseif phase == "HookSet" then
		FishingController:RequestHookSet()
	elseif phase == "Casting" then
		-- the line is still going out; nothing to do
	else
		FishingController:RequestCast(promptTarget)
	end
end

local function onRelease()
	if phase == "Fighting" then
		FishingController:SetFightInput(false)
	end
end

-- Knit lifecycle --------------------------------------------------------------

function FishingController:KnitStart()
	for _, name in { "CastRequest", "HookSetRequest", "FightInput", "FightStateChanged", "FightResolved" } do
		remotes[name] = Remotes.get(name)
	end

	remotes.FightStateChanged.OnClientEvent:Connect(function(view: FightView)
		serverView = view
		phase = view.phase
		currentTarget = if view.phase == "Casting"
				or view.phase == "HookSet"
				or view.phase == "Fighting"
			then (promptTarget or currentTarget)
			else nil
		-- resync the dead-reckoned needle to the authority every packet (§5.3)
		if view.phase == "Fighting" then
			local predicted = {
				needle = view.needle,
				zoneCentre = view.zoneCentre,
				zoneHalfWidth = view.zoneHalfWidth,
				hold = view.hold,
				tensionMax = view.tensionMax,
				speciesId = view.speciesId,
				name = view.name,
				value = view.value,
				rarity = view.rarity,
				phase = view.phase,
				inZone = view.inZone,
				overTension = view.overTension,
			}
			predictedZone = view.zoneCentre
			fightView = predicted
			if hud() ~= nil then
				hud():ShowFight(predicted)
			end
		else
			fightView = nil
			if hud() ~= nil then
				hud():HideFight()
			end
		end
	end)

	remotes.FightResolved.OnClientEvent:Connect(function(payload: { result: Types.FightResult, reason: string? })
		fightView = nil
		serverView = nil
		phase = nil
		held = false
		currentTarget = nil
		if hud() ~= nil then
			hud():HideFight()
		end

		if payload.result == "Landed" then
			if hud() ~= nil and payload.reason ~= nil then
				hud():ShowCatchMessage(payload.reason)
			end
		else
			self:ShowFailure(payload.result, payload.reason)
			-- §5.6: the cooldown that follows each loss, for the countdown the HUD shows.
			local kind = if payload.result == "Snapped" or payload.result == "WeakLine" then "snap" else "escape"
			local total = FightConfig.Cooldowns[kind] or 0
			cooldownUntil[kind] = os.clock() + total
		end
	end)

	-- §5.1-§5.3: one key for cast, hook set and pull; mouse button 1 and gamepad R2 are the same
	-- pull. Q aborts.
	local ContextActionService = game:GetService("ContextActionService")
	ContextActionService:BindAction("DeepTideFish", function(_, inputState: Enum.UserInputState, _)
		if inputState == Enum.UserInputState.Begin then
			onPress()
		elseif inputState == Enum.UserInputState.End then
			onRelease()
		elseif inputState == Enum.UserInputState.Cancel then
			onRelease()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

	ContextActionService:BindAction("DeepTideAbort", function(_, inputState: Enum.UserInputState, _)
		if inputState == Enum.UserInputState.Begin then
			self:AbortFight()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Q)

	-- §5.1: the prompt, the line and the dead-reckoned needle, once a frame.
	RunService.RenderStepped:Connect(function(dt: number)
		if phase == nil then
			local target = scanForTarget(os.clock())
			refreshPrompt(target)
			currentTarget = nil
		else
			refreshPrompt(nil)
		end

		local tracked = currentTarget or promptTarget
		if phase == "Casting" or phase == "Fighting" then
			updateCastLine(if phase == "Casting" then tracked else nil)
		elseif castLine ~= nil then
			castLine.Transparency = 1
		end

		-- Dead-reckon the needle and ease the safe zone toward the server's value, so the bar the
		-- player is watching responds to their input this frame rather than 33 ms ago.
		if fightView ~= nil and phase == "Fighting" then
			local view = fightView :: FightView
			local rate = if held then FightConfig.NeedleRiseRate else -FightConfig.NeedleFallRate
			view.needle = math.clamp(view.needle + rate * dt, 0, view.tensionMax)
			if serverView ~= nil then
				predictedZone = predictedZone
					+ ((serverView :: FightView).zoneCentre - predictedZone) * math.min(1, dt * 10)
			end
			view.zoneCentre = predictedZone
			view.inZone = math.abs(view.needle - view.zoneCentre) <= view.zoneHalfWidth
			view.overTension = view.needle >= view.tensionMax - FightConfig.SnapBand
			if hud() ~= nil then
				hud():ShowFight(view)
			end
		end
	end)

	-- The rod the player is holding drives the HUD's `ROD:` line (§9) — RodController owns it.
	if rod() ~= nil then
		rod():AttachToCharacter()
	end
end

return FishingController
