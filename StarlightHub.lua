--[[
    ╔══════════════════════════════════════╗
    ║         STARLIGHT HUB  v1.0          ║
    ║     Steal An Egg • Premium UI        ║
    ║        Fully Open Source             ║
    ╚══════════════════════════════════════╝
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

-- ====================== CONFIG ======================
local Config = {
    WalkSpeed     = 120,
    FlySpeed      = 90,
    InstantSteal  = true,
    AutoSteal     = false,
    AutoPlace     = true,
    AutoHatch     = true,
    AutoSell      = false,
    Priority      = "Smart",
    ESPEnabled    = true,
    AntiFling     = true,
    Noclip        = false,
    Fly           = false,
    InfiniteJump  = false,
    StealDelay    = 1.4,
    Jitter        = 0.35,
    MinRarityRank = 1,
    OnlyBigEggs   = false,
}

local RarityRank = {
    Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
    Legendary = 5, Mythic = 6, Cosmic = 7,
    Secret = 8, Eternal = 9, Divine = 10
}

local RarityColor = {
    Common    = Color3.fromRGB(180,180,180),
    Uncommon  = Color3.fromRGB(80,200,80),
    Rare      = Color3.fromRGB(70,130,255),
    Epic      = Color3.fromRGB(170,70,255),
    Legendary = Color3.fromRGB(255,180,40),
    Mythic    = Color3.fromRGB(255,60,60),
    Cosmic    = Color3.fromRGB(0,220,255),
    Secret    = Color3.fromRGB(255,0,150),
    Eternal   = Color3.fromRGB(255,255,100),
    Divine    = Color3.fromRGB(255,215,0),
}

-- ====================== STATE ======================
local Character, Humanoid, Root
local ESPFolder
local autoStealConnection
local flyBV, flyBG
local stats = { stolen = 0, failed = 0, lastEgg = "None" }

-- Theme
local Theme = {
    Background   = Color3.fromRGB(12, 12, 18),
    Surface      = Color3.fromRGB(18, 18, 28),
    SurfaceAlt   = Color3.fromRGB(24, 24, 38),
    Accent       = Color3.fromRGB(130, 90, 255),      -- Starlight purple
    AccentSoft   = Color3.fromRGB(160, 120, 255),
    AccentDark   = Color3.fromRGB(90, 55, 200),
    Success      = Color3.fromRGB(50, 200, 120),
    Danger       = Color3.fromRGB(230, 70, 90),
    TextPrimary  = Color3.fromRGB(245, 245, 255),
    TextSecondary= Color3.fromRGB(160, 160, 190),
    TextMuted    = Color3.fromRGB(110, 110, 140),
    Stroke       = Color3.fromRGB(45, 40, 70),
}

-- ====================== UTILS ======================
local function notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 3.5
        })
    end)
end

local function refreshCharacter()
    Character = LocalPlayer.Character
    if not Character then return false end
    Humanoid = Character:FindFirstChildOfClass("Humanoid")
    Root = Character:FindFirstChild("HumanoidRootPart")
    return Root ~= nil
end

local function tp(cf)
    if refreshCharacter() then
        Root.CFrame = cf
    end
end

local function tweenTP(cf, speed)
    if not refreshCharacter() then return end
    local dist = (Root.Position - cf.Position).Magnitude
    local t = math.clamp(dist / (speed or 380), 0.12, 1.8)
    local tw = TweenService:Create(Root, TweenInfo.new(t, Enum.EasingStyle.Linear), {CFrame = cf})
    tw:Play()
    tw.Completed:Wait()
end

local function getPlot()
    local plots = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases") or Workspace:FindFirstChild("Farms")
    if plots then
        local myPlot = plots:FindFirstChild(LocalPlayer.Name) or plots:FindFirstChild(tostring(LocalPlayer.UserId))
        if myPlot then return myPlot end
    end
    for _, v in pairs(Workspace:GetDescendants()) do
        if v:IsA("SpawnLocation") and v.Name:lower():find("spawn") then
            return v.Parent
        end
    end
    return nil
end

-- ====================== EGG DETECTION ======================
local function isEgg(obj)
    if not obj:IsA("BasePart") and not obj:IsA("Model") then return false end
    local name = obj.Name:lower()
    if name:find("egg") then return true end
    if obj:GetAttribute("Rarity") or obj:GetAttribute("EggRarity") then return true end
    if obj:FindFirstChild("Rarity") or obj:FindFirstChild("EggId") then return true end
    if obj.Parent and obj.Parent.Name:lower():find("egg") then return true end
    return false
end

local function getEggData(obj)
    local part = obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")) or obj
    if not part then return nil end

    local rarity = obj:GetAttribute("Rarity") or obj:GetAttribute("EggRarity")
        or (obj:FindFirstChild("Rarity") and obj.Rarity.Value)
        or "Common"

    rarity = tostring(rarity)
    local rank = RarityRank[rarity] or 1
    local size = part.Size.Magnitude
    local dist = Root and (Root.Position - part.Position).Magnitude or 9999

    return {
        part  = part,
        model = obj,
        rarity = rarity,
        rank  = rank,
        size  = size,
        dist  = dist,
        score = (rank * 1000) + (size * 8) - (dist * 0.15)
    }
end

local function findBestEgg()
    if not refreshCharacter() then return nil end
    local candidates = {}
    for _, obj in pairs(Workspace:GetDescendants()) do
        if isEgg(obj) then
            local data = getEggData(obj)
            if data and data.rank >= Config.MinRarityRank then
                if not Config.OnlyBigEggs or data.size > 6 then
                    table.insert(candidates, data)
                end
            end
        end
    end
    if #candidates == 0 then return nil end

    table.sort(candidates, function(a, b)
        if Config.Priority == "Rarest" then
            return a.rank > b.rank or (a.rank == b.rank and a.size > b.size)
        elseif Config.Priority == "Biggest" then
            return a.size > b.size
        elseif Config.Priority == "Nearest" then
            return a.dist < b.dist
        else
            return a.score > b.score
        end
    end)
    return candidates[1]
end

-- ====================== STEAL ======================
local function firePickup(eggData)
    local target = eggData.model or eggData.part
    local prompt = target:FindFirstChildOfClass("ProximityPrompt") or target:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then
        pcall(fireproximityprompt, prompt)
    end

    local containers = {ReplicatedStorage, ReplicatedStorage:FindFirstChild("Remotes"), ReplicatedStorage:FindFirstChild("Events")}
    for _, container in pairs(containers) do
        if container then
            for _, remote in pairs(container:GetDescendants()) do
                if remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction") then
                    local n = remote.Name:lower()
                    if n:find("steal") or n:find("pickup") or n:find("egg") or n:find("collect") or n:find("grab") then
                        pcall(function() remote:FireServer(target) end)
                        pcall(function() remote:FireServer(target.Name) end)
                        pcall(function() remote:FireServer(eggData.part) end)
                    end
                end
            end
        end
    end
end

local function stealEgg(eggData)
    if not eggData or not refreshCharacter() then return false end
    stats.lastEgg = eggData.rarity .. " (" .. math.floor(eggData.size) .. ")"

    local targetCF = eggData.part.CFrame + Vector3.new(0, 3.5, 0)
    if Config.InstantSteal then
        tp(targetCF)
    else
        tweenTP(targetCF, 420)
    end

    task.wait(0.12 + math.random() * 0.08)
    firePickup(eggData)
    task.wait(0.25)

    local plot = getPlot()
    if plot then
        local returnPart = plot:FindFirstChild("Spawn")
            or plot:FindFirstChildWhichIsA("SpawnLocation")
            or plot.PrimaryPart
            or plot:FindFirstChildWhichIsA("BasePart")
        if returnPart then
            local returnCF = returnPart.CFrame + Vector3.new(0, 5, 0)
            if Config.InstantSteal then
                tp(returnCF)
            else
                tweenTP(returnCF, 380)
            end
        end
    end

    stats.stolen += 1
    return true
end

-- ====================== AUTO FARM ======================
local function startAutoSteal()
    if autoStealConnection then
        autoStealConnection:Disconnect()
        autoStealConnection = nil
    end

    autoStealConnection = RunService.Heartbeat:Connect(function()
        if not Config.AutoSteal then return end
        if not refreshCharacter() then return end

        local egg = findBestEgg()
        if egg then
            local success = stealEgg(egg)
            if not success then stats.failed += 1 end
            local delay = Config.StealDelay + (math.random() * Config.Jitter)
            task.wait(delay)
        end
    end)
end

-- ====================== ESP ======================
local function clearESP()
    if ESPFolder then ESPFolder:ClearAllChildren() end
end

local function createESP(part, text, color)
    local bill = Instance.new("BillboardGui")
    bill.Adornee = part
    bill.Size = UDim2.new(0, 220, 0, 40)
    bill.StudsOffset = Vector3.new(0, 2.5, 0)
    bill.AlwaysOnTop = true
    bill.Parent = ESPFolder

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = color
    label.TextStrokeTransparency = 0.35
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.Parent = bill
end

local function updateESP()
    if not Config.ESPEnabled or not refreshCharacter() then
        clearESP()
        return
    end
    clearESP()
    for _, obj in pairs(Workspace:GetDescendants()) do
        if isEgg(obj) then
            local data = getEggData(obj)
            if data then
                local col = RarityColor[data.rarity] or Color3.fromRGB(255, 255, 100)
                local txt = string.format("%s  •  %.1f  •  %dm", data.rarity, data.size, math.floor(data.dist))
                createESP(data.part, txt, col)
            end
        end
    end
end

-- ====================== MOVEMENT ======================
local function toggleFly(state)
    Config.Fly = state
    if not refreshCharacter() then return end

    if flyBV then flyBV:Destroy() flyBV = nil end
    if flyBG then flyBG:Destroy() flyBG = nil end

    if state then
        flyBV = Instance.new("BodyVelocity")
        flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        flyBV.Velocity = Vector3.zero
        flyBV.Parent = Root

        flyBG = Instance.new("BodyGyro")
        flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
        flyBG.P = 3e4
        flyBG.Parent = Root
    end
end

RunService.RenderStepped:Connect(function()
    if Config.Fly and flyBV and refreshCharacter() then
        local move = Vector3.zero
        local camCF = Camera.CFrame
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.yAxis end
        if move.Magnitude > 0 then
            flyBV.Velocity = move.Unit * Config.FlySpeed
        else
            flyBV.Velocity = Vector3.zero
        end
        if flyBG then flyBG.CFrame = camCF end
    end
end)

RunService.Stepped:Connect(function()
    if Config.Noclip and Character then
        for _, p in pairs(Character:GetDescendants()) do
            if p:IsA("BasePart") then
                p.CanCollide = false
            end
        end
    end
end)

UserInputService.JumpRequest:Connect(function()
    if Config.InfiniteJump and Humanoid then
        Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

RunService.Heartbeat:Connect(function()
    if Config.AntiFling and Root then
        if Root.AssemblyLinearVelocity.Magnitude > 180 then
            Root.AssemblyLinearVelocity = Vector3.zero
            Root.AssemblyAngularVelocity = Vector3.zero
        end
    end
end)

RunService.Heartbeat:Connect(function()
    if Humanoid and Config.WalkSpeed ~= 16 then
        Humanoid.WalkSpeed = Config.WalkSpeed
    end
end)

-- ====================== UI HELPERS ======================
local function tween(obj, props, duration, style, dir)
    local info = TweenInfo.new(duration or 0.25, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out)
    local t = TweenService:Create(obj, info, props)
    t:Play()
    return t
end

local function createCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = parent
    return c
end

local function createStroke(parent, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or Theme.Stroke
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0.3
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = parent
    return s
end

local function createPadding(parent, t, b, l, r)
    local p = Instance.new("UIPadding")
    p.PaddingTop = UDim.new(0, t or 0)
    p.PaddingBottom = UDim.new(0, b or 0)
    p.PaddingLeft = UDim.new(0, l or 0)
    p.PaddingRight = UDim.new(0, r or 0)
    p.Parent = parent
    return p
end

-- ====================== STARLIGHT GUI ======================
local function createGUI()
    if CoreGui:FindFirstChild("StarlightHub") then
        CoreGui.StarlightHub:Destroy()
    end

    ESPFolder = Instance.new("Folder")
    ESPFolder.Name = "Starlight_ESP"
    ESPFolder.Parent = CoreGui

    local gui = Instance.new("ScreenGui")
    gui.Name = "StarlightHub"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = CoreGui

    -- Main Frame
    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.new(0, 340, 0, 0) -- starts collapsed for animation
    main.Position = UDim2.new(0, 22, 0.22, 0)
    main.BackgroundColor3 = Theme.Background
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Parent = gui
    createCorner(main, 14)
    createStroke(main, Theme.Accent, 1.5, 0.55)

    -- Glow accent line at top
    local accentLine = Instance.new("Frame")
    accentLine.Size = UDim2.new(1, 0, 0, 3)
    accentLine.Position = UDim2.new(0, 0, 0, 0)
    accentLine.BackgroundColor3 = Theme.Accent
    accentLine.BorderSizePixel = 0
    accentLine.Parent = main
    createCorner(accentLine, 2)

    -- Header
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 52)
    header.BackgroundColor3 = Theme.Surface
    header.BorderSizePixel = 0
    header.Parent = main
    createCorner(header, 14)

    -- Fix bottom corners of header
    local headerFix = Instance.new("Frame")
    headerFix.Size = UDim2.new(1, 0, 0, 16)
    headerFix.Position = UDim2.new(0, 0, 1, -16)
    headerFix.BackgroundColor3 = Theme.Surface
    headerFix.BorderSizePixel = 0
    headerFix.Parent = header

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 1, 0)
    title.Position = UDim2.new(0, 16, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "✦  STARLIGHT HUB"
    title.TextColor3 = Theme.TextPrimary
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -70, 0, 16)
    subtitle.Position = UDim2.new(0, 18, 0, 30)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "Steal An Egg  •  v1.0"
    subtitle.TextColor3 = Theme.TextMuted
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 11
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = header

    -- Minimize button
    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 32, 0, 32)
    minBtn.Position = UDim2.new(1, -44, 0, 10)
    minBtn.BackgroundColor3 = Theme.SurfaceAlt
    minBtn.Text = "–"
    minBtn.TextColor3 = Theme.TextSecondary
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 18
    minBtn.Parent = header
    createCorner(minBtn, 8)

    -- Status bar
    local statusBar = Instance.new("Frame")
    statusBar.Name = "StatusBar"
    statusBar.Size = UDim2.new(1, -24, 0, 48)
    statusBar.Position = UDim2.new(0, 12, 0, 62)
    statusBar.BackgroundColor3 = Theme.Surface
    statusBar.BorderSizePixel = 0
    statusBar.Parent = main
    createCorner(statusBar, 10)
    createStroke(statusBar, Theme.Stroke, 1, 0.4)

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "Status"
    statusLabel.Size = UDim2.new(1, -16, 1, 0)
    statusLabel.Position = UDim2.new(0, 12, 0, 0)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Stolen: 0   •   Failed: 0\nLast: None"
    statusLabel.TextColor3 = Theme.TextSecondary
    statusLabel.Font = Enum.Font.GothamMedium
    statusLabel.TextSize = 12
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextYAlignment = Enum.TextYAlignment.Center
    statusLabel.Parent = statusBar

    -- Content container
    local content = Instance.new("ScrollingFrame")
    content.Name = "Content"
    content.Size = UDim2.new(1, -24, 0, 380)
    content.Position = UDim2.new(0, 12, 0, 120)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 3
    content.ScrollBarImageColor3 = Theme.Accent
    content.CanvasSize = UDim2.new(0, 0, 0, 0)
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    content.Parent = main

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 8)
    listLayout.Parent = content

    createPadding(content, 0, 12, 0, 4)

    -- Section helper
    local function createSection(name, order)
        local section = Instance.new("Frame")
        section.Name = name
        section.Size = UDim2.new(1, 0, 0, 0)
        section.AutomaticSize = Enum.AutomaticSize.Y
        section.BackgroundTransparency = 1
        section.LayoutOrder = order
        section.Parent = content

        local headerLabel = Instance.new("TextLabel")
        headerLabel.Size = UDim2.new(1, 0, 0, 22)
        headerLabel.BackgroundTransparency = 1
        headerLabel.Text = name:upper()
        headerLabel.TextColor3 = Theme.AccentSoft
        headerLabel.Font = Enum.Font.GothamBold
        headerLabel.TextSize = 11
        headerLabel.TextXAlignment = Enum.TextXAlignment.Left
        headerLabel.Parent = section

        local sectionList = Instance.new("UIListLayout")
        sectionList.SortOrder = Enum.SortOrder.LayoutOrder
        sectionList.Padding = UDim.new(0, 6)
        sectionList.Parent = section

        local pad = Instance.new("UIPadding")
        pad.PaddingTop = UDim.new(0, 24)
        pad.Parent = section

        return section
    end

    -- Toggle helper with smooth animation
    local function addToggle(parent, text, default, callback, order)
        local btn = Instance.new("TextButton")
        btn.Name = text
        btn.Size = UDim2.new(1, 0, 0, 38)
        btn.BackgroundColor3 = Theme.Surface
        btn.Text = ""
        btn.AutoButtonColor = false
        btn.LayoutOrder = order or 0
        btn.Parent = parent
        createCorner(btn, 9)
        createStroke(btn, Theme.Stroke, 1, 0.45)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -70, 1, 0)
        label.Position = UDim2.new(0, 14, 0, 0)
        label.BackgroundTransparency = 1
        label.Text = text
        label.TextColor3 = Theme.TextPrimary
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = btn

        -- Toggle track
        local track = Instance.new("Frame")
        track.Size = UDim2.new(0, 42, 0, 22)
        track.Position = UDim2.new(1, -54, 0.5, -11)
        track.BackgroundColor3 = default and Theme.Accent or Theme.SurfaceAlt
        track.BorderSizePixel = 0
        track.Parent = btn
        createCorner(track, 11)

        local knob = Instance.new("Frame")
        knob.Size = UDim2.new(0, 16, 0, 16)
        knob.Position = default and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        knob.BorderSizePixel = 0
        knob.Parent = track
        createCorner(knob, 8)

        local state = default

        local function setState(v, animate)
            state = v
            local trackColor = state and Theme.Accent or Theme.SurfaceAlt
            local knobPos = state and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
            if animate then
                tween(track, {BackgroundColor3 = trackColor}, 0.22)
                tween(knob, {Position = knobPos}, 0.22, Enum.EasingStyle.Back)
            else
                track.BackgroundColor3 = trackColor
                knob.Position = knobPos
            end
            callback(state)
        end

        btn.MouseButton1Click:Connect(function()
            setState(not state, true)
        end)

        -- Hover effect
        btn.MouseEnter:Connect(function()
            tween(btn, {BackgroundColor3 = Theme.SurfaceAlt}, 0.18)
        end)
        btn.MouseLeave:Connect(function()
            tween(btn, {BackgroundColor3 = Theme.Surface}, 0.18)
        end)

        return setState
    end

    -- Input helper
    local function addInput(parent, placeholder, default, callback, order)
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, 0, 0, 38)
        box.BackgroundColor3 = Theme.Surface
        box.Text = tostring(default)
        box.PlaceholderText = placeholder
        box.TextColor3 = Theme.TextPrimary
        box.PlaceholderColor3 = Theme.TextMuted
        box.Font = Enum.Font.GothamMedium
        box.TextSize = 13
        box.ClearTextOnFocus = false
        box.LayoutOrder = order or 0
        box.Parent = parent
        createCorner(box, 9)
        createStroke(box, Theme.Stroke, 1, 0.45)
        createPadding(box, 0, 0, 14, 14)

        box.Focused:Connect(function()
            tween(box, {BackgroundColor3 = Theme.SurfaceAlt}, 0.15)
        end)
        box.FocusLost:Connect(function()
            tween(box, {BackgroundColor3 = Theme.Surface}, 0.15)
            local n = tonumber(box.Text)
            if n then callback(n) end
        end)
        return box
    end

    -- Build sections
    local farmSection = createSection("Farming", 1)
    addToggle(farmSection, "Auto Steal", false, function(v)
        Config.AutoSteal = v
        if v then
            startAutoSteal()
            notify("Starlight", "Auto Steal enabled")
        else
            notify("Starlight", "Auto Steal disabled")
        end
    end, 1)

    addToggle(farmSection, "Instant Steal", true, function(v)
        Config.InstantSteal = v
    end, 2)

    addToggle(farmSection, "Only Big Eggs", false, function(v)
        Config.OnlyBigEggs = v
    end, 3)

    local visualSection = createSection("Visuals", 2)
    addToggle(visualSection, "Egg ESP", true, function(v)
        Config.ESPEnabled = v
        if not v then clearESP() end
    end, 1)

    local moveSection = createSection("Movement", 3)
    addToggle(moveSection, "Fly", false, function(v)
        toggleFly(v)
    end, 1)

    addToggle(moveSection, "Noclip", false, function(v)
        Config.Noclip = v
    end, 2)

    addToggle(moveSection, "Infinite Jump", false, function(v)
        Config.InfiniteJump = v
    end, 3)

    addToggle(moveSection, "Anti-Fling", true, function(v)
        Config.AntiFling = v
    end, 4)

    local settingsSection = createSection("Settings", 4)
    addInput(settingsSection, "WalkSpeed", Config.WalkSpeed, function(n)
        Config.WalkSpeed = math.clamp(n, 16, 500)
        notify("Starlight", "WalkSpeed → " .. Config.WalkSpeed)
    end, 1)

    addInput(settingsSection, "Fly Speed", Config.FlySpeed, function(n)
        Config.FlySpeed = math.clamp(n, 20, 300)
        notify("Starlight", "FlySpeed → " .. Config.FlySpeed)
    end, 2)

    -- Open animation
    main.Size = UDim2.new(0, 340, 0, 0)
    tween(main, {Size = UDim2.new(0, 340, 0, 520)}, 0.45, Enum.EasingStyle.Quint)

    -- Minimize logic
    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        if minimized then
            tween(main, {Size = UDim2.new(0, 340, 0, 52)}, 0.35, Enum.EasingStyle.Quint)
            minBtn.Text = "+"
        else
            tween(main, {Size = UDim2.new(0, 340, 0, 520)}, 0.4, Enum.EasingStyle.Quint)
            minBtn.Text = "–"
        end
    end)

    -- Hover on minimize
    minBtn.MouseEnter:Connect(function()
        tween(minBtn, {BackgroundColor3 = Theme.AccentDark}, 0.15)
    end)
    minBtn.MouseLeave:Connect(function()
        tween(minBtn, {BackgroundColor3 = Theme.SurfaceAlt}, 0.15)
    end)

    -- Live status updater
    task.spawn(function()
        while task.wait(0.8) do
            if statusLabel and statusLabel.Parent then
                statusLabel.Text = string.format("Stolen: %d   •   Failed: %d\nLast: %s", stats.stolen, stats.failed, stats.lastEgg)
            end
        end
    end)

    -- Dragging
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- ====================== INIT ======================
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.6)
    refreshCharacter()
    if Config.Fly then toggleFly(true) end
end)

refreshCharacter()
createGUI()

task.spawn(function()
    while task.wait(1.8) do
        if Config.ESPEnabled then
            pcall(updateESP)
        end
    end
end)

notify("Starlight Hub", "Loaded successfully ✦")
print("[Starlight Hub] v1.0 ready")
