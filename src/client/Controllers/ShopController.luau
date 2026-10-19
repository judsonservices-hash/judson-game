--!strict
--[[
	ShopController — GDD §1 step 8 (`E — Trade` at the Tide Trader stall opens the shop),
	§6.2 (SELL ALL converts the Catch Log to Coins at the table prices), §6.3 (the three SKUs
	and the presentation order), §6.6 (one disabled second tab, no Robux anywhere),
	§9 (sticky cost-vs-cash comparison on every row, shortfall shown on a disabled row,
	`[E] TRADE` world prompt).

	Presentation only: every price, permission and payload comes from the server. The panel is
	plain unstyled Frames and TextButtons so the loop is playable now and the UI/UX pass can
	restyle it without re-deriving a single number.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

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
local panel: Frame? = nil
local coinsLabel: TextLabel? = nil
local rowsFrame: Frame? = nil

-- Plain UI helpers -------------------------------------------------------------

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
	label.BackgroundTransparency = 0.4
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(240, 240, 245)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = parent
	return label
end

local function newButton(parent: Instance, name: string, size: UDim2, position: UDim2, text: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = Color3.fromRGB(40, 44, 52)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.Code
	button.TextSize = 16
	button.TextColor3 = Color3.fromRGB(240, 240, 245)
	button.Text = text
	button.Parent = parent
	return button
end

--- §9: is a row's price affordable, greyed with its shortfall, or already held?
function ShopController:FormatPrice(sku: Types.ShopSkuState): string
	if sku.owned then
		return EconomyConfig.ShopRowLabel.ownedFormat
	end
	if sku.affordable then
		return EconomyConfig.ShopRowLabel.affordableFormat:format(sku.cost)
	end
	return EconomyConfig.ShopRowLabel.shortfallFormat:format(sku.cost, sku.shortfall)
end

--- §6.3/§6.6: the header — cash, plus the layout slot the eventual second tab keeps open.
function ShopController:GetTabsLabel(): string
	local disabled = EconomyConfig.DisabledShopTab
	return ("%s   %s"):format("TIDE TRADER", if disabled ~= nil then disabled.label else "—")
end

-- Rendering --------------------------------------------------------------------

local function buildPanel(): Frame
	local player = game:GetService("Players").LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "DeepTideShop"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.Parent = playerGui

	local built =
		newFrame(screen, "Panel", UDim2.fromOffset(520, 360), UDim2.new(0.5, -260, 0.2, 0), Color3.fromRGB(14, 16, 22))
	coinsLabel = newLabel(built, "Header", UDim2.fromOffset(500, 22), UDim2.fromOffset(10, 8), "")
	rowsFrame =
		newFrame(built, "Rows", UDim2.new(1, -20, 1, -110), UDim2.fromOffset(10, 34), Color3.fromRGB(14, 16, 22))

	-- §6.2: SELL ALL lives in the same panel as the shop — §1 step 8 opens the stall, and the
	-- catch is turned into Coins at the same counter the upgrade is bought from.
	local sellAll = newButton(built, "SellAll", UDim2.fromOffset(240, 34), UDim2.fromOffset(10, 310), "SELL ALL")
	sellAll.Activated:Connect(function()
		ShopController:SellAll()
	end)

	local close = newButton(built, "Close", UDim2.fromOffset(120, 34), UDim2.fromOffset(260, 310), "CLOSE")
	close.Activated:Connect(function()
		ShopController:Close()
	end)

	-- §6.6: one disabled tab, no MarketplaceService call anywhere in the slice.
	local disabledTab = newButton(
		built,
		"DisabledTab",
		UDim2.fromOffset(60, 22),
		UDim2.fromOffset(440, 8),
		if EconomyConfig.DisabledShopTab ~= nil then EconomyConfig.DisabledShopTab.label else "—"
	)
	disabledTab.Active = false
	disabledTab.AutoButtonColor = false
	disabledTab.TextColor3 = Color3.fromRGB(120, 120, 130)

	return built
end

--- §9: redraw every row from the server's payload — name, effect, sticky cost-vs-cash, and the
--- recommended flag on the tank (§6.3/§6.5's ordering).
function ShopController:Render()
	if rowsFrame == nil then
		return
	end
	for _, child in rowsFrame:GetChildren() do
		child:Destroy()
	end
	if coinsLabel ~= nil then
		coinsLabel.Text = ("%s   C %d"):format(self:GetTabsLabel(), shopState.coins)
	end

	local index = 0
	for _, sku in shopState.skus do
		local top = index * 66
		local row = newFrame(
			rowsFrame,
			"Row_" .. sku.sku,
			UDim2.new(1, -10, 0, 60),
			UDim2.fromOffset(0, top),
			Color3.fromRGB(24, 27, 34)
		)
		local title = ("%s%s — %s"):format(sku.name, if sku.recommended then "  (RECOMMENDED)" else "", sku.category)
		newLabel(row, "Title", UDim2.new(1, -110, 0, 18), UDim2.fromOffset(6, 2), title)
		newLabel(row, "Effect", UDim2.new(1, -110, 0, 16), UDim2.fromOffset(6, 20), sku.effectLabel)
		newLabel(row, "Unlock", UDim2.new(1, -110, 0, 16), UDim2.fromOffset(6, 38), sku.unlockLabel)

		local price = newLabel(row, "Price", UDim2.fromOffset(100, 20), UDim2.new(1, -104, 0, 4), self:FormatPrice(sku))
		price.TextXAlignment = Enum.TextXAlignment.Right
		-- §9: the comparison is sticky and its colour is its meaning.
		price.TextColor3 = if sku.owned
			then Color3.fromRGB(150, 200, 255)
			elseif sku.affordable then Color3.fromRGB(120, 235, 130)
			else Color3.fromRGB(150, 150, 155)

		local buy = newButton(
			row,
			"Buy",
			UDim2.fromOffset(100, 26),
			UDim2.new(1, -104, 0, 28),
			if sku.owned then "OWNED" else "BUY"
		)
		-- §9: never show a purchase button that silently does nothing. A disabled row is
		-- visibly disabled and its label carries the shortfall.
		local purchasable = not sku.owned and sku.affordable
		buy.Active = purchasable
		buy.AutoButtonColor = purchasable
		buy.TextColor3 = if purchasable then Color3.fromRGB(240, 240, 245) else Color3.fromRGB(110, 110, 118)
		buy.Activated:Connect(function()
			ShopController:RequestPurchase(sku.sku)
		end)
		buy:SetAttribute("SkuId", sku.sku)
		buy:SetAttribute("Purchasable", purchasable)
		index += 1
	end
end

-- Public API ------------------------------------------------------------------

--- §1 step 8: open the shop UI. The server state arrives on ShopStateChanged.
function ShopController:Open()
	isOpen = true
	if panel == nil then
		panel = buildPanel()
	end
	local screen = panel:FindFirstChildOfClass("ScreenGui") or panel.Parent
	if screen ~= nil and (screen :: Instance):IsA("ScreenGui") then
		(screen :: ScreenGui).Enabled = true
	end
	self:Render()
end

function ShopController:Close()
	isOpen = false
	if panel ~= nil then
		local screen = panel.Parent
		if screen ~= nil and (screen :: Instance):IsA("ScreenGui") then
			(screen :: ScreenGui).Enabled = false
		end
	end
end

function ShopController:IsOpen(): boolean
	return isOpen
end

--- The last state the server pushed (§9: `280 C` in green when affordable, grey with the
--- shortfall shown when not).
function ShopController:GetState(): Types.ShopState
	return shopState
end

--- §6.2: SELL ALL. The server pays Σ(value x count) and clears the log — selling is
--- authoritative, so this asks the service rather than touching the log itself.
function ShopController:SellAll()
	local ok, service = pcall(function()
		return Knit.GetService("ShopService")
	end)
	if not ok or type(service) ~= "table" then
		return
	end
	local answered, promise = pcall(function()
		return (service :: any):SellAll()
	end)
	if not answered then
		return
	end
	if promise ~= nil and (promise :: any).andThen ~= nil then
		(promise :: any):andThen(function(result: Types.SellAllResult)
			-- The new state arrives on ShopStateChanged; this is only for an immediate redraw.
			if result ~= nil and result.soldCount ~= nil then
				ShopController:Render()
			end
		end)
	elseif type(promise) == "table" then
		ShopController:Render()
	end
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

-- Knit lifecycle --------------------------------------------------------------

function ShopController:KnitStart()
	for _, name in { "ShopBuyRequest", "ShopStateChanged", "CoinsChanged" } do
		remotes[name] = Remotes.get(name)
	end

	remotes.ShopStateChanged.OnClientEvent:Connect(function(state: Types.ShopState)
		shopState = state
		-- The Tide Trader's verb is "open the shop": the panel appears when the state the
		-- server just pushed for that player lands, so there is no second open protocol.
		if not isOpen then
			ShopController:Open()
		else
			ShopController:Render()
		end
	end)

	remotes.CoinsChanged.OnClientEvent:Connect(function(coins: number)
		shopState.coins = coins
		-- §9: the cost-vs-cash comparison is sticky — a purchase redraws every row against the
		-- new balance.
		if isOpen then
			ShopController:Render()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			ShopController:Close()
		end
	end)
end

return ShopController
