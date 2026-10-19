--!strict
--[[
    Deep Tide — Types
    Source: GDD §4.2 (fish), §4.1 (rarity), §5.3 (fight outcomes), §6 (economy), §9 (catch log).
    Shared type vocabulary. Data only — every runtime lookup goes through Modules/Configs.
]]

export type RarityName = "Common" | "Uncommon" | "Rare" | "Epic"
export type SpeciesId = "SilverSardine" | "SunsetGrouper" | "ReefBass" | "LanternEel" | "GhostRay"
export type ZoneId = "Shallows" | "Shelf"
export type RodId = "RustyRod" | "BrassRod"
export type GearId = "RubberLungs" | "ReinforcedTank"
export type BehaviourType = "School" | "Patrol" | "Flee" | "Ambush"

-- Fish lifecycle. "Hooked_Pending" is the GDD's name for a fish that is hooked but
-- whose hook-set window is still open (§5.1 step 3); the rest of the state machine is
-- the gameplay scripter's to define in FishService.
export type FishState = string

-- Outcomes of the Tension mini-game (§5.3, §5.4).
export type FightResult = "Landed" | "Escaped" | "Snapped" | "WeakLine"

export type MiniGameConfig = {
	zoneHalfWidth: number,
	zoneHz: number,
	zoneAmp: number,
	fillRate: number,
	requiredTension: number,
	hookWindow: number,
}

export type SpeciesConfig = {
	id: SpeciesId,
	name: string,
	rarity: RarityName,
	value: number,
	depthBand: { number },
	zone: ZoneId,
	behaviour: BehaviourType,
	liveAtStart: number,
	parts: number,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	transparency: number,
	visualCue: string,
	mini: MiniGameConfig,
	behaviourCfg: { [string]: any },
}

export type RodConfigEntry = {
	id: RodId,
	name: string,
	tier: number,
	cost: number,
	maxRarity: RarityName,
	lineStrength: number,
	zoneWidthMult: number,
	strainMult: number,
	fillMult: number,
}

export type GearConfigEntry = {
	id: GearId,
	name: string,
	tier: number,
	cost: number,
	airCapacity: number,
	depthRating: number,
}

-- One row of the Catch Log (§9): everything caught and not yet sold.
export type CatchLogEntry = {
	speciesId: SpeciesId,
	name: string,
	rarity: RarityName,
	value: number,
	count: number,
}

-- Result of SELL ALL (§6.2).
export type SellAllResult = {
	soldCount: number,
	coinsEarned: number,
	newBalance: number,
}

-- What persists per player (Modules/PlayerStore, PlayerService).
export type PlayerData = {
	schemaVersion: number,
	coins: number,
	catchLog: { CatchLogEntry },
	equippedRodId: RodId,
	equippedGearId: GearId,
}

-- Live dive readout (§9): `AIR 100s`, `DEPTH 62m`, `RATING 90m`, `GEAR RATING EXCEEDED`.
export type DiveState = {
	air: number,
	airCapacity: number,
	depth: number,
	depthRating: number,
	exceeded: boolean,
	submerged: boolean,
}

-- One shop row as the client renders it (§9: sticky cost-vs-cash comparison).
export type ShopSkuState = {
	sku: string,
	name: string,
	category: string,
	cost: number,
	affordable: boolean,
	owned: boolean,
	recommended: boolean,
	unlockLabel: string,
	-- How far short of the price the player is (§9: "grey with C 150 / 280 shown when not").
	-- 0 when the row is affordable.
	shortfall: number,
	-- The measurable effect, built from RodConfig/GearConfig at read time (§6.3: the tank is
	-- the key to depth, and the row has to say so with real numbers).
	effectLabel: string,
}

export type ShopState = {
	coins: number,
	skus: { ShopSkuState },
}

-- The §9 explainer line: "never a loss without a reason and a next step".
export type NotifyPayload = {
	text: string,
	seconds: number,
}

return {}
