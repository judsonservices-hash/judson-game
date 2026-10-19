--[[
	Deep Tide — headless mock DataStoreService for the dock economy suite.

	Same trick as persist_setup.luau: a DataStore the suite can read back, so the "coins and
	purchases survive a rejoin" assertion drives the real PlayerStore/PlayerService path
	(join -> mutate -> leave -> save -> join -> load) instead of a copy of it. `FAKE` stays in
	scope for the assertions half.
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
	GetDataStore = function(_, _name)
		return storeObj
	end,
}
