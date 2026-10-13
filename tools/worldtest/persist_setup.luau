--[[
	Deep Tide — headless persistence test, setup half.

	Runs after the globals stub and the real config sources, before PlayerStore/PlayerService
	are loaded. It installs a mock DataStoreService (that can be switched to "API access off"),
	a mock Players service with real signals, a mock Knit.GetService, and a fake script tree so
	PlayerService's sibling-release sweep has something to walk.
]]

local FAKE = { saved = {}, fail = false }

local storeObj = {}
function storeObj:GetAsync(key)
	if FAKE.fail then
		error("Studio API access is off")
	end
	return FAKE.saved[key]
end
function storeObj:SetAsync(key, value)
	if FAKE.fail then
		error("Studio API access is off")
	end
	FAKE.saved[key] = value
end
SERVICES.DataStoreService = {
	GetDataStore = function(_, name)
		return storeObj
	end,
}

local function newSignal()
	local signal = { handlers = {} }
	function signal:Connect(fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	function signal:Fire(...)
		for _, fn in ipairs(self.handlers) do
			fn(...)
		end
	end
	return signal
end

local playersService = makeInstance("Players")
playersService.PlayerAdded = newSignal()
playersService.PlayerRemoving = newSignal()
playersService.GetPlayers = function()
	return {}
end
SERVICES.Players = playersService

local BIND_TO_CLOSE = nil
game.BindToClose = function(_, fn)
	BIND_TO_CLOSE = fn
end

local releasedPlayers = {}
SIBLING_SERVICES.GearService = {
	ReleasePlayer = function(_, player)
		table.insert(releasedPlayers, player.Name)
	end,
}
__KnitStub.GetService = function(name)
	local service = SIBLING_SERVICES[name]
	if service == nil then
		error("service not found: " .. tostring(name))
	end
	return service
end

-- The `script` tree PlayerService walks: Services/{PlayerService, GearService}.
local servicesFolder = makeInstance("Folder")
servicesFolder.Name = "Services"
script = makeInstance("ModuleScript")
script.Name = "PlayerService"
script.Parent = servicesFolder
local siblingModule = makeInstance("ModuleScript")
siblingModule.Name = "GearService"
siblingModule.Parent = servicesFolder
