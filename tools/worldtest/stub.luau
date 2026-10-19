-- Fake Roblox globals so the builder can be executed headlessly in the Luau CLI.
local STORES = {}
local function getStore(x)
    return STORES[x]
end

local REMOTE_LOG = {}

-- The Luau CLI has no `warn`; services use it for their guarded failure paths.
warn = function(...)
    local parts = { ... }
    local text = {}
    for _, value in parts do
        table.insert(text, tostring(value))
    end
    print("[warn] " .. table.concat(text, " "))
end

local function newSignal()
    local signal = { handlers = {} }
    function signal:Connect(fn)
        table.insert(self.handlers, fn)
        return {
            Disconnect = function()
                for index, handler in ipairs(signal.handlers) do
                    if handler == fn then
                        table.remove(signal.handlers, index)
                        break
                    end
                end
            end,
        }
    end
    function signal:Fire(...)
        local snapshot = table.clone(signal.handlers)
        for _, fn in ipairs(snapshot) do
            fn(...)
        end
    end
    return signal
end

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
    if class == "RemoteEvent" then
        store.OnServerEvent = newSignal()
        store.OnClientEvent = newSignal()
        function methods:FireServer(player, ...)
            table.insert(REMOTE_LOG, { remote = store.Name, direction = "FireServer", player = player, args = { ... } })
        end
        function methods:FireClient(player, ...)
            table.insert(REMOTE_LOG, { remote = store.Name, direction = "FireClient", player = player, args = { ... } })
        end
        function methods:FireAllClients(...)
            table.insert(
                REMOTE_LOG,
                { remote = store.Name, direction = "FireAllClients", player = nil, args = { ... } }
            )
        end
    end
    if class == "Player" then
        function methods:GetAttributeChangedSignal(key)
            store.Signals = store.Signals or {}
            local signal = store.Signals[key]
            if signal == nil then
                signal = newSignal()
                store.Signals[key] = signal
            end
            return signal
        end
    end
    if class == "ProximityPrompt" then
        store.Triggered = newSignal()
        store.TriggerEnded = newSignal()
        store.PromptShown = newSignal()
        store.PromptHidden = newSignal()
    end
    function methods:FindFirstChild(name)
        for _, c in ipairs(store.Children) do
            if c.Name == name then
                return c
            end
        end
        return nil
    end
    function methods:GetChildren()
        return table.clone(store.Children)
    end
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
                if c == inst then
                    table.remove(list, i)
                    break
                end
            end
        end
        store.Parent = nil
    end
    function methods:IsA(c)
        if c == store.ClassName then
            return true
        end
        if c == "Instance" then
            return true
        end
        if
            c == "BasePart"
            and (store.ClassName == "Part" or store.ClassName == "WedgePart" or store.ClassName == "SpawnLocation")
        then
            return true
        end
        if c == "Part" and (store.ClassName == "SpawnLocation" or store.ClassName == "Part") then
            return true
        end
        return false
    end
    function methods:WaitForChild(name, _timeout)
        for _, c in ipairs(store.Children) do
            if c.Name == name then
                return c
            end
        end
        return nil
    end
    function methods:FindFirstChildOfClass(class)
        for _, c in ipairs(store.Children) do
            if getStore(c).ClassName == class then
                return c
            end
        end
        return nil
    end
    function methods:SetAttribute(k, v)
        store.Attributes[k] = v
    end
    function methods:GetAttribute(k)
        return store.Attributes[k]
    end
    function methods:Clone()
        error("Clone not stubbed")
    end

    inst = setmetatable({}, {
        __index = function(_, k)
            local m = methods[k]
            if m ~= nil then
                return m
            end
            local v = store[k]
            if v ~= nil then
                return v
            end
            -- Roblox reports a part's Position from its CFrame; the stub mirrors the two.
            if k == "Position" and store.CFrame ~= nil then
                return store.CFrame.Position
            end
            -- An Attachment's WorldPosition is its host part's position plus its own offset.
            -- (Built by hand: Vector3 is declared below this closure, so the global is nil here.)
            if k == "WorldPosition" and store.ClassName == "Attachment" then
                local host = store.Parent
                local hostStore = if host ~= nil then getStore(host) else nil
                local offset = store.Position
                if hostStore == nil or hostStore.CFrame == nil then
                    return offset
                end
                local base = hostStore.CFrame.Position
                if offset == nil then
                    return base
                end
                return setmetatable(
                    { X = base.X + offset.X, Y = base.Y + offset.Y, Z = base.Z + offset.Z },
                    getmetatable(base)
                )
            end
            -- Roblox lets you index a child by name (Workspace.DeepTide.World...)
            for _, c in ipairs(store.Children) do
                if c.Name == k then
                    return c
                end
            end
            return nil
        end,
        __newindex = function(_, k, v)
            if k == "Parent" then
                local old = store.Parent
                if old then
                    local list = getStore(old).Children
                    for i, c in ipairs(list) do
                        if c == inst then
                            table.remove(list, i)
                            break
                        end
                    end
                end
                store.Parent = v
                if v ~= nil then
                    table.insert(getStore(v).Children, inst)
                end
            else
                if k == "CFrame" and type(v) == "table" and v.Position ~= nil then
                    store.Position = v.Position
                end
                store[k] = v
            end
        end,
    })
    STORES[inst] = store
    return inst
end
Instance.new = function(class)
    return makeInstance(class)
end

local Vector3 = {}
local vmt = {}
vmt.__index = function(t, k)
    if k == "Magnitude" then
        return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
    end
    if k == "Unit" then
        local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
        if m == 0 then
            return Vector3.new(0, 0, 0)
        end
        return Vector3.new(t.X / m, t.Y / m, t.Z / m)
    end
    return vmt[k]
end
function Vector3.new(x, y, z)
    if type(x) == "table" then
        x, y, z = x.X, x.Y, x.Z
    end
    return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, vmt)
end
Vector3.zero = Vector3.new(0, 0, 0)
vmt.__add = function(a, b)
    return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
vmt.__sub = function(a, b)
    return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
vmt.__mul = function(a, b)
    if type(b) == "number" then
        return Vector3.new(a.X * b, a.Y * b, a.Z * b)
    end
    return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
vmt.__div = function(a, b)
    return Vector3.new(a.X / b, a.Y / b, a.Z / b)
end
vmt.__eq = function(a, b)
    return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
vmt.__tostring = function(a)
    return ("(%.2f, %.2f, %.2f)"):format(a.X, a.Y, a.Z)
end

local cframeMt = {}
cframeMt.__index = function(t, k)
    local ry = rawget(t, "ry") or 0
    if k == "LookVector" then
        -- CFrame.Angles(0, ry, 0).LookVector, which is what a character's root reports.
        return Vector3.new(-math.sin(ry), 0, -math.cos(ry))
    elseif k == "RightVector" then
        return Vector3.new(math.cos(ry), 0, -math.sin(ry))
    elseif k == "UpVector" then
        return Vector3.new(0, 1, 0)
    end
    return cframeMt[k]
end
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
-- Roblox stores a Color3 as three channels in [0, 1] (Color3.fromRGB divides by 255). The stub
-- mirrors that rather than keeping 0-255 integers, because art code that lerps colours is written
-- against the real semantics — a stub that quietly disagreed would let a broken lerp pass its test.
function Color3.fromRGB(r, g, b)
    return { R = r / 255, G = g / 255, B = b / 255, __rgb = true }
end
function Color3.new(r, g, b)
    return Color3.fromRGB(r * 255, g * 255, b * 255)
end

local function enumFamily()
    local fam = {}
    return setmetatable(fam, {
        __index = function(_, k)
            local item = { Name = k, EnumType = fam }
            return item
        end,
    })
end
local Enum = setmetatable({}, {
    __index = function(_, k)
        return enumFamily()
    end,
})

local UDim2 = {}
function UDim2.fromScale(x, y)
    return { x, y }
end
function UDim2.new(x, xo, y, yo)
    return { x, xo, y, yo }
end

-- Sequence types, so the visual suite can build ParticleEmitters the way the real server does.
-- Only the shape matters headlessly: what a test asserts is that the emitter exists, on which
-- host, and with which rate/lifetime — not how Roblox interpolates a gradient.
local NumberSequence = {}
function NumberSequence.new(a, b)
    return { __sequence = "number", start = a, finish = if b == nil then a else b }
end
local ColorSequence = {}
function ColorSequence.new(a, b)
    return { __sequence = "color", start = a, finish = if b == nil then a else b }
end
local Vector2 = {}
function Vector2.new(x, y)
    return { X = x, Y = y }
end

local TERRAIN_FILLS = {}
local workspaceService = makeInstance("Workspace")
workspaceService.Terrain = makeInstance("Terrain")
function workspaceService.Terrain:FillBlock(cf, size, material)
    table.insert(TERRAIN_FILLS, { size = size, material = material.Name })
end
workspace = workspaceService
-- Roblox exposes Workspace as well as workspace; server code may use either.
Workspace = workspaceService

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
    if src == nil then
        error("no config source for " .. tostring(name))
    end
    return src()
end
local function TREE()
    return workspaceService
end
local function FILLS()
    return TERRAIN_FILLS
end

-- ============================================================================
-- Services the fishing harness needs (tools/worldtest/fish_harness.luau)
-- ============================================================================

-- task: the server code only ever defers, so deferral is executed inline here.
-- task.wait is deliberately an error: a headless harness has no scheduler, and a
-- `while true do task.wait() end` loop would hang the suite forever.
task = {
    spawn = function(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            error(err)
        end
    end,
    defer = function(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            error(err)
        end
    end,
    delay = function(_seconds, fn, ...)
        pcall(fn, ...)
    end,
    wait = function()
        error("task.wait is not available in the headless harness")
    end,
}

local heartbeat = newSignal()
local renderStepped = newSignal()
local runService = makeInstance("RunService")
runService.Heartbeat = heartbeat
runService.RenderStepped = renderStepped
runService.Stepped = heartbeat
runService.PostSimulation = heartbeat
function runService:IsServer()
    return true
end
function runService:IsClient()
    return false
end
SERVICES.RunService = runService
local function __fireHeartbeat(dt)
    heartbeat:Fire(dt)
end

local playersService = makeInstance("Players")
playersService.PlayerAdded = newSignal()
playersService.PlayerRemoving = newSignal()
local PLAYER_LIST = {}
function playersService:GetPlayers()
    return table.clone(PLAYER_LIST)
end
function playersService:GetPlayerFromCharacter(character)
    for _, candidate in ipairs(PLAYER_LIST) do
        if candidate.Character == character then
            return candidate
        end
    end
    return nil
end
function playersService:GetPlayerByUserId(userId)
    for _, candidate in ipairs(PLAYER_LIST) do
        if candidate.UserId == userId then
            return candidate
        end
    end
    return nil
end
SERVICES.Players = playersService

local function __setPosition(inst, position)
    local store = getStore(inst)
    local yaw = if store.CFrame ~= nil then (store.CFrame.ry or 0) else 0
    store.Position = position
    store.CFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
end

local function __setYaw(inst, yaw)
    local store = getStore(inst)
    local position = store.Position or (if store.CFrame ~= nil then store.CFrame.Position else Vector3.new(0, 0, 0))
    store.CFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
end

local nextUserId = 1000

--- A mock player with a character, a HumanoidRootPart and a Head at `position`.
--- Everything the server reads about a player goes through those two parts.
local function __addPlayer(name: string, position: Vector3, yaw: number?)
    nextUserId += 1
    local player = makeInstance("Player")
    player.Name = name
    player.UserId = nextUserId
    local userId = nextUserId

    local character = makeInstance("Model")
    character.Name = name
    character.Parent = workspaceService

    local root = makeInstance("Part")
    root.Name = "HumanoidRootPart"
    root.Parent = character

    local head = makeInstance("Part")
    head.Name = "Head"
    head.Parent = character

    local humanoid = makeInstance("Humanoid")
    humanoid.Name = "Humanoid"
    humanoid.Parent = character

    __setPosition(root, position)
    __setPosition(head, position + Vector3.new(0, 2, 0))
    if yaw ~= nil then
        __setYaw(root, yaw)
    end

    getStore(player).Character = character
    getStore(player).UserId = userId
    table.insert(PLAYER_LIST, player)
    playersService.PlayerAdded:Fire(player)
    return player
end

--- Move a mock player: root and head together, so depth and distance stay consistent.
local function __movePlayer(player, position, yaw: number?)
    local character = player.Character
    local root = character:FindFirstChild("HumanoidRootPart")
    local head = character:FindFirstChild("Head")
    __setPosition(root, position)
    __setPosition(head, position + Vector3.new(0, 2, 0))
    if yaw ~= nil then
        __setYaw(root, yaw)
    end
end

local function __removePlayer(player)
    for index, candidate in ipairs(PLAYER_LIST) do
        if candidate == player then
            table.remove(PLAYER_LIST, index)
            break
        end
    end
    playersService.PlayerRemoving:Fire(player)
end

--- The whole server -> client log, so a test can assert what a player was actually told.
local function __remotes()
    return REMOTE_LOG
end
local function __clearRemotes()
    for index = #REMOTE_LOG, 1, -1 do
        table.remove(REMOTE_LOG, index)
    end
end

--- Client -> server: fire a RemoteEvent's OnServerEvent the way a client would.
local function __fireClientToServer(remoteName, player, ...)
    local folder = SERVICES.ReplicatedStorage:FindFirstChild("DeepTide")
    local remotes = if folder ~= nil then folder:FindFirstChild("Remotes") else nil
    local remote = if remotes ~= nil then remotes:FindFirstChild(remoteName) else nil
    if remote == nil then
        error("no such remote: " .. tostring(remoteName))
    end
    remote.OnServerEvent:Fire(player, ...)
end

--- Whether a RemoteEvent exists for every name the server declared.
local function __remoteFolder()
    return SERVICES.ReplicatedStorage
end
