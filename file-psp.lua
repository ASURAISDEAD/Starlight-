--[[
================================================================================
  STEAL AN EGG  |  v1.2.0
--------------------------------------------------------------------------------
  v1.2.0
    + Speed Bypass integrated (anti-cheat sampler hook) — ON by default
    + Instant Grab  (CarryAreaEgg HoldDuration = 0)   — ON by default
    + No Knockback  (RE/RigSync/Refresh disconnect)
    + Auto Reload   (queue_on_teleport) — survives the ~5 min world reset
    + World-reset handler (holds at base, resumes on respawn)
    + Egg detection via the CarryAreaEgg prompt

  !! SET RELOAD_URL BELOW to your own raw GitHub URL !!
  RightShift toggles the panel. MIT.
================================================================================
]]

if getgenv and getgenv().SAE_Unload then pcall(getgenv().SAE_Unload) end

local RELOAD_URL = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/StealAnEgg.lua"

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local StarterGui         = game:GetService("StarterGui")
local TeleportService    = game:GetService("TeleportService")
local VirtualInput       = game:GetService("VirtualInputManager")
local PathfindingService = game:GetService("PathfindingService")
local ProximityPromptSvc = game:GetService("ProximityPromptService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local player             = Players.LocalPlayer

--============================== CONFIG ===============================
local CONFIG = {
    -- Farm
    AutoSteal = false, Priority = "Rarest", OnlySelected = false, Selected = {},
    MinRarity = "Common",
    -- Speed bypass
    SpeedBypass = true, BypassSpeed = 250,
    -- Movement
    FastMode = false, FastMult = 2.0, ReturnHome = true, StealDelay = 0.15,
    -- Automation
    AutoHatch = false, AutoSell = false, AutoCollect = false, AutoClaim = false,
    AutoBuy = false, AutoTrain = false, TrainEvery = 25,
    -- Visuals
    ESP = false, ESPNames = true, ESPXray = true,
    -- Protection
    AntiAFK = true, AntiRagdoll = true, AntiTrap = true,
    InstantGrab = true, NoKnockback = false, AntiKick = true,
    -- Session
    AutoReload = true, AutoHop = false, HopAfter = 90,
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
            VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
            VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
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
local lastEggCount, resetUntil = 0, 0

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

-- Primary detection: eggs carry a "CarryAreaEgg" prompt (verified from game internals)
local function asEgg(obj)
    if not obj:IsA("Model") then return nil end
    local part = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
    if not part then return nil end
    local prompt = obj:FindFirstChild("CarryAreaEgg", true)
    local anyPrompt = prompt or obj:FindFirstChildWhichIsA("ProximityPrompt", true)
    local rarity = readRarity(obj)
    if not rarity and not anyPrompt and not obj.Name:lower():find("egg") then return nil end
    rarity = rarity or "Common"
    return { model = obj, part = part, pos = part.Position, prompt = prompt,
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
    -- world reset detection
    if #list == 0 and lastEggCount > 0 then
        resetUntil = os.clock() + 15
        notify("World reset", "Holding at base, eggs respawning")
    end
    lastEggCount = #list
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

--=================== SPEED BYPASS (anti-cheat hook) ==================
-- Blinds the game's integrity sampler so any WalkSpeed looks legit.
local bypassActive, bypassCleanup = false, nil

local function samplerTargets()
    local out = {}
    for _, fn in next, getgc() do
        if typeof(fn) == "function" and islclosure(fn) then
            local okSrc, src = pcall(debug.info, fn, "s")
            if okSrc and type(src) == "string" and src:find("ContentCatalog%.Runtime") then
                local okA, params = pcall(debug.info, fn, "a")
                local okU, ups = pcall(debug.getupvalues, fn)
                if okA and params == 3 and okU and type(ups) == "table" and #ups == 5 then
                    table.insert(out, fn)
                end
            end
        end
    end
    return out
end

local function enableSpeedBypass()
    if bypassActive then return end
    if not (hookmetamethod and hookfunction and getgc and islclosure
            and debug and debug.info and debug.getupvalues) then
        notify("Speed Bypass", "Executor missing hook functions — bypass off")
        return
    end

    local function lockValue() return CONFIG.BypassSpeed end

    local oldIndex
    local newIndex = function(self, key, value)
        if key == "WalkSpeed" and value ~= lockValue() then
            local ch = player.Character
            if ch and self == ch:FindFirstChildOfClass("Humanoid") then return end
        end
        return oldIndex(self, key, value)
    end
    if newcclosure then newIndex = newcclosure(newIndex) end
    oldIndex = hookmetamethod(game, "__newindex", newIndex)

    local heartbeat = RunService.Heartbeat:Connect(function()
        local ch = player.Character
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        if h and h.WalkSpeed ~= lockValue() then h.WalkSpeed = lockValue() end
    end)

    bypassActive = true
    bypassCleanup = function()
        heartbeat:Disconnect()
        bypassActive = false
        bypassCleanup = nil
    end

    -- retry until the AC module is loaded and the sampler is found
    task.spawn(function()
        for attempt = 1, 25 do
            if not bypassActive then return end
            local targets = samplerTargets()
            if #targets > 0 then
                local blinded = 0
                for _, fn in ipairs(targets) do
                    local orig
                    local wrapper = function(a, b, c)
                        local sample = orig(a, b, c)
                        if type(sample) == "table" and sample.WalkSpeed
                           and sample.Position and sample.Timestamp then
                            sample.WalkSpeed = 100000
                        end
                        return sample
                    end
                    if newlclosure then wrapper = newlclosure(wrapper) end
                    local ok = pcall(function() orig = hookfunction(fn, wrapper) end)
                    if ok and type(orig) == "function" then blinded = blinded + 1 end
                end
                if blinded > 0 then
                    notify("Speed Bypass", ("Active — %d sampler(s), WalkSpeed %d")
                        :format(blinded, CONFIG.BypassSpeed))
                    return
                end
            end
            task.wait(1)
        end
        notify("Speed Bypass", "Sampler not found — expect rubber-banding")
    end)
end

--======================== INSTANT GRAB / NO KB =======================
local instantConn = nil
local function enableInstantGrab()
    if instantConn then return end
    instantConn = ProximityPromptSvc.PromptButtonHoldBegan:Connect(function(prompt, plr)
        if plr == player and prompt.Name:lower():find("carry") then
            pcall(function() prompt.HoldDuration = 0 end)
        end
    end)
end
local function sweepInstantGrab()
    if not CONFIG.InstantGrab then return end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name:lower():find("carry") and d.HoldDuration ~= 0 then
            pcall(function() d.HoldDuration = 0 end)
        end
    end
end

local function enableNoKnockback()
    local pkgs = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkgs and pkgs:FindFirstChild("Networking")
    local rig = net and net:FindFirstChild("RE/RigSync/Refresh")
    if not rig or not getconnections then
        notify("No Knockback", "RigSync/Refresh not found")
        return
    end
    local n = 0
    pcall(function()
        for _, c in ipairs(getconnections(rig.OnClientEvent)) do
            c:Disconnect(); n = n + 1
        end
    end)
    notify("No Knockback", ("Disconnected %d RigSync connections"):format(n))
end

--=========================== MOVEMENT ================================
local function hum() local c = player.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = player.Character; return c and c:FindFirstChild("HumanoidRootPart") end

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

local function stepTo(target, timeout)
    local start, lastPos, lastMove = os.clock(), nil, os.clock()
    local h, r = hum(), hrp()
    if not h or not r then return false end
    lastPos = r.Position
    while os.clock() - start < timeout do
        h, r = hum(), hrp()
        if not h or not r then return false end
        local flat = Vector3.new(target.X, r.Position.Y, target.Z)
        if (flat - r.Position).Magnitude < 5 then return true end
        h:MoveTo(flat)
        task.wait(0.08)
        if (r.Position - lastPos).Magnitude < 1 then
            if os.clock() - lastMove > 0.8 then h.Jump = true; lastMove = os.clock() end
            if os.clock() - lastMove > 3 then return false end
        else
            lastPos = r.Position
            lastMove = os.clock()
        end
    end
    return false
end

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
    if not pcall(function() path:ComputeAsync(r.Position, target) end) then
        return stepTo(target, timeout)
    end
    for _, wp in ipairs(path:GetWaypoints()) do
        if wp.Action == Enum.PathWaypointAction.Jump then
            local h = hum(); if h then h.Jump = true end
        end
        if not stepTo(wp.Position, 10) then return false end
    end
    return true
end

local function tryInteract(egg)
    local prompt = egg.prompt or egg.model:FindFirstChildWhichIsA("ProximityPrompt", true)
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

--=================== AUTO RELOAD (survives resets) ===================
local function installAutoReload()
    if not CONFIG.AutoReload then return end
    if RELOAD_URL:find("YOUR_USERNAME") then
        notify("Auto Reload", "Set RELOAD_URL at the top of the script")
        return
    end
    local code = ('loadstring(game:HttpGet("%s"))()'):format(RELOAD_URL)
    pcall(function()
        if queue_on_teleport then queue_on_teleport(code)
        elseif syn and syn.queue_on_teleport then syn.queue_on_teleport(code)
        elseif fluxus and fluxus.queue_on_teleport then fluxus.queue_on_teleport(code) end
    end)
end

--======================== KICK BLOCKER (client) ======================
local function nc(f) if newcclosure then return newcclosure(f) end return f end
local function installAntiKick()
    if typeof(getrawmetatable) ~= "function" or not setreadonly then return end
    pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = nc(function(self, ...)
            if getnamecallmethod() == "Kick" and typeof(self) == "Instance"
               and self:IsA("Player") then
                return nil
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
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

--============================ BRAIN ==================================
local trainReady = 0
local noCharSince = nil

local function brain()
    while task.wait() do
        if CONFIG.InstantGrab then pcall(sweepInstantGrab) end
        local active = CONFIG.AutoSteal or CONFIG.AutoTrain
        if not active then
            releaseControls()
            setStatus("Idle")
        elseif os.clock() < resetUntil then
            setStatus("World reset — waiting for eggs")
            task.wait(0.3)
        else
            local r = hrp()
            if not r then
                if not noCharSince then noCharSince = os.clock() end
                if os.clock() - noCharSince > 4 then
                    setStatus("No character — rejoin if stuck")
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
                    if bp then walkTo(bp, 45) end
                elseif CONFIG.AutoTrain and os.clock() >= trainReady then
                    local prompt = findWorldPrompt({"treadmill","train","speed"})
                    if prompt then
                        setStatus("Training")
                        walkTo(prompt.Parent.Position, 40)
                        firePrompt(prompt)
                        trainReady = os.clock() + CONFIG.TrainEvery
                    else
                        trainReady = os.clock() + 3
                    end
                elseif CONFIG.AutoSteal then
                    local t = pickTarget()
                    if t then
                        setStatus(("Stealing [%s] %s"):format(t.rarity, t.name))
                        local ok = walkTo(t.pos, 45)
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
        if CONFIG.AutoHop and CONFIG.AutoSteal
           and os.clock() >= resetUntil
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

local main = new("Frame", { Size = UDim2.new(0, 320, 0, 450),
    Position = UDim2.new(0, 20, 0.5, -225),
    BackgroundColor3 = Color3.fromRGB(26, 26, 32), BorderSizePixel = 0 }, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, main)

local header = new("Frame", { Size = UDim2.new(1, 0, 0, 32),
    BackgroundColor3 = Color3.fromRGB(38, 38, 48), BorderSizePixel = 0 }, main)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, header)
new("TextLabel", { Size = UDim2.new(1, -40, 1, 0), Position = UDim2.new(0, 12, 0, 0),
    BackgroundTransparency = 1, Text = "Steal an Egg — v1.2.0",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 14,
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
        lbl.Text = text .. ": " .. math.floor(v)
        if cb then cb(math.floor(v)) end
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

-- Speed
local spd = addPage("Speed")
new("TextLabel", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
    Text = "Bypass hooks the anti-cheat sampler so any speed passes.",
    TextColor3 = Color3.fromRGB(180,180,190), Font = Enum.Font.Gotham, TextSize = 11,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left }, spd)
local _, setBypass = addToggle(spd, "Speed Bypass (sampler hook)", CONFIG.SpeedBypass, function(v)
    CONFIG.SpeedBypass = v
    if v then enableSpeedBypass() else if bypassCleanup then bypassCleanup() end end
end)
addSlider(spd, "Bypass Speed", 50, 600, CONFIG.BypassSpeed, function(v) CONFIG.BypassSpeed = v end)
local _, setFast = addToggle(spd, "FastMode (tween, no anchor)", CONFIG.FastMode,
    function(v) CONFIG.FastMode = v end)

-- Visual
local vis = addPage("Visual")
local _, setESP = addToggle(vis, "Egg ESP", CONFIG.ESP,
    function(v) CONFIG.ESP = v; if not v then clearESP() end end)
addToggle(vis, "ESP Name Tags", CONFIG.ESPNames, function(v) CONFIG.ESPNames = v end)
addToggle(vis, "ESP X-Ray", CONFIG.ESPXray, function(v) CONFIG.ESPXray = v end)

-- Protect
local prot = addPage("Protect")
local _, setGrab = addToggle(prot, "Instant Grab", CONFIG.InstantGrab, function(v)
    CONFIG.InstantGrab = v
    if v then enableInstantGrab(); sweepInstantGrab() end
end)
addToggle(prot, "Anti AFK", CONFIG.AntiAFK, function(v) CONFIG.AntiAFK = v end)
addToggle(prot, "Anti Ragdoll", CONFIG.AntiRagdoll, function(v) CONFIG.AntiRagdoll = v end)
addToggle(prot, "Anti Trap / Unstuck", CONFIG.AntiTrap, function(v) CONFIG.AntiTrap = v end)
addToggle(prot, "No Knockback", CONFIG.NoKnockback, function(v)
    CONFIG.NoKnockback = v
    if v then enableNoKnockback() end
end)
addToggle(prot, "Client :Kick Blocker", CONFIG.AntiKick, function(v)
    CONFIG.AntiKick = v
    if v then installAntiKick() end
end)

-- Misc
local misc = addPage("Misc")
local _, setReload = addToggle(misc, "Auto Reload on Teleport", CONFIG.AutoReload, function(v)
    CONFIG.AutoReload = v
    if v then installAutoReload() end
end)
local _, setHop = addToggle(misc, "Auto Server Hop", CONFIG.AutoHop, function(v) CONFIG.AutoHop = v end)
addSlider(misc, "Hop After (s)", 30, 300, CONFIG.HopAfter, function(v) CONFIG.HopAfter = v end)
local safeBtn = new("TextButton", { Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = Color3.fromRGB(60, 130, 200), Text = "Apply Safe Preset",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 12,
    BorderSizePixel = 0 }, misc)
new("UICorner", { CornerRadius = UDim.new(0, 5) }, safeBtn)
local unloadBtn = new("TextButton", { Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = Color3.fromRGB(180, 70, 70), Text = "Unload Script",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 13,
    BorderSizePixel = 0 }, misc)
new("UICorner", { CornerRadius = UDim.new(0, 5) }, unloadBtn)

safeBtn.MouseButton1Click:Connect(function()
    CONFIG.SpeedBypass = true; CONFIG.FastMode = false
    CONFIG.ESP = false; CONFIG.AutoHop = false
    if bypassCleanup then pcall(bypassCleanup) end
    clearESP()
    setBypass(true); setFast(false); setESP(false); setHop(false)
    enableSpeedBypass()
    notify("Safe Preset", "Bypass on, walking, no hop")
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
    if bypassCleanup then pcall(bypassCleanup) end
    if instantConn then instantConn:Disconnect(); instantConn = nil end
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

-- boot
if CONFIG.SpeedBypass then enableSpeedBypass() end
if CONFIG.InstantGrab then enableInstantGrab() end
if CONFIG.AntiKick then pcall(installAntiKick) end
installAutoReload()
farm.Visible = true
refreshList()
notify("Steal an Egg", "v1.2.0 loaded — RightShift to toggle")
print("[SAE] v1.2.0 loaded.")