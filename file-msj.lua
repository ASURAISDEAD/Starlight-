--[[
================================================================================
  STEAL AN EGG  |  BAC-SAFE  |  v1.1.0
--------------------------------------------------------------------------------
  Rewritten against verified BAC-safe movement rules:
    * NEVER write position  (no teleport)
    * NEVER anchor
    * NEVER touch WalkSpeed in normal mode
    * Real Humanoid:MoveTo + PathfindingService
    * Optional FastMode: tween WITHOUT anchoring, capped at 2x real WalkSpeed
    * Client-side :Kick blocker

  Load:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/USER/REPO/main/StealAnEgg.lua"))()

  NOTE: death = NO RESPAWN in this game. If you die, you must rejoin.
  RightShift toggles the panel. Unload from the Misc tab. MIT.
================================================================================
]]

if getgenv and getgenv().SAE_Unload then pcall(getgenv().SAE_Unload) end

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")
local TeleportService   = game:GetService("TeleportService")
local VirtualInput      = game:GetService("VirtualInputManager")
local PathfindingService= game:GetService("PathfindingService")
local TweenService      = game:GetService("TweenService")
local player            = Players.LocalPlayer

--============================== CONFIG ===============================
-- BAC-SAFE DEFAULTS: walking only, nothing else touched.
local CONFIG = {
    -- Farm
    AutoSteal = false, Priority = "Rarest", OnlySelected = false, Selected = {},
    MinRarity = "Common",
    -- Movement  (the only "speed" concept is FastMode's multiplier)
    FastMode = false, FastMult = 2.0, ReturnHome = true, StealDelay = 0.25,
    -- Automation
    AutoHatch = false, AutoSell = false, AutoCollect = false, AutoClaim = false,
    AutoBuy = false, AutoTrain = false, TrainEvery = 25,
    -- Visuals
    ESP = false, ESPNames = true, ESPXray = true,
    -- Protection
    AntiAFK = true, AntiRagdoll = true, AntiTrap = true,
    AntiKick = true,        -- client-side :Kick blocker (cannot block server BAC)
    DetectorFreeze = false, -- optional legacy integrity-state freeze
    -- Server
    AutoHop = false, HopAfter = 45,
    RescanEvery = 1.0,
}

local RARITY_RANK = {
    Common=1, Uncommon=2, Rare=3, Epic=4, Legendary=5, Mythic=6,
    Cosmic=7, Secret=8, Eternal=9, Divine=10, Huge=11, Godly=12,
}
local RARITY_COLOR = {
    Common=Color3.fromRGB(180,180,180), Uncommon=Color3.fromRGB(120,220,120),
    Rare=Color3.fromRGB(90,160,255),   Epic=Color3.fromRGB(170,110,255),
    Legendary=Color3.fromRGB(255,180,60), Mythic=Color3.fromRGB(255,90,90),
    Cosmic=Color3.fromRGB(90,240,240), Secret=Color3.fromRGB(255,105,220),
    Eternal=Color3.fromRGB(255,230,120), Divine=Color3.fromRGB(255,255,255),
    Huge=Color3.fromRGB(255,140,0),    Godly=Color3.fromRGB(255,215,0),
}

--============================= UTIL ==================================
local status = "Idle"
local function setStatus(s) status = s end
local function notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 3 })
    end)
end

local function normalizeRarity(r)
    if type(r) ~= "string" then return nil end
    local clean = r:gsub("[^%a]", ""):lower()
    for name in pairs(RARITY_RANK) do
        if clean == name:lower() then return name end
    end
    return nil
end

local VIM = VirtualInput
local function click(btn)
    if not btn or not btn:IsA("GuiButton") then return end
    local done = false
    if getconnections then
        done = pcall(function()
            for _, c in ipairs(getconnections(btn.MouseButton1Click)) do
                if c.Function then c.Function(btn) end
            end
        end)
    end
    if not done or not getconnections then
        pcall(function()
            local p = btn.AbsolutePosition + btn.AbsoluteSize / 2
            VIM:SendMouseButtonEvent(p.X, p.Y, 0,true, game, 1)
            VIM:SendMouseButtonEvent(p.X, p.Y, 0,false, game, 1)
        end)
    end
end

local function firePrompt(prompt)
    if not prompt then return end
    pcall(function()
        prompt:InputHoldBegin()
        task.wait((prompt.HoldDuration or 0) + 0.05)
        prompt:InputHoldEnd()
    end)
end

--============================= EGGS ==================================
local eggCache, lastScan, stuck = {}, 0, {}

local function readRarity(obj)
    for _, k in ipairs({"Rarity","rarity","Tier","tier"}) do
        local n = normalizeRarity(obj:GetAttribute(k))
        if n then return n end
    end
    for _, c in ipairs(obj:GetDescendants()) do
        if c:IsA("StringValue") and c.Name:lower():find("rar") then
            local n = normalizeRarity(c.Value)
            if n then return n end
        end
    end
    return normalizeRarity(obj.Name)
end

local function isInPlot(obj)
    local a = obj.Parent
    while a and a ~= workspace do
        if a:GetAttribute("Owner") ~= nil then return true end
        a = a.Parent
    end
    return false
end

local function asEgg(obj)
    if not obj:IsA("Model") then return nil end
    local part = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
    if not part then return nil end
    local rarity = readRarity(obj)
    if not rarity and not obj.Name:lower():find("egg") then return nil end
    rarity = rarity or "Common"
    return { model = obj, part = part, pos = part.Position,
             name = obj.Name, rarity = rarity, rank = RARITY_RANK[rarity] or 1 }
end

local function scanEggs(force)
    if not force and os.clock() - lastScan < CONFIG.RescanEvery then return eggCache end
    lastScan = os.clock()
    local list, char = {}, player.Character
    for _, d in ipairs(workspace:GetDescendants()) do
        local e = asEgg(d)
        if e and not isInPlot(e.model) and not (char and e.model:IsDescendantOf(char)) then
            table.insert(list, e)
        end
    end
    eggCache = list
    return list
end

--========================== BASE / CARRY =============================
local function isCarrying()
    local char = player.Character
    if not char then return false end
    for _, k in ipairs({"Carrying","IsCarrying","Holding","HasEgg"}) do
        local v = player:GetAttribute(k)
        if type(v) == "boolean" then return v end
    end
    for _, d in ipairs(char:GetChildren()) do
        if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower():find("egg") then return true end
    end
    return false
end

local function getPlot()
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") or c:IsA("Folder") then
            if c:FindFirstChild(player.Name) then return c:FindFirstChild(player.Name) end
            local o = c:GetAttribute("Owner")
            if o == player or o == player.Name then return c end
        end
    end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Model") then
            local o = d:GetAttribute("Owner")
            if o == player or o == player.Name or o == player.UserId then return d end
        end
    end
    return nil
end

local function getPlotPosition(plot)
    if not plot then return nil end
    if plot.PrimaryPart then return plot.PrimaryPart.Position end
    for _, n in ipairs({"Spawn","Base","Plot","Center","Place"}) do
        local c = plot:FindFirstChild(n, true)
        if c and c:IsA("BasePart") then return c.Position end
    end
    local p = plot:FindFirstChildWhichIsA("BasePart", true)
    return p and p.Position or nil
end

--======================= MOVEMENT  (BAC-SAFE) ========================
local function hum() local c = player.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function realWalkSpeed() local h = hum(); return (h and h.WalkSpeed) or 16 end

-- ControlModule fires Humanoid:Move(0,0,0) every frame and fights the bot,
-- causing a ~4 studs/s crawl bug. Disable it while we drive.
local controlsHeld = false
local function getControlModule()
    local ps = player:FindFirstChild("PlayerScripts")
    local pm = ps and ps:FindFirstChild("PlayerModule")
    return pm and pm:FindFirstChild("ControlModule")
end
local function grabControls()
    if controlsHeld then return end
    local cm = getControlModule()
    if cm then pcall(function() cm:Disable() end); controlsHeld = true end
end
local function releaseControls()
    if not controlsHeld then return end
    local cm = getControlModule()
    if cm then pcall(function() cm:Enable() end) end
    controlsHeld = false
end
player.CharacterAdded:Connect(function() controlsHeld = false end)

-- Real walking. Straight line first, jump when stalled, give up after 3s stuck.
local function stepTo(target, timeout)
    local start, lastPos, lastMove = os.clock(), nil, os.clock()
    local h, r = hum(), hrp()
    if not h or not r then return false end
    lastPos = r.Position
    while os.clock() - start < timeout do
        h, r = hum(), hrp()
        if not h or not r then return false end
        local flat = Vector3.new(target.X, r.Position.Y, target.Z)
        if (flat - r.Position).Magnitude < 4 then return true end
        h:MoveTo(flat)
        task.wait(0.1)
        if (r.Position - lastPos).Magnitude < 1 then
            if os.clock() - lastMove > 1 then
                h.Jump = true
                lastMove = os.clock()
            end
            if os.clock() - lastMove > 3 then return false end
        else
            lastPos = r.Position
            lastMove = os.clock()
        end
    end
    return false
end

-- Pathfinding fallback for when the straight charge gets wedged.
local function walkTo(target, timeout)
    timeout = timeout or 40
    if stepTo(target, math.min(timeout, 14)) then return true end
    local r = hrp()
    if not r then return false end
    local ok, path = pcall(function()
        return PathfindingService:CreatePath({
            AgentRadius = 3, AgentHeight = 6, AgentCanJump = true,
            AgentCanClimb = false, WaypointSpacing = 8,
        })
    end)
    if not ok or not path then return stepTo(target, timeout) end
    local computed = pcall(function() path:ComputeAsync(r.Position, target) end)
    if not computed then return stepTo(target, timeout) end
    for _, wp in ipairs(path:GetWaypoints()) do
        if wp.Action == Enum.PathWaypointAction.Jump then
            local h = hum(); if h then h.Jump = true end
        end
        if not stepTo(wp.Position, 10) then return false end
    end
    return true
end

-- FastMode: tween the root CFrame WITHOUT anchoring, WalkSpeed 0 during the
-- move, capped at FastMult x real WalkSpeed. Auto-falls back after 3 failures.
local fastRollbacks = 0
local function fastTo(target)
    local h, r = hum(), hrp()
    if not h or not r then return false end
    local real = h.WalkSpeed
    local speed = math.max(8, real * CONFIG.FastMult)
    local flat = Vector3.new(target.X, r.Position.Y, target.Z)
    local dist = (flat - r.Position).Magnitude
    if dist < 4 then return true end

    h.WalkSpeed = 0
    local startPos = r.Position
    local dur = math.max(0.05, dist / speed)
    local look = (flat - startPos)
    local cf = CFrame.lookAt(flat, flat + (look.Magnitude > 0 and look.Unit or Vector3.new(0,0,1)))
    local tw = TweenService:Create(r, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = cf })
    r.AssemblyLinearVelocity, r.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    tw:Play()
    local t0 = os.clock()
    while tw.PlaybackState == Enum.PlaybackState.Playing and os.clock() - t0 < dur + 3 do
        r.AssemblyLinearVelocity, r.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
        task.wait()
    end
    local hh = hum(); if hh then hh.WalkSpeed = real end

    if (r.Position - startPos).Magnitude < dist * 0.5 then
        fastRollbacks = fastRollbacks + 1
        if fastRollbacks >= 3 then
            CONFIG.FastMode = false
            notify("FastMode off", "Server pushed back — using walking")
        end
        return false
    end
    fastRollbacks = 0
    return true
end

local function goTo(target, timeout)
    if CONFIG.FastMode then
        if fastTo(target) then return true end
    end
    return walkTo(target, timeout)
end

local function tryInteract(egg)
    local prompt = egg.model:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then firePrompt(prompt) end
end

local function pickTarget()
    local list = scanEggs()
    local root = hrp()
    local myPos = root and root.Position
    local minRank = RARITY_RANK[CONFIG.MinRarity] or 1
    local now, best, bestScore = os.clock()
    for _, e in ipairs(list) do
        local blocked  = stuck[e.name] and stuck[e.name] > now
        local filtered = CONFIG.OnlySelected and next(CONFIG.Selected) and not CONFIG.Selected[e.name]
        if e.rank >= minRank and not blocked and not filtered then
            local dist = myPos and (e.pos - myPos).Magnitude or 0
            local score = (CONFIG.Priority == "Nearest") and dist or (-e.rank * 1000 + dist * 0.01)
            if not bestScore or score < bestScore then best, bestScore = e, score end
        end
    end
    return best
end

--======================== KICK BLOCKER (client) ======================
local function nc(f) if newcclosure then return newcclosure(f) end return f end
local function installAntiKick()
    if typeof(getrawmetatable) ~= "function" or not setreadonly then return false end
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = nc(function(self, ...)
            local m = getnamecallmethod()
            if m == "Kick" and typeof(self) == "Instance" and self:IsA("Player") then
                return nil
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
    return ok
end

--===================== OPTIONAL DETECTOR FREEZE ======================
local freezeCleanup = nil
local function enableFreeze()
    if freezeCleanup then return end
    if typeof(filtergc) ~= "function" then
        notify("Detector Freeze", "Executor lacks filtergc")
        return
    end
    local env = getgenv and getgenv() or _G
    local runtime = { active = true, character = nil, state = nil,
                      lastSearch = 0, lastUpdate = 0, speed = 100000, conns = {} }
    local function body(c)
        if not c then return nil, nil end
        return c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
    end
    local function matches(s, c, h, r)
        return type(s) == "table" and rawget(s,"Player") == player and rawget(s,"Character") == c
            and rawget(s,"Humanoid") == h and rawget(s,"RootPart") == r
            and type(rawget(s,"SampleHistory")) == "table" and type(rawget(s,"Evidence")) == "table"
    end
    local function findState(c)
        local h, r = body(c)
        if not h or not r then return nil end
        if matches(env.SAE_Cache, c, h, r) then return env.SAE_Cache end
        local ok, cands = pcall(filtergc, "table",
            { Keys = {"Player","Character","Humanoid","RootPart","SampleHistory","Evidence"} }, false)
        if not ok or type(cands) ~= "table" then return nil end
        for _, cd in ipairs(cands) do
            if matches(cd, c, h, r) then env.SAE_Cache = cd; return cd end
        end
        return nil
    end
    local function sanitize(s, r)
        if type(s) ~= "table" then return end
        local cf = r.CFrame
        rawset(s, "WalkSpeed", runtime.speed)
        rawset(s, "CFrame", cf)
        rawset(s, "Position", cf.Position)
        rawset(s, "LinearVelocity", Vector3.zero)
        rawset(s, "AngularVelocity", Vector3.zero)
    end
    local function update()
        local c = player.Character
        local h, r = body(c)
        if not h or not r then return end
        if runtime.character ~= c then
            runtime.character = c; runtime.state = nil; env.SAE_Cache = nil
        end
        if not matches(runtime.state, c, h, r) then
            if os.clock() - runtime.lastSearch < 1 then return end
            runtime.lastSearch = os.clock(); runtime.state = findState(c)
        end
        local s = runtime.state
        if not s then return end
        for _, n in ipairs({"CurrentSample","LastSample","PreviousSample","LastSafeSample","PreMovementSafeSample"}) do
            sanitize(rawget(s, n), r)
        end
        for _, v in pairs(rawget(s, "SampleHistory") or {}) do sanitize(v, r) end
        for _, v in pairs(rawget(s, "SafeGroundCheckpoints") or {}) do sanitize(v, r) end
        local ev = rawget(s, "Evidence")
        if type(ev) == "table" then ev.Speed = 0; ev.Teleport = 0; ev.Flight = 0 end
    end
    runtime.conns[#runtime.conns+1] = player.CharacterAdded:Connect(function(c)
        runtime.character = c; runtime.state = nil; runtime.lastSearch = 0; env.SAE_Cache = nil
    end)
    runtime.conns[#runtime.conns+1] = RunService.Heartbeat:Connect(function()
        if not runtime.active then return end
        local n = os.clock()
        if n - runtime.lastUpdate < 0.1 then return end
        runtime.lastUpdate = n; pcall(update)
    end)
    task.defer(update)
    freezeCleanup = function()
        runtime.active = false
        for _, c in ipairs(runtime.conns) do pcall(c.Disconnect, c) end
        freezeCleanup = nil
    end
end

--============================= ESP ===================================
local espFolder = Instance.new("Folder")
espFolder.Name = "SAE_ESP"
espFolder.Parent = workspace.CurrentCamera
local espCache, nameCache = {}, {}

local function clearESP()
    for _, h in pairs(espCache) do h:Destroy() end
    for _, b in pairs(nameCache) do b:Destroy() end
    espCache, nameCache = {}, {}
end

local function updateESP()
    if not CONFIG.ESP then return end
    local seen = {}
    for _, e in ipairs(scanEggs()) do
        seen[e.model] = true
        local col = RARITY_COLOR[e.rarity] or Color3.new(1,1,1)
        local h = espCache[e.model]
        if not h then
            h = Instance.new("Highlight")
            h.Name = "SAE_HL"; h.Adornee = e.model
            h.FillTransparency = 0.6; h.OutlineTransparency = 0
            h.Parent = espFolder
            espCache[e.model] = h
        end
        h.FillColor = col; h.OutlineColor = col
        h.DepthMode = CONFIG.ESPXray and Enum.HighlightDepthMode.AlwaysOnTop
                        or Enum.HighlightDepthMode.Occluded
        if CONFIG.ESPNames and e.part then
            local bb = nameCache[e.model]
            if not bb then
                bb = Instance.new("BillboardGui")
                bb.Name = "SAE_Name"; bb.Adornee = e.part
                bb.Size = UDim2.new(0, 110, 0, 20); bb.StudsOffset = Vector3.new(0, 3, 0)
                bb.AlwaysOnTop = CONFIG.ESPXray; bb.Parent = espFolder
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
                lbl.Font = Enum.Font.GothamBold; lbl.TextScaled = true
                lbl.TextColor3 = col; lbl.TextStrokeTransparency = 0.3
                lbl.Parent = bb
                nameCache[e.model] = bb
            end
            local lbl = bb:FindFirstChildOfClass("TextLabel")
            if lbl then lbl.Text = e.name; lbl.TextColor3 = col end
        end
    end
    for m, h in pairs(espCache) do
        if not seen[m] or not m.Parent then h:Destroy(); espCache[m] = nil end
    end
    for m, b in pairs(nameCache) do
        if not seen[m] or not m.Parent then b:Destroy(); nameCache[m] = nil end
    end
end

--=========================== WORLD TASKS =============================
local function findWorldPrompt(keywords)
    local root = hrp()
    if not root then return nil end
    local best, bestDist
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Parent and d.Parent:IsA("BasePart") then
            local nm = (d.Parent.Name .. " " .. (d.ActionText or "")):lower()
            for _, k in ipairs(keywords) do
                if nm:find(k) then
                    local dist = (d.Parent.Position - root.Position).Magnitude
                    if not bestDist or dist < bestDist then best, bestDist = d, dist end
                    break
                end
            end
        end
    end
    return best
end

--========================= UI AUTOMATION =============================
local myGui
local function scanButtons(keywords)
    local out = {}
    for _, d in ipairs(player.PlayerGui:GetDescendants()) do
        if d:IsA("GuiButton") and d.Visible and d.AbsoluteSize.X > 1
           and not (myGui and d:IsDescendantOf(myGui)) then
            local t = ((d.Text ~= "" and d.Text) or d.Name):lower()
            for _, k in ipairs(keywords) do
                if t:find(k) then table.insert(out, d); break end
            end
        end
    end
    return out
end
local function clickKeywords(keywords)
    local n = 0
    for _, b in ipairs(scanButtons(keywords)) do click(b); n = n + 1 end
    return n
end

--========================== PROTECTION ===============================
player.Idled:Connect(function()
    if not CONFIG.AntiAFK then return end
    pcall(function()
        local VU = game:GetService("VirtualUser")
        VU:CaptureController(); VU:ClickButton2(Vector2.new())
    end)
end)

task.spawn(function()
    while task.wait(0.4) do
        if CONFIG.AntiRagdoll then
            local h = hum()
            if h then
                pcall(function()
                    if h:GetState() == Enum.HumanoidStateType.Ragdoll then
                        h:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end
                end)
            end
        end
    end
end)

task.spawn(function()
    local lastPos, lastChange = nil, os.clock()
    while task.wait(0.5) do
        if CONFIG.AntiTrap then
            local r = hrp()
            if r then
                if lastPos and (r.Position - lastPos).Magnitude < 1 then
                    if os.clock() - lastChange > 4 then
                        local h = hum(); if h then h.Jump = true end
                        lastChange = os.clock()
                    end
                else
                    lastChange = os.clock()
                end
                lastPos = r.Position
            end
        else
            lastPos = nil
        end
    end
end)

--============================= HOP ===================================
local lastValid, hopping = os.clock(), false
local function serverHop()
    if hopping then return end
    hopping = true
    notify("Server Hop", "No rare eggs — hopping")
    task.wait(0.5)
    pcall(function() TeleportService:Teleport(game.PlaceId, player) end)
    task.wait(4)
    hopping = false
end

--============================ BRAIN ==================================
local trainReady = 0
local noCharSince = nil

local function brain()
    while task.wait() do
        local active = CONFIG.AutoSteal or CONFIG.AutoTrain
        if not active then
            releaseControls()
            setStatus("Idle")
        else
            local r = hrp()
            if not r then
                if not noCharSince then noCharSince = os.clock() end
                if os.clock() - noCharSince > 4 then
                    setStatus("No character — DIED? rejoin (no respawn)")
                else
                    setStatus("Waiting for character")
                end
                task.wait(0.3)
            else
                noCharSince = nil
                grabControls()
                if isCarrying() and CONFIG.ReturnHome then
                    setStatus("Carrying — returning home")
                    local bp = getPlotPosition(getPlot())
                    if bp then goTo(bp, 45) end
                elseif CONFIG.AutoTrain and os.clock() >= trainReady then
                    local prompt = findWorldPrompt({"treadmill","train","speed"})
                    if prompt then
                        setStatus("Training")
                        goTo(prompt.Parent.Position, 40)
                        firePrompt(prompt)
                        trainReady = os.clock() + CONFIG.TrainEvery
                    else
                        trainReady = os.clock() + 3
                    end
                elseif CONFIG.AutoSteal then
                    local t = pickTarget()
                    if t then
                        lastValid = os.clock()
                        setStatus(("Stealing [%s] %s"):format(t.rarity, t.name))
                        local ok = goTo(t.pos, 45)
                        tryInteract(t)
                        task.wait(CONFIG.StealDelay)
                        if not ok and not isCarrying() then stuck[t.name] = os.clock() + 6 end
                    else
                        setStatus("No matching egg in server")
                    end
                end
            end
        end
    end
end
task.spawn(brain)

task.spawn(function()
    while task.wait(1) do
        if CONFIG.AutoHop and (CONFIG.AutoSteal or CONFIG.AutoTrain)
           and os.clock() - lastValid > CONFIG.HopAfter then
            serverHop()
            lastValid = os.clock()
        end
    end
end)

local autoT = { hatch = 0, sell = 0, collect = 0, claim = 0, buy = 0 }
task.spawn(function()
    while task.wait(0.5) do
        local n = os.clock()
        if CONFIG.AutoHatch and n - autoT.hatch > 1 then
            clickKeywords({"hatch all","hatch"}); autoT.hatch = n
        end
        if CONFIG.AutoSell and n - autoT.sell > 2 then
            clickKeywords({"sell all","sell"}); autoT.sell = n
        end
        if CONFIG.AutoCollect and n - autoT.collect > 2 then
            clickKeywords({"claim all","claim","collect","reward"}); autoT.collect = n
        end
        if CONFIG.AutoClaim and n - autoT.claim > 3 then
            clickKeywords({"index","claim all","claim"}); autoT.claim = n
        end
        if CONFIG.AutoBuy and n - autoT.buy > 3 then
            clickKeywords({"buy","upgrade","purchase"}); autoT.buy = n
        end
    end
end)

task.spawn(function()
    while task.wait(0.4) do pcall(updateESP) end
end)

--============================= UI ====================================
local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local gui = new("ScreenGui", { Name = "SAE_AllInOne", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
myGui = gui

local main = new("Frame", { Size = UDim2.new(0, 320, 0, 440),
    Position = UDim2.new(0, 20, 0.5, -220),
    BackgroundColor3 = Color3.fromRGB(26, 26, 32), BorderSizePixel = 0 }, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, main)

local header = new("Frame", { Size = UDim2.new(1, 0, 0, 32),
    BackgroundColor3 = Color3.fromRGB(38, 38, 48), BorderSizePixel = 0 }, main)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, header)
new("TextLabel", { Size = UDim2.new(1, -40, 1, 0), Position = UDim2.new(0, 12, 0, 0),
    BackgroundTransparency = 1, Text = "Steal an Egg — BAC-Safe v1.1.0",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left }, header)
new("TextButton", { Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, -30, 0, 3),
    BackgroundColor3 = Color3.fromRGB(200, 70, 70), Text = "×", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBold, TextSize = 16, BorderSizePixel = 0 }, header)
    .MouseButton1Click:Connect(function() main.Visible = false end)

local tabBar = new("Frame", { Size = UDim2.new(1, -16, 0, 26), Position = UDim2.new(0, 8, 0, 38),
    BackgroundTransparency = 1 }, main)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)

local pages = {}
local function addPage(name)
    local btn = new("TextButton", { Size = UDim2.new(0, 48, 1, 0),
        BackgroundColor3 = Color3.fromRGB(45, 45, 56), Text = name,
        TextColor3 = Color3.new(1,1,1), Font = Enum.Font.Gotham, TextSize = 12,
        BorderSizePixel = 0 }, tabBar)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, btn)
    local page = new("ScrollingFrame", { Size = UDim2.new(1, -16, 1, -104),
        Position = UDim2.new(0, 8, 0, 70), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 4, Visible = false,
        AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, main)
    new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, page)
    new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, page)
    pages[name] = page
    btn.MouseButton1Click:Connect(function()
        for n, p in pairs(pages) do p.Visible = (n == name) end
    end)
    return page
end

local function addToggle(page, text, default, cb)
    local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = default and Color3.fromRGB(46,134,79) or Color3.fromRGB(45,45,56),
        Text = text .. ": " .. (default and "ON" or "OFF"), TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        BorderSizePixel = 0 }, page)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
    local st = default
    local function apply(state)
        st = state
        b.BackgroundColor3 = st and Color3.fromRGB(46,134,79) or Color3.fromRGB(45,45,56)
        b.Text = text .. ": " .. (st and "ON" or "OFF")
        if cb then cb(st) end
    end
    b.MouseButton1Click:Connect(function() apply(not st) end)
    return b, apply
end

local function addSlider(page, text, min, max, default, cb)
    local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, page)
    local lbl = new("TextLabel", { Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        Text = text .. ": " .. default, TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, holder)
    local track = new("TextButton", { Size = UDim2.new(1, 0, 0, 8), Position = UDim2.new(0, 0, 0, 20),
        BackgroundColor3 = Color3.fromRGB(60,60,70), Text = "", BorderSizePixel = 0 }, holder)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
    local fill = new("Frame", { Size = UDim2.new((default-min)/(max-min), 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(90,150,240), BorderSizePixel = 0 }, track)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
    local drag = false
    local function set(v)
        v = math.clamp(v, min, max)
        fill.Size = UDim2.new((v-min)/(max-min), 0, 1, 0)
        lbl.Text = text .. ": " .. v
        if cb then cb(v) end
    end
    track.MouseButton1Down:Connect(function()
        drag = true
        local rel = (UserInputService:GetMouseLocation().X - track.AbsolutePosition.X) / track.AbsoluteSize.X
        set(min + rel * (max - min))
    end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
            local rel = (UserInputService:GetMouseLocation().X - track.AbsolutePosition.X) / track.AbsoluteSize.X
            set(min + rel * (max - min))
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
    end)
    return holder, set
end

local function addCycle(page, text, list, index, cb)
    local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = Color3.fromRGB(45,45,56), Text = text .. ": " .. list[index],
        TextColor3 = Color3.new(1,1,1), Font = Enum.Font.Gotham, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0 }, page)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
    local i = index
    local function apply(value)
        for idx, v in ipairs(list) do if v == value then i = idx; break end end
        b.Text = text .. ": " .. list[i]
        if cb then cb(list[i]) end
    end
    b.MouseButton1Click:Connect(function()
        i = i % #list + 1
        b.Text = text .. ": " .. list[i]
        if cb then cb(list[i]) end
    end)
    return b, apply
end

-- Farm
local farm = addPage("Farm")
addToggle(farm, "Auto Steal", CONFIG.AutoSteal, function(v) CONFIG.AutoSteal = v end)
addToggle(farm, "Return Home", CONFIG.ReturnHome, function(v) CONFIG.ReturnHome = v end)
addToggle(farm, "Only Selected Eggs", CONFIG.OnlySelected, function(v) CONFIG.OnlySelected = v end)
addCycle(farm, "Priority", {"Rarest","Nearest"}, 1, function(v) CONFIG.Priority = v end)
addCycle(farm, "Min Rarity", {"Common","Uncommon","Rare","Epic","Legendary","Mythic","Cosmic","Secret","Eternal","Divine"}, 1,
    function(v) CONFIG.MinRarity = v end)
new("TextLabel", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
    Text = "Eggs on server — tick to whitelist:", TextColor3 = Color3.fromRGB(180,180,190),
    Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, farm)
local listFrame = new("Frame", { Size = UDim2.new(1, 0, 0, 240), BackgroundTransparency = 1 }, farm)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)

local function refreshList()
    for _, c in ipairs(listFrame:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    local names, seen = {}, {}
    for _, e in ipairs(scanEggs(true)) do
        if not seen[e.name] then
            seen[e.name] = true
            table.insert(names, { name = e.name, rarity = e.rarity })
        end
    end
    table.sort(names, function(a, b) return a.name < b.name end)
    for _, n in ipairs(names) do
        local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 22),
            BackgroundColor3 = CONFIG.Selected[n.name] and Color3.fromRGB(46,134,79) or Color3.fromRGB(40,40,48),
            Text = ("[%s] %s"):format(n.rarity, n.name), TextColor3 = Color3.new(1,1,1),
            Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
            BorderSizePixel = 0 }, listFrame)
        new("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0, 6) }, b)
        b.MouseButton1Click:Connect(function()
            CONFIG.Selected[n.name] = (not CONFIG.Selected[n.name]) or nil
            b.BackgroundColor3 = CONFIG.Selected[n.name] and Color3.fromRGB(46,134,79)
                                 or Color3.fromRGB(40,40,48)
        end)
    end
    listFrame.Size = UDim2.new(1, 0, 0, math.max(#names, 1) * 24)
end
task.spawn(function()
    while task.wait(3) do if farm.Visible then pcall(refreshList) end end
end)

-- Auto
local auto = addPage("Auto")
addToggle(auto, "Auto Hatch", CONFIG.AutoHatch, function(v) CONFIG.AutoHatch = v end)
addToggle(auto, "Auto Sell", CONFIG.AutoSell, function(v) CONFIG.AutoSell = v end)
addToggle(auto, "Auto Collect Rewards", CONFIG.AutoCollect, function(v) CONFIG.AutoCollect = v end)
addToggle(auto, "Auto Claim Index", CONFIG.AutoClaim, function(v) CONFIG.AutoClaim = v end)
addToggle(auto, "Auto Buy / Upgrades", CONFIG.AutoBuy, function(v) CONFIG.AutoBuy = v end)
addToggle(auto, "Auto Train (Treadmill)", CONFIG.AutoTrain, function(v) CONFIG.AutoTrain = v end)

-- Move
local move = addPage("Move")
new("TextLabel", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
    Text = "Walking only. WalkSpeed is never touched.",
    TextColor3 = Color3.fromRGB(180,180,190), Font = Enum.Font.Gotham, TextSize = 11,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left }, move)
local _, setFast = addToggle(move, "FastMode (tween, no anchor)", CONFIG.FastMode,
    function(v) CONFIG.FastMode = v; if v then fastRollbacks = 0 end end)
addSlider(move, "Fast Mult (x real speed)", 1.0, 3.0, CONFIG.FastMult,
    function(v) CONFIG.FastMult = v end)
addSlider(move, "Steal Delay x100", 5, 100, CONFIG.StealDelay * 100,
    function(v) CONFIG.StealDelay = v / 100 end)

-- Visual
local vis = addPage("Visual")
local _, setESP = addToggle(vis, "Egg ESP", CONFIG.ESP,
    function(v) CONFIG.ESP = v; if not v then clearESP() end end)
addToggle(vis, "ESP Name Tags", CONFIG.ESPNames, function(v) CONFIG.ESPNames = v end)
addToggle(vis, "ESP X-Ray", CONFIG.ESPXray, function(v) CONFIG.ESPXray = v end)

-- Protect
local prot = addPage("Protect")
addToggle(prot, "Anti AFK", CONFIG.AntiAFK, function(v) CONFIG.AntiAFK = v end)
addToggle(prot, "Anti Ragdoll", CONFIG.AntiRagdoll, function(v) CONFIG.AntiRagdoll = v end)
addToggle(prot, "Anti Trap / Unstuck", CONFIG.AntiTrap, function(v) CONFIG.AntiTrap = v end)
addToggle(prot, "Client :Kick Blocker", CONFIG.AntiKick, function(v)
    CONFIG.AntiKick = v
    if v then installAntiKick() end
end)
local _, setFreeze = addToggle(prot, "Detector Freeze (optional)", CONFIG.DetectorFreeze, function(v)
    CONFIG.DetectorFreeze = v
    if v then enableFreeze() else if freezeCleanup then freezeCleanup() end end
end)

-- Misc
local misc = addPage("Misc")
local _, setHop = addToggle(misc, "Auto Server Hop", CONFIG.AutoHop, function(v) CONFIG.AutoHop = v end)
addSlider(misc, "Hop After (s)", 15, 180, CONFIG.HopAfter, function(v) CONFIG.HopAfter = v end)
local safeBtn = new("TextButton", { Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = Color3.fromRGB(60, 130, 200), Text = "Apply BAC-Safe Preset",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 12,
    BorderSizePixel = 0 }, misc)
new("UICorner", { CornerRadius = UDim.new(0, 5) }, safeBtn)
local unloadBtn = new("TextButton", { Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = Color3.fromRGB(180, 70, 70), Text = "Unload Script",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 13,
    BorderSizePixel = 0 }, misc)
new("UICorner", { CornerRadius = UDim.new(0, 5) }, unloadBtn)

safeBtn.MouseButton1Click:Connect(function()
    CONFIG.FastMode = false; CONFIG.ESP = false
    CONFIG.AutoHop = false; CONFIG.DetectorFreeze = false
    if freezeCleanup then pcall(freezeCleanup) end
    clearESP()
    setFast(false); setESP(false); setHop(false); setFreeze(false)
    notify("BAC-Safe Preset", "Walking only, nothing else touched")
end)

new("TextLabel", { Size = UDim2.new(1, -16, 0, 20), Position = UDim2.new(0, 8, 1, -24),
    BackgroundTransparency = 1, Text = "Idle", TextColor3 = Color3.fromRGB(150,220,150),
    Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    Name = "Status" }, main)
task.spawn(function()
    while task.wait(0.3) do
        local s = main:FindFirstChild("Status")
        if s then s.Text = status end
    end
end)

local reopen = new("TextButton", { Size = UDim2.new(0, 44, 0, 24), Position = UDim2.new(0, 20, 0, 20),
    BackgroundColor3 = Color3.fromRGB(38,38,48), Text = "SAE", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBold, TextSize = 12, Visible = false }, gui)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, reopen)
reopen.MouseButton1Click:Connect(function() main.Visible = true; reopen.Visible = false end)

local dStart, sPos
header.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dStart, sPos = i.Position, main.Position
        i.Changed:Connect(function()
            if i.UserInputState == Enum.UserInputState.End then dStart = nil end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(i)
    if dStart and (i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - dStart
        main.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y)
    end
end)

getgenv().SAE_Unload = function()
    CONFIG.AutoSteal = false
    releaseControls()
    if freezeCleanup then pcall(freezeCleanup) end
    clearESP()
    espFolder:Destroy()
    gui:Destroy()
    getgenv().SAE_Unload = nil
end
unloadBtn.MouseButton1Click:Connect(function() getgenv().SAE_Unload() end)
UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        main.Visible = not main.Visible
        reopen.Visible = not main.Visible
    end
end)

if CONFIG.AntiKick then pcall(installAntiKick) end
farm.Visible = true
refreshList()
notify("Steal an Egg", "v1.1.0 BAC-safe loaded — RightShift to toggle")
print("[SAE] v1.1.0 BAC-safe loaded.")