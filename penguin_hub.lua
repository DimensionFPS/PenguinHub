--!nocheck
--[[
    Penguin Hub
    fly / speed / noclip / autofarm / tp

    Targets the penguin survival place. Everything goes through the game's own
    remotes (RequestMeleeAttack, RequestPunch) and ProximityPrompts, so nothing
    here has to guess at server-side validation.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
local MeleeRemote = Remotes and Remotes:WaitForChild("RequestMeleeAttack", 10)
local PunchRemote = Remotes and Remotes:WaitForChild("RequestPunch", 10)

-- Keep the state table off the script upvalue so a reload does not stack a
-- second copy of the loops on top of the first.
local State = getgenv().PENGUIN_HUB
if type(State) ~= "table" then
    State = { conns = {}, flags = {}, config = {} }
    getgenv().PENGUIN_HUB = State
end

if type(State.shutdown) == "function" then
    pcall(State.shutdown)
end

local Config = State.config
Config.walkSpeed = Config.walkSpeed or 60
Config.flySpeed = Config.flySpeed or 90
Config.attackDelay = Config.attackDelay or 0.7
Config.harvestRadius = Config.harvestRadius or 14
Config.instantInterval = Config.instantInterval or 0.02

State.conns = {}
State.flags = { fly = false, speed = false, noclip = false, farm = false, instant = true }
State.savedCFrame = State.savedCFrame or nil

local function bind(signal, handler)
    local connection = signal:Connect(handler)
    table.insert(State.conns, connection)
    return connection
end

local function character()
    local model = LocalPlayer.Character
    if not model or not model.Parent then
        return nil
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then
        return nil
    end
    return model, humanoid, root
end

local function notify(title, content)
    if State.ui then
        pcall(function()
            State.ui:Notify({ Title = title, Content = content, Duration = 3 })
        end)
    end
end

-- / movement --------------------------------------------------------------

local held = {}

bind(UserInputService.InputBegan, function(input, gameProcessed)
    if not gameProcessed then
        held[input.KeyCode] = true
    end
end)

bind(UserInputService.InputEnded, function(input)
    held[input.KeyCode] = nil
end)

local function releaseFly()
    local _, humanoid = character()
    if humanoid then
        humanoid.PlatformStand = false
    end
end

local function flyStep(delta)
    if not State.flags.fly then
        return
    end

    local _, humanoid, root = character()
    if not root then
        return
    end
    if UserInputService:GetFocusedTextBox() then
        return
    end

    humanoid.PlatformStand = true

    local camera = workspace.CurrentCamera
    local direction = Vector3.zero
    if held[Enum.KeyCode.W] then
        direction += camera.CFrame.LookVector
    end
    if held[Enum.KeyCode.S] then
        direction -= camera.CFrame.LookVector
    end
    if held[Enum.KeyCode.D] then
        direction += camera.CFrame.RightVector
    end
    if held[Enum.KeyCode.A] then
        direction -= camera.CFrame.RightVector
    end
    if held[Enum.KeyCode.Space] then
        direction += Vector3.yAxis
    end
    if held[Enum.KeyCode.LeftControl] or held[Enum.KeyCode.Q] then
        direction -= Vector3.yAxis
    end

    if direction.Magnitude > 0 then
        direction = direction.Unit
    end

    local rotation = root.CFrame.Rotation
    local position = root.CFrame.Position + direction * Config.flySpeed * delta
    root.CFrame = CFrame.new(position) * rotation
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function enforceSpeed()
    if not State.flags.speed or State.flags.fly then
        return
    end
    local _, humanoid = character()
    if humanoid and humanoid.WalkSpeed ~= Config.walkSpeed then
        humanoid.WalkSpeed = Config.walkSpeed
    end
end

local function enforceNoclip()
    if not State.flags.noclip then
        return
    end
    local model = LocalPlayer.Character
    if not model then
        return
    end
    for _, part in model:GetDescendants() do
        if part:IsA("BasePart") and part.CanCollide then
            part.CanCollide = false
        end
    end
end

local function restoreCollisions()
    local _, _, root = character()
    if root then
        root.CanCollide = true
    end
end

bind(RunService.RenderStepped, function(delta)
    flyStep(delta)
    enforceNoclip()
end)

-- The game rewrites WalkSpeed from AnimationController and MovementController,
-- so re-assert it on both sides of the simulation step.
bind(RunService.Heartbeat, enforceSpeed)
bind(RunService.PreSimulation, enforceSpeed)

-- / teleport --------------------------------------------------------------

local function teleportTo(cframe)
    local _, _, root = character()
    if not root then
        return false
    end
    root.CFrame = cframe
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end

local function mousePosition()
    local camera = workspace.CurrentCamera
    local location = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(location.X, location.Y)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    params.IgnoreWater = true

    local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
    return hit and hit.Position or (ray.Origin + ray.Direction * 250)
end

local function teleportToMouse()
    local position = mousePosition()
    if teleportTo(CFrame.new(position + Vector3.new(0, 3, 0))) then
        notify("Teleport", string.format("Moved to %.0f, %.0f, %.0f", position.X, position.Y, position.Z))
    end
end

local function findPlayer(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    name = name:lower()
    for _, player in Players:GetPlayers() do
        if player ~= LocalPlayer and player.Name:lower():find(name, 1, true) then
            return player
        end
    end
    return nil
end

local function teleportToPlayer(name)
    local target = findPlayer(name)
    local targetRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot then
        notify("Teleport", "No player found for that name")
        return
    end
    local offset = targetRoot.CFrame.LookVector * 4 + Vector3.new(0, 2, 0)
    teleportTo(CFrame.new(targetRoot.Position + offset))
    notify("Teleport", "Moved to " .. target.Name)
end

-- / autofarm --------------------------------------------------------------

local function liveCreatures()
    local list = {}
    for _, model in CollectionService:GetTagged("Creature") do
        if model:IsA("Model") and model.Parent then
            local health = model:GetAttribute("Health")
            if type(health) == "number" and health > 0 then
                table.insert(list, model)
            end
        end
    end
    return list
end

local function nearestCreature(origin)
    local best, bestDistance
    for _, model in liveCreatures() do
        local position = model:GetPivot().Position
        local distance = (position - origin).Magnitude
        if not bestDistance or distance < bestDistance then
            best, bestDistance = model, distance
        end
    end
    return best, bestDistance
end

local prompts = {}
local nextPromptScan = 0

local function scanPrompts()
    local list = {}
    local world = workspace:FindFirstChild("World")
    if world then
        for _, descendant in world:GetDescendants() do
            if descendant:IsA("ProximityPrompt") and descendant.Enabled then
                -- Creatures carry a feed prompt; leave those alone.
                if not descendant:FindFirstAncestor("Creatures") then
                    table.insert(list, descendant)
                end
            end
        end
    end
    prompts = list
end

local function promptPosition(prompt)
    local parent = prompt.Parent
    if not parent then
        return nil
    end
    if parent:IsA("BasePart") then
        return parent.Position
    end
    if parent:IsA("Model") then
        return parent:GetPivot().Position
    end
    local part = parent:FindFirstChildWhichIsA("BasePart")
    return part and part.Position or nil
end

local lastAttack = 0
local lastHarvest = 0
local lastFired = {}

local function engage(model)
    local _, _, root = character()
    if not root then
        return
    end

    local target = model:GetPivot().Position
    local distance = (target - root.Position).Magnitude

    if distance > 7 then
        local away = root.Position - target
        away = Vector3.new(away.X, 0, away.Z)
        if away.Magnitude < 0.1 then
            away = Vector3.new(0, 0, 1)
        end
        local stand = target + away.Unit * 5 + Vector3.new(0, 2, 0)
        teleportTo(CFrame.lookAt(stand, Vector3.new(target.X, stand.Y, target.Z)))
        lastAttack = 0
        return
    end

    root.CFrame = CFrame.lookAt(root.Position, Vector3.new(target.X, root.Position.Y, target.Z))

    -- Instant mode ignores the swing cooldown entirely and fires on every
    -- tick; the server drops anything past ~12 hits a second anyway.
    local interval = State.flags.instant and Config.instantInterval or Config.attackDelay
    if os.clock() - lastAttack < interval then
        return
    end
    lastAttack = os.clock()

    local equipped = LocalPlayer:GetAttribute("EquippedItem")
    if equipped and MeleeRemote then
        MeleeRemote:FireServer(model)
    elseif PunchRemote then
        PunchRemote:FireServer(model)
    end
end

local function harvestNearby(allowTeleport)
    local _, _, root = character()
    if not root then
        return
    end

    local now = os.clock()
    if now >= nextPromptScan then
        nextPromptScan = now + 3
        scanPrompts()
    end

    local candidates = {}
    for _, prompt in prompts do
        local position = prompt.Parent and promptPosition(prompt)
        if position then
            local distance = (position - root.Position).Magnitude
            if distance <= 60 then
                table.insert(candidates, { prompt = prompt, position = position, distance = distance })
            end
        end
    end
    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    for index = 1, math.min(#candidates, 3) do
        local candidate = candidates[index]
        local prompt = candidate.prompt

        if candidate.distance > Config.harvestRadius then
            if not allowTeleport then
                return
            end
            teleportTo(CFrame.new(candidate.position + Vector3.new(0, 3, 0)))
            return
        end

        if now - (lastFired[prompt] or 0) > 0.5 and type(fireproximityprompt) == "function" then
            lastFired[prompt] = now
            pcall(fireproximityprompt, prompt)
        end
    end
end

local farmRunning = false

local function farmStep()
    if State.flags.fly then
        return
    end

    local _, _, root = character()
    if not root then
        return
    end

    local target = nearestCreature(root.Position)
    if target then
        engage(target)
    end

    -- While a creature is in play only fire prompts already in reach; walking
    -- off to a tree mid-fight is how a farm ends up doing neither job.
    if os.clock() - lastHarvest >= 1 then
        lastHarvest = os.clock()
        harvestNearby(not target)
    end
end

local function startFarm()
    if farmRunning then
        return
    end
    farmRunning = true
    task.spawn(function()
        while State.flags.farm do
            pcall(farmStep)
            task.wait(State.flags.instant and Config.instantInterval or 0.05)
        end
        farmRunning = false
    end)
end

-- / keybinds --------------------------------------------------------------

local keybinds = {
    fly = Enum.KeyCode.F,
    speed = Enum.KeyCode.V,
    noclip = Enum.KeyCode.X,
    farm = Enum.KeyCode.G,
}

local ui = {}
State.ui = nil

local function setFlag(name, value)
    State.flags[name] = value
    if name == "fly" and not value then
        releaseFly()
    end
    if name == "noclip" and not value then
        restoreCollisions()
    end
    if name == "farm" and value then
        startFarm()
    end
end

bind(UserInputService.InputBegan, function(input, gameProcessed)
    if gameProcessed or UserInputService:GetFocusedTextBox() then
        return
    end
    for name, key in keybinds do
        if input.KeyCode == key then
            setFlag(name, not State.flags[name])
            local toggle = ui[name]
            if toggle then
                pcall(function()
                    toggle:Set(State.flags[name])
                end)
            end
            return
        end
    end
end)

-- / ui --------------------------------------------------------------------

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
if not WindUI then
    warn("[Penguin Hub] WindUI failed to load")
    return
end

local Window = WindUI:CreateWindow({
    Title = "Penguin Hub",
    Author = "fly / speed / noclip / autofarm / tp",
    Icon = "snowflake",
    Folder = "PenguinHub",
    Size = UDim2.fromOffset(560, 430),
    Theme = "Dark",
})

State.ui = WindUI

Window:SetToggleKey(Enum.KeyCode.RightShift)

local movementTab = Window:Tab({ Title = "Movement", Icon = "move" })
local teleportTab = Window:Tab({ Title = "Teleport", Icon = "map-pin" })
local farmTab = Window:Tab({ Title = "Farm", Icon = "crosshair" })

ui.fly = movementTab:Toggle({
    Title = "Fly",
    Desc = "WASD to steer, Space to rise, Ctrl or Q to sink  [F]",
    Value = false,
    Callback = function(value)
        setFlag("fly", value)
    end,
})

movementTab:Slider({
    Title = "Fly speed",
    Step = 5,
    Value = { Min = 20, Max = 300, Default = Config.flySpeed },
    Callback = function(value)
        Config.flySpeed = value
    end,
})

ui.speed = movementTab:Toggle({
    Title = "Speed",
    Desc = "Re-asserted every frame because the movement controllers reset it  [V]",
    Value = false,
    Callback = function(value)
        setFlag("speed", value)
    end,
})

movementTab:Slider({
    Title = "Walk speed",
    Step = 2,
    Value = { Min = 16, Max = 300, Default = Config.walkSpeed },
    Callback = function(value)
        Config.walkSpeed = value
    end,
})

ui.noclip = movementTab:Toggle({
    Title = "Noclip",
    Desc = "Disabled collisions on your character  [X]",
    Value = false,
    Callback = function(value)
        setFlag("noclip", value)
    end,
})

teleportTab:Button({
    Title = "Teleport to mouse",
    Icon = "mouse-pointer",
    Callback = teleportToMouse,
})

local playerDropdown = teleportTab:Dropdown({
    Title = "Player",
    Values = (function()
        local names = {}
        for _, player in Players:GetPlayers() do
            if player ~= LocalPlayer then
                table.insert(names, player.Name)
            end
        end
        table.sort(names)
        return names
    end)(),
    Value = nil,
    AllowNone = true,
    Callback = function(value)
        State.selectedPlayer = value
    end,
})

teleportTab:Button({
    Title = "Teleport to player",
    Icon = "user-round",
    Callback = function()
        teleportToPlayer(State.selectedPlayer)
    end,
})

teleportTab:Button({
    Title = "Teleport to nearest creature",
    Icon = "paw-print",
    Callback = function()
        local _, _, root = character()
        if not root then
            return
        end
        local model, distance = nearestCreature(root.Position)
        if not model then
            notify("Teleport", "No live creature in range")
            return
        end
        local position = model:GetPivot().Position + Vector3.new(0, 3, 0)
        teleportTo(CFrame.new(position))
        notify("Teleport", string.format("%s at %.0f studs", model.Name, distance or 0))
    end,
})

teleportTab:Button({
    Title = "Save position",
    Icon = "bookmark",
    Callback = function()
        local _, _, root = character()
        if root then
            State.savedCFrame = root.CFrame
            notify("Teleport", "Position saved")
        end
    end,
})

teleportTab:Button({
    Title = "Return to saved position",
    Icon = "undo-2",
    Callback = function()
        if State.savedCFrame then
            teleportTo(State.savedCFrame)
        else
            notify("Teleport", "Nothing saved yet")
        end
    end,
})

ui.farm = farmTab:Toggle({
    Title = "Auto farm",
    Desc = "Hunts the nearest creature and fires harvest prompts on the way  [G]",
    Value = false,
    Callback = function(value)
        setFlag("farm", value)
    end,
})

ui.instant = farmTab:Toggle({
    Title = "Instant hit",
    Desc = "No swing delay: attacks every tick. The server takes about 12 hits a second",
    Value = State.flags.instant,
    Callback = function(value)
        State.flags.instant = value
    end,
})

farmTab:Slider({
    Title = "Attack delay",
    Step = 0.05,
    Value = { Min = 0.05, Max = 2, Default = Config.attackDelay },
    Callback = function(value)
        Config.attackDelay = value
    end,
})

farmTab:Slider({
    Title = "Harvest radius",
    Step = 1,
    Value = { Min = 8, Max = 60, Default = Config.harvestRadius },
    Callback = function(value)
        Config.harvestRadius = value
    end,
})

-- Refresh the player list while the menu is alive.
task.spawn(function()
    while State.ui == WindUI do
        task.wait(5)
        local names = {}
        for _, player in Players:GetPlayers() do
            if player ~= LocalPlayer then
                table.insert(names, player.Name)
            end
        end
        table.sort(names)
        pcall(function()
            playerDropdown:Refresh(names)
        end)
    end
end)

-- Small surface for testing from the outside without poking at locals.
State.api = {
    character = character,
    teleportTo = teleportTo,
    teleportToMouse = teleportToMouse,
    nearestCreature = nearestCreature,
    engage = engage,
    harvestNearby = harvestNearby,
    scanPrompts = scanPrompts,
    setFlag = setFlag,
}

-- / lifecycle -------------------------------------------------------------

bind(LocalPlayer.CharacterAdded, function()
    task.wait(0.5)
    if State.flags.fly then
        releaseFly()
    end
    enforceNoclip()
end)

State.shutdown = function()
    State.flags = { fly = false, speed = false, noclip = false, farm = false, instant = true }
    for _, connection in State.conns do
        pcall(function()
            connection:Disconnect()
        end)
    end
    State.conns = {}
    releaseFly()
    pcall(function()
        Window:Destroy()
    end)
    State.ui = nil
end

WindUI:Notify({
    Title = "Penguin Hub",
    Content = "RightShift opens the menu. F fly, V speed, X noclip, G autofarm.",
    Duration = 6,
})
