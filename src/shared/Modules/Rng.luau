--!strict
--[[
	Deep Tide — Rng (deterministic pseudo-random numbers)

	Source: GDD §4.3 (the behaviour specs are full of "random" values: anchor random walks,
	orbit phase offsets, jitter, waypoint scatter) and §4.5 (respawn/despawn timers).

	Why this exists: fish behaviour has to be *reproducible*. A run with the same seed must
	produce the same swim, the same fights and the same outcomes twice, so the loop can be
	tested headlessly (tools/worldtest) and so a bug can be replayed instead of guessed at.
	`math.random` cannot do that — it is global and shared with every other caller.

	A small 32-bit LCG (Numerical Recipes constants). Exact in a double, no bit library needed,
	and the same sequence in Studio, in the Luau CLI and on any server.
]]

local Rng = {}
Rng.__index = Rng

local MODULUS = 4294967296 -- 2^32
local MULTIPLIER = 1664525
local INCREMENT = 1013904223

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

--- A generator from `seed`. Any integer works; 0 is folded to 1 so the sequence never sticks.
function Rng.new(seed: number?): Rng
	local state = math.floor(math.abs(seed or 1)) % MODULUS
	if state <= 0 then
		state = 1
	end
	return setmetatable({ state = state }, Rng)
end

--- Uniform in [0, 1).
function Rng:nextUnit(): number
	self.state = (self.state * MULTIPLIER + INCREMENT) % MODULUS
	return self.state / MODULUS
end

--- Uniform in [min, max).
function Rng:range(min: number, max: number): number
	return min + (max - min) * self:nextUnit()
end

--- Uniform integer in [min, max], inclusive on both ends.
function Rng:integer(min: number, max: number): number
	if max <= min then
		return min
	end
	return min + math.floor(self:nextUnit() * (max - min + 1) - 1e-9) :: number
end

--- -1 or 1.
function Rng:sign(): number
	return if self:nextUnit() < 0.5 then -1 else 1
end

--- One element of a list, or nil for an empty list.
function Rng:pick<T>(list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[self:integer(1, #list)]
end

--- A point inside a sphere of `radius` (uniform by volume), offset from `centre`.
function Rng:insideSphere(centre: Vector3, radius: number): Vector3
	local z = self:range(-1, 1)
	local theta = self:range(0, 2 * math.pi)
	local r = radius * (self:nextUnit() ^ (1 / 3))
	local planar = math.sqrt(math.max(0, 1 - z * z))
	return centre + Vector3.new(r * planar * math.cos(theta), r * z, r * planar * math.sin(theta))
end

--- A unit direction. Used for flee/lunge headings, which the GDD gives as "away from the
--- player" — a real direction only needs to be deterministic when the fish has no player.
function Rng:unitVector(): Vector3
	local z = self:range(-1, 1)
	local theta = self:range(0, 2 * math.pi)
	local planar = math.sqrt(math.max(0, 1 - z * z))
	return Vector3.new(planar * math.cos(theta), z, planar * math.sin(theta))
end

--- The next integer a fresh generator from this seed would use — for logging a run so it can
--- be replayed.
function Rng:getState(): number
	return self.state
end

return Rng
