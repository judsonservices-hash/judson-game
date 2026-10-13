--!strict
--[[
	ShopController — GDD §1 step 8 (`E — Trade` at the Tide Trader stall opens the shop),
	§6.2 (SELL ALL converts the Catch Log to Coins at the table prices), §6.3 (the three SKUs
	and the presentation order), §6.6 (one disabled second tab, no Robux anywhere),
	§9 (sticky cost-vs-cash comparison on every row, `[E] TRADE` world prompt).

	Presentation only: every price and every permission comes from the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local ShopController = Knit.CreateController({
	Name = "ShopController",
})

local remotes: { [string]: RemoteEvent } = {}
local shopState: Types.ShopState = {
	coins = EconomyConfig.StartingCoins,
	skus = {},
}
local isOpen = false

-- Public API ------------------------------------------------------------------

--- §1 step 8: open the shop UI. The server state arrives on ShopStateChanged.
function ShopController:Open()
	isOpen = true
	-- TODO(§9): render the panel — Reinforced Tank first and flagged recommended
	-- (EconomyConfig.ShopOrder[1]), Brass Rod below it with its unlock label, and the
	-- disabled second tab from EconomyConfig.DisabledShopTab.
end

function ShopController:Close()
	isOpen = false
end

function ShopController:IsOpen(): boolean
	return isOpen
end

--- The last state the server pushed (§9: `280 C` in green when affordable, grey with
--- `C 150 / 280` shown when not).
function ShopController:GetState(): Types.ShopState
	return shopState
end

--- §6.2: SELL ALL. The server pays Σ(value x count) and clears the log.
function ShopController:SellAll()
	-- TODO(§6.2): route through the server — selling is authoritative. A ShopSellAllRequest
	-- remote is not in Appendix B's list; reuse the shop's server surface (ShopService:SellAll
	-- via Knit Comm) and fire CoinsChanged + CatchLogChanged back.
end

--- §6.3: buy a SKU. Never a purchase button that silently does nothing.
function ShopController:RequestPurchase(sku: string): boolean
	local remote = remotes.ShopBuyRequest
	if remote == nil then
		return false
	end
	remote:FireServer(sku)
	return true
end

--- A row's own label, ready to print: `280 C`, or `C 150 / 280` when unaffordable (§9).
function ShopController:FormatPrice(sku: Types.ShopSkuState): string
	if sku.affordable then
		return ("%d C"):format(sku.cost)
	end
	return ("C %d / %d"):format(shopState.coins, sku.cost)
end

-- Knit lifecycle --------------------------------------------------------------

function ShopController:KnitStart()
	for _, name in { "ShopBuyRequest", "ShopStateChanged", "CoinsChanged" } do
		remotes[name] = Remotes.get(name)
	end

	remotes.ShopStateChanged.OnClientEvent:Connect(function(state: Types.ShopState)
		shopState = state
		-- TODO(§9): redraw every row's affordability; keep the comparison sticky.
	end)

	-- TODO(§1 step 8): show the `[E] TRADE` ProximityPrompt on Workspace.DeepTide.Spawns
	-- TideTrader and call Open() on trigger; Tab/Escape closes.
end

return ShopController
