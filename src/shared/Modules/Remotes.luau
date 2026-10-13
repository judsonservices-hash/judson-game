--!strict
--[[
	Deep Tide — Remotes (remote/event definitions)
	Source: GDD Appendix B ("Key remotes (Remotes folder, CreateRemoteEvent)").
	PURE DATA + one accessor pair. No gameplay logic.

	Every client <-> server message in the game is declared here once, created by the
	server bootstrap, and fetched by name on either realm:

		local Remotes = require(game:GetService("ReplicatedStorage").DeepTide.Modules.Remotes)
		Remotes.get("CoinsChanged"):FireClient(player, coins)

	Payloads are documented per remote so the scripter and the UI designer agree on shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.ParentName = "DeepTide" -- ReplicatedStorage.DeepTide
Remotes.FolderName = "Remotes" -- ReplicatedStorage.DeepTide.Remotes

Remotes.Direction = {
	ClientToServer = "ClientToServer",
	ServerToClient = "ServerToClient",
}

Remotes.Definitions = {
	-- Client -> server requests
	CastRequest = {
		direction = Remotes.Direction.ClientToServer,
		payload = "fish instance (the client's chosen target within §5.1 cast range)",
		owner = "FishingService",
	},
	HookSetRequest = {
		direction = Remotes.Direction.ClientToServer,
		payload = "none (the server owns the hook-set window, §5.2)",
		owner = "FishingService",
	},
	FightInput = {
		direction = Remotes.Direction.ClientToServer,
		payload = "\"hold\" | \"release\" | \"abort\" (§5.3 input set)",
		owner = "FishingService",
	},
	ShopBuyRequest = {
		direction = Remotes.Direction.ClientToServer,
		payload = "sku id (EconomyConfig.ShopOrder members, §6.3)",
		owner = "ShopService",
	},

	-- Server -> client state
	FightStateChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ needle T, zone centre S, zone half-width W, hold meter H, tensionMax } @30 Hz (§5.3)",
		owner = "FishingService",
	},
	FightResolved = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ result = \"Landed\"|\"Escaped\"|\"Snapped\"|\"WeakLine\", speciesId, reason } (§5.3, §5.4)",
		owner = "FishingService",
	},
	CatchLogChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ entries = { Types.CatchLogEntry }, totalCoins } (§9)",
		owner = "InventoryService",
	},
	CoinsChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ coins, delta } (§9)",
		owner = "EconomyService",
	},
	ShopStateChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ skus = { { sku, cost, affordable, owned } }, coins } (§9)",
		owner = "ShopService",
	},
	DiveStateChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ air, airCapacity, depth, depthRating, exceeded } (§9)",
		owner = "DiveService",
	},
	ZoneChanged = {
		direction = Remotes.Direction.ServerToClient,
		payload = "zone id (\"Shallows\" | \"Shelf\") — drives the §9 entry banner",
		owner = "WorldService",
	},
	Notify = {
		direction = Remotes.Direction.ServerToClient,
		payload = "{ text, seconds } — the §9 2-second explainer line (FightConfig.FailMessages)",
		owner = "FishingService",
	},
}

-- Ordered list of every remote name (creation order is deterministic).
Remotes.Names = {
	"CastRequest",
	"HookSetRequest",
	"FightInput",
	"FightStateChanged",
	"FightResolved",
	"CatchLogChanged",
	"CoinsChanged",
	"ShopBuyRequest",
	"ShopStateChanged",
	"DiveStateChanged",
	"ZoneChanged",
	"Notify",
}

--- The ReplicatedStorage.DeepTide.Remotes folder.
--- Server: created on demand. Client: waited for (the server makes it at boot).
function Remotes.getFolder(): Folder
	local deepTide = ReplicatedStorage:WaitForChild(Remotes.ParentName)

	if RunService:IsServer() then
		local existing = deepTide:FindFirstChild(Remotes.FolderName)
		if existing ~= nil then
			return existing :: Folder
		end

		local created = Instance.new("Folder")
		created.Name = Remotes.FolderName
		created.Parent = deepTide
		return created
	end

	return deepTide:WaitForChild(Remotes.FolderName) :: Folder
end

--- Creates the folder and every RemoteEvent. Server only; called once by the bootstrap.
function Remotes.ensure(): Folder
	assert(RunService:IsServer(), "Remotes.ensure() must only be called on the server")

	local folder = Remotes.getFolder()
	for _, name in Remotes.Names do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	return folder
end

--- Fetch one remote by name. Waits on the client if the server has not created it yet.
function Remotes.get(name: string): RemoteEvent
	assert(Remotes.Definitions[name] ~= nil, ("Remotes.get: '%s' is not a declared remote"):format(name))
	return Remotes.getFolder():WaitForChild(name) :: RemoteEvent
end

return Remotes
