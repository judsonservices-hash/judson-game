-- Fake Roblox globals so the builder can be executed headlessly in the Luau CLI.
local STORES = {}
local function getStore(x) return STORES[x] end

local function initInstance(store)
store.Attributes = store.Attributes or {}
store.Children = store.Children or {}
end

local Instance = {}
local function makeInstance(class)
local store = { ClassName = class, Name = class }
initInstance(store)
local methods = {}
local inst
function methods:FindFirstChild(name)
for _, c in ipairs(store.Children) do
if c.Name == name then return c end
end
return nil
end
function methods:GetChildren() return table.clone(store.Children) end
function methods:GetDescendants()
local out = {}
local function walk(node)
for _, c in ipairs(getStore(node).Children) do
table.insert(out, c)
walk(c)
end
end
walk(inst)
return out
end
function methods:Destroy()
local p = store.Parent
if p then
local list = getStore(p).Children
for i, c in ipairs(list) do
if c == inst then table.remove(list, i) break end
end
end
store.Parent = nil
end
function methods:IsA(c)
if c == store.ClassName then return true end
if c == "Part" and (store.ClassName == "SpawnLocation" or store.ClassName == "Part") then return true end
return false
end
function methods:SetAttribute(k, v) store.Attributes[k] = v end
function methods:GetAttribute(k) return store.Attributes[k] end
function methods:Clone() error("Clone not stubbed") end

inst = setmetatable({}, {
__index = function(_, k)
    local m = methods[k]
    if m ~= nil then return m end
    local v = store[k]
    if v ~= nil then return v end
    -- Roblox lets you index a child by name (Workspace.DeepTide.World...)
    for _, c in ipairs(store.Children) do
        if c.Name == k then return c end
    end
    return nil
end,
__newindex = function(_, k, v)
if k == "Parent" then
local old = store.Parent
if old then
local list = getStore(old).Children
for i, c in ipairs(list) do
if c == inst then table.remove(list, i) break end
end
end
store.Parent = v
if v ~= nil then table.insert(getStore(v).Children, inst) end
else
store[k] = v
end
end,
})
STORES[inst] = store
return inst
end
Instance.new = function(class) return makeInstance(class) end

local Vector3 = {}
local vmt = {}
vmt.__index = vmt
function Vector3.new(x, y, z)
if type(x) == "table" then x, y, z = x.X, x.Y, x.Z end
return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, vmt)
end
Vector3.zero = Vector3.new(0, 0, 0)
vmt.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
vmt.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
vmt.__mul = function(a, b)
if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
vmt.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
vmt.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
vmt.__tostring = function(a) return ("(%.2f, %.2f, %.2f)"):format(a.X, a.Y, a.Z) end

local cframeMt = {}
cframeMt.__index = cframeMt
local CFrame = {}
function CFrame.new(x, y, z)
if type(x) == "table" and x.X ~= nil then
return setmetatable({ Position = Vector3.new(x.X, x.Y, x.Z) }, cframeMt)
end
return setmetatable({ Position = Vector3.new(x or 0, y or 0, z or 0) }, cframeMt)
end
function CFrame.Angles(rx, ry, rz)
return setmetatable({ Position = Vector3.new(0, 0, 0), rx = rx, ry = ry, rz = rz }, cframeMt)
end
cframeMt.__mul = function(a, b)
return setmetatable({
Position = a.Position + b.Position,
rx = (a.rx or 0) + (b.rx or 0),
ry = (a.ry or 0) + (b.ry or 0),
rz = (a.rz or 0) + (b.rz or 0),
}, cframeMt)
end

local Color3 = {}
function Color3.fromRGB(r, g, b) return { R = r, G = g, B = b, __rgb = true } end
function Color3.new(r, g, b) return Color3.fromRGB(r * 255, g * 255, b * 255) end

local function enumFamily()
local fam = {}
return setmetatable(fam, {
__index = function(_, k)
local item = { Name = k, EnumType = fam }
return item
end,
})
end
local Enum = setmetatable({}, { __index = function(_, k) return enumFamily() end })

local UDim2 = {}
function UDim2.fromScale(x, y) return { x, y } end
function UDim2.new(x, xo, y, yo) return { x, xo, y, yo } end

local TERRAIN_FILLS = {}
local workspaceService = makeInstance("Workspace")
workspaceService.Terrain = makeInstance("Terrain")
function workspaceService.Terrain:FillBlock(cf, size, material)
table.insert(TERRAIN_FILLS, { size = size, material = material.Name })
end
workspace = workspaceService

local SIBLING_SERVICES = {}
local SERVICES = { Workspace = workspaceService, ReplicatedStorage = makeInstance("ReplicatedStorage") }
game = {
GetService = function(_, name)
local svc = SERVICES[name]
if svc == nil then
svc = makeInstance(name)
SERVICES[name] = svc
end
return svc
end,
BindToClose = function() end,
}

local __KnitStub = {
CreateService = function(def)
def.Client = def.Client or {}
def.Server = def
return def
end,
}

local __CFG_SOURCES = {}
local function __config(name)
local src = __CFG_SOURCES[name]
if src == nil then error("no config source for " .. tostring(name)) end
return src()
end
local function TREE()
return workspaceService
end
local function FILLS()
return TERRAIN_FILLS
end
