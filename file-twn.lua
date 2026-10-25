--=====================================================================
--  🥚 STEAL AN EGG  •  AUTO STEAL RAREST EGG
--  • Speed + anti-cheat bypass core  : akkiwi  (kept intact)
--  • Auto-steal / ESP / auto-return  : built on top
--=====================================================================

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")
local VirtualUser       = game:GetService("VirtualUser")

local player = Players.LocalPlayer
local genv   = (type(getgenv) == "function" and getgenv()) or _G

if genv.__SAE_Unload then pcall(genv.__SAE_Unload) end

--=====================================================================
-- CONFIG
--=====================================================================
local CONFIG = {
    Speed       = 500,          -- locked walk speed (bypass keeps it)
    SlowSpeed   = 55,           -- speed used when close to the egg
    AutoSteal   = true,
    AutoReturn  = true,         -- walk home + drop after each steal
    AutoDrop    = true,
    ESP         = true,
    Noclip      = false,
    AntiAFK     = true,
    TargetMode  = "Rarest",     -- "Rarest" | "Nearest"
    MinRarity   = 0,            -- skip eggs below this rarity score
    StealRange  = 14,
    MaxDistance = 6000,
    MoveMode    = "Walk",       -- "Walk" | "Teleport"
    Debug       = false,
    Keybind     = Enum.KeyCode.RightShift,
}

local STATE = {
    running = true,
    phase   = "idle",   -- idle | goToEgg | steal | goHome | drop
    phaseT  = 0,
    egg     = nil,
    stolen  = 0,
    started = os.time(),
    basePos = nil,
    baseT   = 0,
    status  = "idle",
    lastPos = Vector3.new(),
    stuckT  = 0,
}

--=====================================================================
-- UTILS
--=====================================================================
local function notify(txt)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = "Auto Steal", Text = txt, Duration = 3 })
    end)
end

local function char()
    local c = player.Character
    if c and c:FindFirstChildOfClass("Humanoid") and c:FindFirstChild("HumanoidRootPart") then return c end
end

local function rootPos()
    local c = char()
    return c and c.HumanoidRootPart.Position or nil
end

local function distTo(pos)
    local r = rootPos()
    if not r then return math.huge end
    return (r - pos).Magnitude
end

--=====================================================================
--  SPEED + ANTI-CHEAT BYPASS  (akkiwi core, kept intact)
--=====================================================================
local setLock
do
    local lock = CONFIG.Speed

    local missing = {}
    if type(hookmetamethod) ~= "function" then table.insert(missing, "hookmetamethod") end
    if type(hookfunction)   ~= "function" then table.insert(missing, "hookfunction") end
    if type(getgc)          ~= "function" then table.insert(missing, "getgc") end
    if type(islclosure)     ~= "function" then table.insert(missing, "islclosure") end
    if type(debug) ~= "table" or type(debug.info) ~= "function" or type(debug.getupvalues) ~= "function" then
        table.insert(missing, "debug.info/getupvalues")
    end

    local blinded = 0

    if #missing == 0 then
        local oldIndex
        local newIndex = function(self, key, value)
            if lock and key == "WalkSpeed" and value ~= lock then
                local c = player.Character
                if c and self == c:FindFirstChildOfClass("Humanoid") then return end
            end
            return oldIndex(self, key, value)
        end
        if type(newcclosure) == "function" then newIndex = newcclosure(newIndex) end
        oldIndex = hookmetamethod(game, "__newindex", newIndex)

        -- blind the game's movement sampler
        local targets = {}
        for _, fn in next, getgc() do
            if typeof(fn) == "function" and islclosure(fn) then
                local okSrc, src = pcall(debug.info, fn, "s")
                if okSrc and type(src) == "string" and src:find("ContentCatalog%.Runtime") then
                    local okA, params = pcall(debug.info, fn, "a")
                    local okU, ups    = pcall(debug.getupvalues, fn)
                    if okA and params == 3 and okU and type(ups) == "table" and #ups == 5 then
                        table.insert(targets, fn)
                    end
                end
            end
        end

        for _, fn in ipairs(targets) do
            local orig
            local wrapper = function(a, b, c)
                local sample = orig(a, b, c)
                if type(sample) == "table" and sample.WalkSpeed and sample.Position and sample.Timestamp then
                    sample.WalkSpeed = 100000
                end
                return sample
            end
            if type(newlclosure) == "function" then wrapper = newlclosure(wrapper) end
            local ok = pcall(function() orig = hookfunction(fn, wrapper) end)
            if ok and type(orig) == "function" then blinded += 1 end
        end
    else
        warn("[AutoSteal] executor missing: " .. table.concat(missing, ", ") .. " — using plain speed")
    end

    RunService.Heartbeat:Connect(function()
        local c = player.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if hum and hum.WalkSpeed ~= lock then hum.WalkSpeed = lock end
    end)

    if blinded > 0 then
        print(("[AutoSteal] WalkSpeed %d — anti-cheat blinded (%d samplers)"):format(lock, blinded))
    elseif #missing == 0 then
        warn("[AutoSteal] WalkSpeed set, but sampler not found — expect rubber-banding")
    end

    setLock = function(n)
        lock = n
        local c = player.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = n end
    end
end

--=====================================================================
-- RARITY ENGINE
--=====================================================================
local RARITY_WORDS = {
    {"uncommon",2},{"legendary",5},{"transcendent",12},{"mythical",6},
    {"celestial",11},{"heavenly",14},{"angelic",15},{"demonic",15},
    {"divine",7},{"cosmic",13},{"eternal",9},{"secret",8},{"rainbow",16},
    {"mythic",6},{"godly",10},{"event",17},{"epic",4},{"rare",3},
    {"common",1},
}
table.sort(RARITY_WORDS, function(a, b) return #a[1] > #b[1] end)

local function rarityFromText(txt)
    if type(txt) ~= "string" then return nil end
    local low = txt:lower()
    for _, p in ipairs(RARITY_WORDS) do
        if low:find(p[1], 1, true) then return p[2] end
    end
    return nil
end

local function readInfo(inst)
    local score, value, label

    for _, attr in ipairs({ "Rarity", "RarityName", "RarityTier", "Tier" }) do
        local ok, v = pcall(inst.GetAttribute, inst, attr)
        if ok and v ~= nil then
            if type(v) == "number" then
                score, label = v, tostring(v)
            else
                label = tostring(v)
                score = rarityFromText(label) or 1
            end
            break
        end
    end

    for _, attr in ipairs({ "Value", "Income", "Price", "Worth", "Cost" }) do
        local ok, v = pcall(inst.GetAttribute, inst, attr)
        if ok and type(v) == "number" then value = math.max(value or 0, v) end
    end

    for _, child in ipairs(inst:GetChildren()) do
        local n = child.Name:lower()
        if (n == "rarity" or n == "tier") and (child:IsA("StringValue") or child:IsA("NumberValue")) then
            if not score then
                if child:IsA("NumberValue") then score = child.Value
                else score = rarityFromText(child.Value) or 1 end
                label = tostring(child.Value)
            end
        elseif (n == "value" or n == "income" or n == "price") and child:IsA("NumberValue") then
            value = math.max(value or 0, child.Value)
        end
    end

    if not score then score = rarityFromText(inst.Name) end
    return score, value, label
end

local function looksLikeEgg(inst)
    if not (inst:IsA("Model") or inst:IsA("BasePart")) then return false end
    local c = char()
    if c and inst:IsDescendantOf(c) then return false end

    local s, v = readInfo(inst)
    if s or v then return true end

    if inst:IsA("BasePart") then
        local sz = inst.Size
        if math.max(sz.X, sz.Y, sz.Z) > 60 then return false end
    end

    for _, tag in ipairs({ "Egg", "Eggs", "Nest" }) do
        if CollectionService:HasTag(inst, tag) then return true end
    end

    local parentName = inst.Parent and inst.Parent.Name:lower() or ""
    if parentName:find("egg") or parentName:find("nest") then return true end
    if inst.Name:lower():find("egg") then return true end

    return false
end

--=====================================================================
-- EGG SCANNER
--=====================================================================
local function eggPosition(inst)
    if inst:IsA("Model") then
        local ok, pivot = pcall(function() return inst:GetPivot().Position end)
        if ok and pivot then return pivot end
        if inst.PrimaryPart then return inst.PrimaryPart.Position end
        local p = inst:FindFirstChildWhichIsA("BasePart")
        return p and p.Position
    end
    return inst.Position
end

local function scanEggs()
    local out = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if looksLikeEgg(inst) then
            local s, v, label = readInfo(inst)
            local pos = eggPosition(inst)
            if pos then
                local score = (s or 0) * 1e6 + (v or 0)
                if s == nil and v == nil then score = 1 end
                table.insert(out, { inst = inst, pos = pos, score = score, rarity = s, value = v, label = label, name = inst.Name })
            end
        end
    end
    return out
end

local cachedEggs, lastScan = {}, 0

local function getEggs()
    if os.clock() - lastScan > 0.6 then
        cachedEggs = scanEggs()
        lastScan = os.clock()
    end
    return cachedEggs
end

local function pickEgg()
    local best, bestScore
    for _, e in ipairs(getEggs()) do
        if e.inst.Parent then
            local d = distTo(e.pos)
            if d <= CONFIG.MaxDistance then
                local rar = e.rarity or 0
                if rar >= CONFIG.MinRarity then
                    local key
                    if CONFIG.TargetMode == "Nearest" then key = -d
                    else key = e.score end
                    if not bestScore or key > bestScore then
                        best, bestScore = e, key
                    end
                end
            end
        end
    end
    return best
end

--=====================================================================
-- BASE / RETURN
--=====================================================================
local function findBase()
    local name = player.Name:lower()
    local disp = player.DisplayName:lower()
    local best, bestScore

    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") or inst:IsA("BasePart") then
            local c = char()
            if not (c and inst:IsDescendantOf(c)) then
                local n = inst.Name:lower()
                local score = 0
                if n:find("base") or n:find("plot") or n:find("pen") or n:find("home") then score += 5 end
                if n:find(name, 1, true) or (disp ~= "" and n:find(disp, 1, true)) then score += 4 end
                if score > 0 then
                    local pos = eggPosition(inst)
                    if pos and (not bestScore or score > bestScore) then
                        best, bestScore = pos, score
                    end
                end
            end
        end
    end
    return best
end

local function getBase()
    if not STATE.basePos or os.clock() - STATE.baseT > 8 then
        STATE.basePos = findBase()
        STATE.baseT = os.clock()
    end
    return STATE.basePos
end

--=====================================================================
-- INTERACTION
--=====================================================================
local function firePrompts(inst)
    if not inst then return end
    local list = {}
    if inst:IsA("Model") or inst:IsA("Folder") or inst:IsA("BasePart") then
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("ProximityPrompt") then table.insert(list, d) end
        end
        if inst:IsA("BasePart") then
            for _, d in ipairs(inst:GetChildren()) do
                if d:IsA("ProximityPrompt") then table.insert(list, d) end
            end
        end
    end
    for _, p in ipairs(list) do
        if type(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, p)
        else
            pcall(function() p:InputHoldBegin(); task.wait(p.HoldDuration or 0); p:InputHoldEnd() end)
        end
    end
end

local function fireClicks(inst)
    if not inst then return end
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("ClickDetector") and type(fireclickdetector) == "function" then
            pcall(fireclickdetector, d)
        end
    end
end

local function trySteal(egg)
    if not egg then return end
    firePrompts(egg.inst)
    fireClicks(egg.inst)
    if egg.inst.Parent and egg.inst.Parent ~= Workspace then
        firePrompts(egg.inst.Parent)
        fireClicks(egg.inst.Parent)
    end
end

--=====================================================================
-- MOVEMENT
--=====================================================================
local function stepTowards(pos)
    local c = char()
    if not c then return false end
    local hum = c:FindFirstChildOfClass("Humanoid")
    local root = c.HumanoidRootPart
    local d = (root.Position - pos).Magnitude

    if d < 3 then return true end

    if CONFIG.MoveMode == "Teleport" then
        root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
        return d < 8
    end

    setLock(d < 40 and CONFIG.SlowSpeed or CONFIG.Speed)
    hum:MoveTo(pos)

    -- unstick
    if (root.Position - STATE.lastPos).Magnitude < 2 then
        STATE.stuckT += 0.1
        if STATE.stuckT > 0.7 then
            hum.Jump = true
            STATE.stuckT = 0
        end
    else
        STATE.stuckT = 0
    end
    STATE.lastPos = root.Position
    return false
end

--=====================================================================
-- ESP
--=====================================================================
local espFolder
do
    espFolder = Instance.new("Folder")
    espFolder.Name = "SAE_ESP"
    espFolder.Parent = Workspace
end

local function rarityColor(score)
    local r = math.clamp((score or 0) / 17, 0, 1)
    return Color3.fromHSV((1 - r) * 0.62, 0.85, 1)  -- red -> green
end

local function updateESP()
    for _, hl in ipairs(espFolder:GetChildren()) do
        if not hl.Adornee or not hl.Adornee.Parent then hl:Destroy() end
    end

    if not CONFIG.ESP then return end

    local eggs = getEggs()
    table.sort(eggs, function(a, b) return a.score > b.score end)

    for i = 1, math.min(#eggs, 25) do
        local e = eggs[i]
        local tag = "HL_" .. tostring(e.inst:GetDebugId and e.inst:GetDebugId() or i)
        local hl = espFolder:FindFirstChild(tag)
        if not hl then
            hl = Instance.new("Highlight")
            hl.Name = tag
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.FillTransparency = 0.55
            hl.OutlineTransparency = 0
            hl.Parent = espFolder
        end
        hl.Adornee = e.inst
        local col = rarityColor(e.rarity or 1)
        hl.FillColor = col
        hl.OutlineColor = col
    end
end

--=====================================================================
-- MAIN LOOP
--=====================================================================
local function tick(dt)
    if not CONFIG.AutoSteal then STATE.status = "paused"; return end

    local c = char()
    if not c then STATE.status = "respawning"; return end

    if STATE.phase == "idle" then
        local egg = pickEgg()
        if egg then
            STATE.egg = egg
            STATE.phase = "goToEgg"
            STATE.phaseT = 0
        else
            STATE.status = "no eggs found"
        end

    elseif STATE.phase == "goToEgg" then
        local egg = STATE.egg
        if not egg or not egg.inst.Parent then
            STATE.phase = "idle"
            return
        end
        STATE.status = ("stealing [%s]"):format(egg.name)
        if distTo(egg.pos) < CONFIG.StealRange or STATE.phaseT > 20 then
            STATE.phase = "steal"
            STATE.phaseT = 0
        else
            stepTowards(egg.pos)
        end

    elseif STATE.phase == "steal" then
        STATE.status = "grabbing"
        trySteal(STATE.egg)
        if STATE.phaseT > 1 then
            STATE.stolen += 1
            if CONFIG.AutoReturn then
                STATE.phase = "goHome"
            else
                STATE.phase = "idle"
            end
            STATE.phaseT = 0
        end

    elseif STATE.phase == "goHome" then
        local base = getBase()
        if not base then STATE.phase = "idle"; return end
        STATE.status = "returning to base"
        if distTo(base) < 14 or STATE.phaseT > 25 then
            STATE.phase = "drop"
            STATE.phaseT = 0
        else
            stepTowards(base)
        end

    elseif STATE.phase == "drop" then
        STATE.status = "dropping"
        if CONFIG.AutoDrop then
            trySteal(STATE.egg)
            firePrompts(Workspace)
        end
        if STATE.phaseT > 0.6 then
            STATE.phase = "idle"
            STATE.phaseT = 0
        end
    end
end

local function mainLoop()
    local last = os.clock()
    while STATE.running do
        local now = os.clock()
        local dt = now - last
        last = now
        STATE.phaseT += dt
        pcall(tick, dt)
        task.wait(0.1)
    end
end

--=====================================================================
-- NOCLIP + ANTI-AFK
--=====================================================================
RunService.Stepped:Connect(function()
    if not CONFIG.Noclip then return end
    local c = char()
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end)

player.Idled:Connect(function()
    if not CONFIG.AntiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

--=====================================================================
-- GUI
--=====================================================================
local function guiParent()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return player:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "SAE_AutoSteal"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = guiParent()

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(232, 348)
main.Position = UDim2.new(0, 18, 0.28, 0)
main.BackgroundColor3 = Color3.fromRGB(23, 25, 32)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 32)
title.BackgroundColor3 = Color3.fromRGB(33, 36, 46)
title.BorderSizePixel = 0
title.Text = "  🥚 Auto Steal Rarest Egg"
title.TextColor3 = Color3.fromRGB(235, 238, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 10)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -16, 1, -44)
body.Position = UDim2.new(0, 8, 0, 38)
body.BackgroundTransparency = 1
body.Parent = main

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local function row(label, value, col)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 26)
    f.BackgroundColor3 = Color3.fromRGB(31, 34, 43)
    f.BorderSizePixel = 0
    f.Parent = body
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)

    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(0.6, 0, 1, 0)
    t.Position = UDim2.new(0, 8, 0, 0)
    t.BackgroundTransparency = 1
    t.Text = label
    t.TextColor3 = Color3.fromRGB(210, 215, 225)
    t.Font = Enum.Font.Gotham
    t.TextSize = 12
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = f

    local v = Instance.new("TextButton")
    v.Size = UDim2.new(0.32, 0, 0, 18)
    v.Position = UDim2.new(0.64, 0, 0, 4)
    v.BackgroundColor3 = col or Color3.fromRGB(58, 62, 76)
    v.Text = value
    v.TextColor3 = Color3.fromRGB(240, 243, 250)
    v.Font = Enum.Font.GothamBold
    v.TextSize = 11
    v.BorderSizePixel = 0
    v.AutoButtonColor = true
    v.Parent = f
    Instance.new("UICorner", v).CornerRadius = UDim.new(0, 5)
    return v, f
end

local function toggle(label, key)
    local on = CONFIG[key]
    local btn = row(label, on and "ON" or "OFF", on and Color3.fromRGB(60, 150, 90) or Color3.fromRGB(120, 60, 60))
    btn.MouseButton1Click:Connect(function()
        CONFIG[key] = not CONFIG[key]
        btn.Text = CONFIG[key] and "ON" or "OFF"
        btn.BackgroundColor3 = CONFIG[key] and Color3.fromRGB(60, 150, 90) or Color3.fromRGB(120, 60, 60)
    end)
    return btn
end

toggle("Auto Steal", "AutoSteal")
toggle("Auto Return", "AutoReturn")
toggle("Auto Drop", "AutoDrop")
toggle("ESP Highlight", "ESP")
toggle("Noclip", "Noclip")
toggle("Anti-AFK", "AntiAFK")

local modeBtn = row("Target Mode", CONFIG.TargetMode, Color3.fromRGB(58, 80, 130))
modeBtn.MouseButton1Click:Connect(function()
    CONFIG.TargetMode = (CONFIG.TargetMode == "Rarest") and "Nearest" or "Rarest"
    modeBtn.Text = CONFIG.TargetMode
end)

local moveBtn = row("Movement", CONFIG.MoveMode, Color3.fromRGB(58, 80, 130))
moveBtn.MouseButton1Click:Connect(function()
    CONFIG.MoveMode = (CONFIG.MoveMode == "Walk") and "Teleport" or "Walk"
    moveBtn.Text = CONFIG.MoveMode
end)

-- speed slider
local speedFrame = Instance.new("Frame")
speedFrame.Size = UDim2.new(1, 0, 0, 40)
speedFrame.BackgroundColor3 = Color3.fromRGB(31, 34, 43)
speedFrame.BorderSizePixel = 0
speedFrame.Parent = body
Instance.new("UICorner", speedFrame).CornerRadius = UDim.new(0, 6)

local speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(1, -16, 0, 18)
speedLabel.Position = UDim2.new(0, 8, 0, 2)
speedLabel.BackgroundTransparency = 1
speedLabel.Text = "Speed: " .. CONFIG.Speed
speedLabel.TextColor3 = Color3.fromRGB(210, 215, 225)
speedLabel.Font = Enum.Font.Gotham
speedLabel.TextSize = 12
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.Parent = speedFrame

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, -16, 0, 8)
bar.Position = UDim2.new(0, 8, 0, 24)
bar.BackgroundColor3 = Color3.fromRGB(55, 59, 72)
bar.BorderSizePixel = 0
bar.Parent = speedFrame
Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

local fill = Instance.new("Frame")
fill.Size = UDim2.new((CONFIG.Speed - 50) / 950, 0, 1, 0)
fill.BackgroundColor3 = Color3.fromRGB(90, 160, 240)
fill.BorderSizePixel = 0
fill.Parent = bar
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

local dragging = false
bar.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = true
    end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(i)
    if not dragging then return end
    if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
        local rel = math.clamp((i.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local spd = math.floor(50 + rel * 950)
        CONFIG.Speed = spd
        setLock(spd)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        speedLabel.Text = "Speed: " .. spd
    end
end)

local stats = Instance.new("TextLabel")
stats.Size = UDim2.new(1, 0, 0, 34)
stats.BackgroundTransparency = 1
stats.Text = "idle"
stats.TextColor3 = Color3.fromRGB(150, 200, 160)
stats.Font = Enum.Font.Code
stats.TextSize = 11
stats.TextWrapped = true
stats.Parent = body

--=====================================================================
-- KEYBIND + UNLOAD
--=====================================================================
UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == CONFIG.Keybind then
        CONFIG.AutoSteal = not CONFIG.AutoSteal
        notify("Auto Steal: " .. (CONFIG.AutoSteal and "ON" or "OFF"))
    end
end)

genv.__SAE_Unload = function()
    STATE.running = false
    pcall(function() gui:Destroy() end)
    pcall(function() espFolder:Destroy() end)
    genv.__SAE_Unload = nil
    print("[AutoSteal] unloaded")
end

--=====================================================================
-- GO
--=====================================================================
task.spawn(mainLoop)
task.spawn(function()
    while STATE.running do
        updateESP()
        local mins = math.floor((os.time() - STATE.started) / 60)
        stats.Text = ("stolen: %d  •  %02dm%02ds\n%s"):format(
            STATE.stolen,
            mins,
            (os.time() - STATE.started) % 60,
            STATE.status
        )
        task.wait(0.4)
    end
end)

notify("Auto Steal Rarest Egg loaded — " .. tostring(CONFIG.Keybind.Name) .. " toggles")
print("[AutoSteal] ready. Eggs found: " .. #getEggs())