--[[
=========================================================
   AUTO STEAL RAREST EGG  •  v2.0
   Game: Steal an Egg  (107778070777162)
   Guaranteed-render UI + adaptive detection + debug log
=========================================================
]]

local P = "[SAE]"
local function log(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    print(P, table.concat(t, " "))
end

-- kill a previous instance if one exists
pcall(function()
    if getgenv and type(getgenv().__SAE_UNLOAD) == "function" then
        getgenv().__SAE_UNLOAD()
    end
end)

local function svc(n)
    local ok, s = pcall(function() return game:GetService(n) end)
    return ok and s or nil
end

local Players    = svc("Players")
local RunService = svc("RunService")
local UIS        = svc("UserInputService")
local Tween      = svc("TweenService")
local StarterGui = svc("StarterGui")
local CoreGui    = svc("CoreGui")
local VU         = svc("VirtualUser")
local LP         = Players and Players.LocalPlayer

if not LP then warn(P .. " LocalPlayer missing — abort") return end

local hasPrompt  = type(fireproximityprompt) == "function"
local hasClick   = type(fireclickdetector) == "function"
local hasHookMM  = type(hookmetamethod) == "function" and type(getrawmetatable) == "function"

log("v2.0 boot — executor:", (type(identifyexecutor) == "function" and (select(1, identifyexecutor())) or "unknown"))
log("capabilities — hookmetamethod:", hasHookMM, "prompt:", hasPrompt, "click:", hasClick)

--=========================================================
--  STATE
--=========================================================
local State = {
    enabled     = true,
    autoSteal   = true,
    autoReturn  = true,
    autoDrop    = true,
    autoCollect = false,
    esp         = true,
    noclip      = false,
    antiAfk     = true,
    minTier     = 1,
    preferRarest = true,
    speed       = 500,
    slowSpeed   = 22,
    mode        = "idle",
    target      = nil,
    dwell       = 0,
}

local conns = {}
local function bind(sig, fn)
    local c = sig:Connect(fn)
    table.insert(conns, c)
    return c
end

--=========================================================
--  HELPERS
--=========================================================
local function getChar() return LP.Character end
local function getHum()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local c = LP.Character
    if not c then return nil end
    return c.PrimaryPart or c:FindFirstChild("HumanoidRootPart")
end

local function centerOf(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("Model") then
        local ok, cf = pcall(function() return obj:GetBoundingBox() end)
        if ok and cf then return cf.Position end
        if obj.PrimaryPart then return obj.PrimaryPart.Position end
        local p = obj:FindFirstChildWhichIsA("BasePart")
        return p and p.Position
    elseif obj:IsA("BasePart") then
        return obj.Position
    end
    return nil
end

--=========================================================
--  SPEED BYPASS  (akkiwi-style, hardened)
--=========================================================
local lock = 500
local internalWrite = false
local curHum = nil

local function applySpeed(v)
    local hum = curHum or getHum()
    if not hum then return end
    internalWrite = true
    pcall(function() hum.WalkSpeed = v end)
    internalWrite = false
end

local function setLock(v)
    if lock ~= v then
        lock = v
        applySpeed(v)
    end
end

if hasHookMM then
    pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__newindex
        if setreadonly then setreadonly(mt, false) end
        local wrap = (type(newcclosure) == "function") and newcclosure or function(f) return f end
        mt.__newindex = wrap(function(self, k, v)
            if k == "WalkSpeed" and typeof(self) == "Instance" and self:IsA("Humanoid")
               and self == curHum and not internalWrite then
                return old(self, k, lock)
            end
            return old(self, k, v)
        end)
        if setreadonly then setreadonly(mt, true) end
        log("WalkSpeed __newindex hook installed")
    end)
else
    log("no hookmetamethod — using re-apply loop only")
end

local function bindCharacter(c)
    curHum = c:WaitForChild("Humanoid", 5)
    if curHum then
        applySpeed(lock)
        log("character bound, lock =", lock)
    end
end

if LP.Character then pcall(bindCharacter, LP.Character) end
bind(LP.CharacterAdded, function(c) pcall(bindCharacter, c) end)

--=========================================================
--  RARITY ENGINE
--=========================================================
local RARITIES = {
    {tier=1,  name="Common",    color=Color3.fromRGB(185,190,200), keys={"common"}},
    {tier=2,  name="Uncommon",  color=Color3.fromRGB(120,220,120), keys={"uncommon"}},
    {tier=3,  name="Rare",      color=Color3.fromRGB(80,160,255),  keys={"rare"}},
    {tier=4,  name="Epic",      color=Color3.fromRGB(170,100,255), keys={"epic"}},
    {tier=5,  name="Legendary", color=Color3.fromRGB(255,180,60),  keys={"legendary","legend"}},
    {tier=6,  name="Mythic",    color=Color3.fromRGB(255,90,90),   keys={"mythic","mythical"}},
    {tier=7,  name="Secret",    color=Color3.fromRGB(60,240,220),  keys={"secret"}},
    {tier=8,  name="Godly",     color=Color3.fromRGB(255,110,255), keys={"godly","god"}},
    {tier=9,  name="Divine",    color=Color3.fromRGB(255,255,255), keys={"divine"}},
    {tier=10, name="Celestial", color=Color3.fromRGB(160,200,255), keys={"celestial"}},
    {tier=11, name="Eternal",   color=Color3.fromRGB(255,225,130), keys={"eternal"}},
}

local function rarityFromText(t)
    if type(t) ~= "string" or t == "" then return nil end
    local s = string.lower(t)
    for i = #RARITIES, 1, -1 do
        local r = RARITIES[i]
        for _, k in ipairs(r.keys) do
            if string.find(s, k, 1, true) then return r end
        end
    end
    return nil
end

--=========================================================
--  DETECTION
--=========================================================
local eggs       = {}
local myBase     = nil
local blacklist  = {}
local homeFallback = nil

local function cheapCandidate(o)
    if o:IsA("Model") then
        if #o:GetChildren() == 0 then return false end
    elseif not o:IsA("BasePart") then
        return false
    end
    local nm = string.lower(o.Name)
    if string.find(nm, "egg", 1, true) then return true end
    if o:FindFirstChildOfClass("BillboardGui") or o:FindFirstChildOfClass("SurfaceGui") then return true end
    if o:FindFirstChildOfClass("ProximityPrompt") or o:FindFirstChildOfClass("ClickDetector") then return true end
    for _ in pairs(o:GetAttributes()) do return true end
    for _, _ in ipairs(o:GetTags()) do return true end
    return false
end

local function ownerOf(obj)
    for k, v in pairs(obj:GetAttributes()) do
        local lk = string.lower(k)
        if lk == "owner" or lk == "ownerid" or lk == "userid" or lk == "placer"
           or lk == "playerid" or lk == "player" then
            if type(v) == "number" and v == LP.UserId then return true end
            if type(v) == "string" and (v == LP.Name or v == LP.DisplayName or v == tostring(LP.UserId)) then return true end
        end
    end
    return false
end

local function hasBaseAncestor(obj)
    local a = obj
    for _ = 1, 4 do
        a = a.Parent
        if not a or a == workspace then break end
        if (a:IsA("Model") or a:IsA("Folder") or a:IsA("BasePart")) then
            if ownerOf(a) then return a end
        end
    end
    return nil
end

local function analyseEgg(o)
    if not cheapCandidate(o) then return nil end
    local score, rarity, value = 0, nil, 0

    if string.find(string.lower(o.Name), "egg", 1, true) then score += 2 end
    rarity = rarityFromText(o.Name) or rarity

    for k, v in pairs(o:GetAttributes()) do
        local lk = string.lower(k)
        if lk == "rarity" or lk == "tier" or lk == "type" or lk == "rank" then
            if type(v) == "string" then
                local r = rarityFromText(v); if r then rarity = r end
                score += 3
            elseif type(v) == "number" then
                score += 2
            end
        elseif lk == "value" or lk == "income" or lk == "price" or lk == "cost"
            or lk == "cash" or lk == "coins" or lk == "money" then
            if type(v) == "number" then value = math.max(value, v); score += 2 end
        end
    end

    for _, tag in ipairs(o:GetTags()) do
        local lt = string.lower(tag)
        if string.find(lt, "egg", 1, true) then score += 2 end
        local r = rarityFromText(tag); if r then rarity = r; score += 2 end
    end

    local n = 0
    for _, d in ipairs(o:GetDescendants()) do
        n += 1
        if n > 80 then break end
        if d:IsA("BillboardGui") or d:IsA("SurfaceGui") then score += 2 end
        if d:IsA("TextLabel") or d:IsA("TextMesh") then
            local r = rarityFromText(d.Text); if r then rarity = r end
        end
        if d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then score += 1 end
    end

    local anc = hasBaseAncestor(o)
    if anc then score += 2 end

    if score < 3 then return nil end
    if o:IsA("BasePart") and o.Size.Magnitude > 60 then return nil end

    if not rarity then
        local vt = 1
        if value >= 1e6 then vt = 8
        elseif value >= 1e5 then vt = 7
        elseif value >= 1e4 then vt = 6
        elseif value >= 1e3 then vt = 5
        elseif value >= 100 then vt = 4
        elseif value >= 20 then vt = 3
        elseif value >= 5 then vt = 2 end
        rarity = RARITIES[vt]
    end

    local pos = centerOf(o)
    if not pos then return nil end

    return {inst = o, pos = pos, rarity = rarity, tier = rarity.tier, value = value,
            mine = (anc and ownerOf(anc)) and true or false}
end

local function scanEggs()
    local now = os.clock()
    local out, visited, qi = {}, 0, 1
    local queue = {{workspace, 0}}
    while qi <= #queue and visited < 12000 do
        local node = queue[qi]; qi += 1
        local o, d = node[1], node[2]
        visited += 1
        if o ~= workspace and o ~= LP.Character then
            local a = analyseEgg(o)
            if a and (blacklist[o] or 0) < now then
                table.insert(out, a)
            end
        end
        if d < 5 then
            for _, c in ipairs(o:GetChildren()) do
                if c ~= LP.Character and c ~= workspace.CurrentCamera then
                    queue[#queue + 1] = {c, d + 1}
                end
            end
        end
    end
    eggs = out
end

local function scanBase()
    local found, visited, qi = nil, 0, 1
    local queue = {{workspace, 0}}
    while qi <= #queue and visited < 12000 do
        local node = queue[qi]; qi += 1
        local o, d = node[1], node[2]
        visited += 1
        if o ~= workspace and (o:IsA("Model") or o:IsA("BasePart")) then
            local match = ownerOf(o)
            if not match and o:IsA("Model") and #o:GetChildren() >= 2 then
                local n = string.lower(o.Name)
                if #LP.Name > 2 and string.find(n, string.lower(LP.Name), 1, true) then match = true end
            end
            if match then
                local pad = o:FindFirstChild("Pad", true) or o:FindFirstChild("Podium", true)
                    or o:FindFirstChild("Platform", true) or o:FindFirstChild("Slot", true)
                    or o:FindFirstChild("Conveyor", true)
                local pos = (pad and pad:IsA("BasePart") and pad.Position) or centerOf(o)
                if pos then found = {obj = o, pos = pos} end
            end
        end
        if d < 4 then
            for _, c in ipairs(o:GetChildren()) do queue[#queue + 1] = {c, d + 1} end
        end
    end
    myBase = found
end

--=========================================================
--  ESP
--=========================================================
local espObjs = {}
local function updateESP()
    if not State.esp then
        for inst, h in pairs(espObjs) do pcall(function() h:Destroy() end) end
        espObjs = {}
        return
    end
    local seen = {}
    for _, e in ipairs(eggs) do
        seen[e.inst] = true
        local h = espObjs[e.inst]
        if not h or not h.Parent then
            h = Instance.new("Highlight")
            h.Name = "SAE_ESP"
            h.FillTransparency = 0.65
            h.OutlineTransparency = 0.05
            h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            h.Adornee = e.inst
            h.Parent = e.inst
            espObjs[e.inst] = h
        end
        h.FillColor = e.rarity.color
        h.OutlineColor = e.rarity.color
    end
    for inst, h in pairs(espObjs) do
        if not seen[inst] or not inst.Parent then
            pcall(function() h:Destroy() end)
            espObjs[inst] = nil
        end
    end
end

--=========================================================
--  ACTIONS
--=========================================================
local function fireInteracts(inst)
    if not inst then return end
    local now = os.clock()
    if now - (State.lastInteract or 0) < 0.4 then return end
    State.lastInteract = now
    for _, d in ipairs(inst:GetDescendants()) do
        if hasPrompt and d:IsA("ProximityPrompt") and d.Enabled then
            pcall(fireproximityprompt, d)
        elseif hasClick and d:IsA("ClickDetector") then
            pcall(fireclickdetector, d)
        end
    end
end

local function pickTarget()
    local list = {}
    for _, e in ipairs(eggs) do
        if e.tier >= State.minTier and not e.mine then
            table.insert(list, e)
        end
    end
    if #list == 0 then
        for _, e in ipairs(eggs) do
            if e.tier >= State.minTier then table.insert(list, e) end
        end
    end
    if #list == 0 then return nil end
    local root = getRoot()
    if root then
        for _, e in ipairs(list) do
            e.dist = (root.Position - e.pos).Magnitude
        end
    end
    table.sort(list, function(a, b)
        if State.preferRarest then
            if a.tier ~= b.tier then return a.tier > b.tier end
            if a.value ~= b.value then return a.value > b.value end
        end
        return (a.dist or 0) < (b.dist or 0)
    end)
    return list[1]
end

local function speedFor(d)
    if d > 90 then return State.speed
    elseif d > 16 then return math.max(State.slowSpeed + 20, 70)
    else return State.slowSpeed end
end

local function failTarget(t, reason)
    if t and t.inst then blacklist[t.inst] = os.clock() + 8 end
    if reason then log("fail:", reason) end
    State.mode = "idle"
    State.dwell = 0
end

--=========================================================
--  GUI  (built first, in its own protected block)
--=========================================================
local UI = {}
local function buildUI()
    local function pickParent()
        local tries = {}
        if type(gethui) == "function" then table.insert(tries, function() return gethui() end) end
        table.insert(tries, function() return CoreGui end)
        table.insert(tries, function() return LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui", 5) end)
        table.insert(tries, function() return StarterGui end)
        for _, f in ipairs(tries) do
            local ok, p = pcall(f)
            if ok and p then return p end
        end
        return nil
    end

    local function mk(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do
            if k ~= "Parent" then o[k] = v end
        end
        if parent then o.Parent = parent end
        return o
    end

    local C = {
        bg      = Color3.fromRGB(16,17,21),
        card    = Color3.fromRGB(24,26,33),
        line    = Color3.fromRGB(45,49,60),
        text    = Color3.fromRGB(236,238,245),
        sub     = Color3.fromRGB(138,144,158),
        accent  = Color3.fromRGB(255,196,72),
        on      = Color3.fromRGB(94,222,140),
        off     = Color3.fromRGB(66,70,82),
    }

    local parent = pickParent()
    local old = parent and parent:FindFirstChild("AutoStealRarestEgg")
    if old then old:Destroy() end

    local sg = mk("ScreenGui", {
        Name = "AutoStealRarestEgg",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 999,
    })
    if parent then sg.Parent = parent end
    UI.sg = sg

    local main = mk("Frame", {
        Name = "Main",
        Size = UDim2.fromOffset(274, 486),
        Position = UDim2.new(0, 24, 0.5, -243),
        BackgroundColor3 = C.bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, sg)
    mk("UICorner", {CornerRadius = UDim.new(0, 12)}, main)
    mk("UIStroke", {Color = C.line, Thickness = 1, Transparency = 0.25}, main)
    UI.main = main

    -- header
    local header = mk("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = C.card,
        BorderSizePixel = 0,
    }, main)
    mk("UICorner", {CornerRadius = UDim.new(0, 12)}, header)

    mk("Frame", {
        Size = UDim2.new(1, 0, 0, 14),
        Position = UDim2.new(0, 0, 1, -14),
        BackgroundColor3 = C.card,
        BorderSizePixel = 0,
    }, header)

    mk("Frame", {
        Size = UDim2.fromOffset(3, 16),
        Position = UDim2.new(0, 14, 0, 16),
        BackgroundColor3 = C.accent,
        BorderSizePixel = 0,
    }, header)

    mk("TextLabel", {
        Size = UDim2.new(1, -70, 0, 16),
        Position = UDim2.new(0, 24, 0, 10),
        BackgroundTransparency = 1,
        Text = "AUTO STEAL RAREST EGG",
        TextColor3 = C.text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)

    mk("TextLabel", {
        Size = UDim2.new(1, -70, 0, 12),
        Position = UDim2.new(0, 24, 0, 27),
        BackgroundTransparency = 1,
        Text = "Steal an Egg  •  v2.0",
        TextColor3 = C.sub,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)

    local minBtn = mk("TextButton", {
        Size = UDim2.fromOffset(22, 22),
        Position = UDim2.new(1, -34, 0, 13),
        BackgroundColor3 = C.bg,
        Text = "–",
        TextColor3 = C.sub,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, header)
    mk("UICorner", {CornerRadius = UDim.new(0, 6)}, minBtn)

    -- status card
    local status = mk("Frame", {
        Size = UDim2.new(1, -24, 0, 58),
        Position = UDim2.new(0, 12, 0, 58),
        BackgroundColor3 = C.card,
        BorderSizePixel = 0,
    }, main)
    mk("UICorner", {CornerRadius = UDim.new(0, 9)}, status)

    local dot = mk("Frame", {
        Size = UDim2.fromOffset(7, 7),
        Position = UDim2.new(0, 12, 0, 14),
        BackgroundColor3 = C.on,
        BorderSizePixel = 0,
    }, status)
    mk("UICorner", {CornerRadius = UDim.new(0, 4)}, dot)

    UI.statusLbl = mk("TextLabel", {
        Size = UDim2.new(1, -34, 0, 14),
        Position = UDim2.new(0, 26, 0, 11),
        BackgroundTransparency = 1,
        Text = "Idle",
        TextColor3 = C.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, status)

    UI.targetLbl = mk("TextLabel", {
        Size = UDim2.new(1, -24, 0, 12),
        Position = UDim2.new(0, 12, 0, 27),
        BackgroundTransparency = 1,
        Text = "Target: —",
        TextColor3 = C.sub,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, status)

    UI.countLbl = mk("TextLabel", {
        Size = UDim2.new(1, -24, 0, 12),
        Position = UDim2.new(0, 12, 0, 41),
        BackgroundTransparency = 1,
        Text = "Eggs 0   Base —",
        TextColor3 = C.sub,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, status)

    -- scroll content
    local scroll = mk("ScrollingFrame", {
        Size = UDim2.new(1, -24, 1, -58 - 12 - 62 - 26),
        Position = UDim2.new(0, 12, 0, 124),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.line,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, main)
    mk("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, scroll)
    UI.scroll = scroll

    local order = 0
    local function section(text)
        order += 1
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 22),
            BackgroundTransparency = 1,
            LayoutOrder = order,
        }, scroll)
        mk("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = C.sub,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        return f
    end

    local function row(label)
        order += 1
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 28),
            BackgroundTransparency = 1,
            LayoutOrder = order,
        }, scroll)
        mk("TextLabel", {
            Size = UDim2.new(1, -54, 1, 0),
            BackgroundTransparency = 1,
            Text = label,
            TextColor3 = C.text,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        return f
    end

    local function toggle(label, default, onChange)
        local f = row(label)
        local sw = mk("Frame", {
            Size = UDim2.fromOffset(36, 19),
            Position = UDim2.new(1, -36, 0.5, -9.5),
            BackgroundColor3 = default and C.on or C.off,
            BorderSizePixel = 0,
        }, f)
        mk("UICorner", {CornerRadius = UDim.new(0, 10)}, sw)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(15, 15),
            Position = UDim2.new(0, default and 19 or 2, 0.5, -7.5),
            BackgroundColor3 = Color3.new(1,1,1),
            BorderSizePixel = 0,
        }, sw)
        mk("UICorner", {CornerRadius = UDim.new(0, 8)}, knob)
        local state = default
        local function render()
            Tween:Create(sw, TweenInfo.new(0.14), {BackgroundColor3 = state and C.on or C.off}):Play()
            Tween:Create(knob, TweenInfo.new(0.14), {Position = UDim2.new(0, state and 19 or 2, 0.5, -7.5)}):Play()
        end
        local btn = mk("TextButton", {Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Text = ""}, f)
        btn.MouseButton1Click:Connect(function()
            state = not state
            render()
            if onChange then pcall(onChange, state) end
        end)
        return {get = function() return state end, set = function(v) state = v; render() end}
    end

    local function slider(label, min, max, default, suffix, onChange)
        order += 1
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 40),
            BackgroundTransparency = 1,
            LayoutOrder = order,
        }, scroll)
        mk("TextLabel", {
            Size = UDim2.new(1, -70, 0, 14),
            BackgroundTransparency = 1,
            Text = label,
            TextColor3 = C.text,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        local val = mk("TextLabel", {
            Size = UDim2.new(0, 60, 0, 14),
            Position = UDim2.new(1, -60, 0, 0),
            BackgroundTransparency = 1,
            Text = tostring(default) .. suffix,
            TextColor3 = C.accent,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Right,
        }, f)
        local bar = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 5),
            Position = UDim2.new(0, 0, 0, 24),
            BackgroundColor3 = C.off,
            BorderSizePixel = 0,
        }, f)
        mk("UICorner", {CornerRadius = UDim.new(0, 3)}, bar)
        local pct = (default - min) / (max - min)
        local fill = mk("Frame", {
            Size = UDim2.new(pct, 0, 1, 0),
            BackgroundColor3 = C.accent,
            BorderSizePixel = 0,
        }, bar)
        mk("UICorner", {CornerRadius = UDim.new(0, 3)}, fill)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(12, 12),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(pct, 0, 0.5, 0),
            BackgroundColor3 = Color3.new(1,1,1),
            BorderSizePixel = 0,
        }, bar)
        mk("UICorner", {CornerRadius = UDim.new(0, 6)}, knob)

        local dragging = false
        local function apply(x)
            local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
            local v = math.floor(min + (max - min) * rel + 0.5)
            val.Text = tostring(v) .. suffix
            fill.Size = UDim2.new(rel, 0, 1, 0)
            knob.Position = UDim2.new(rel, 0, 0.5, 0)
            if onChange then pcall(onChange, v) end
        end
        local hit = mk("TextButton", {
            Size = UDim2.new(1, 0, 1, 0),
            Position = UDim2.new(0, 0, 0, 18),
            BackgroundTransparency = 1,
            Text = "",
        }, f)
        hit.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                apply(i.Position.X)
            end
        end)
        bind(UIS.InputChanged, function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                apply(i.Position.X)
            end
        end)
        bind(UIS.InputEnded, function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        return {set = function(v) apply(bar.AbsolutePosition.X + (v - min) / (max - min) * bar.AbsoluteSize.X) end}
    end

    local function stepper(label, getVal, setVal)
        local f = row(label)
        local box = mk("Frame", {
            Size = UDim2.fromOffset(140, 22),
            Position = UDim2.new(1, -140, 0.5, -11),
            BackgroundColor3 = C.card,
            BorderSizePixel = 0,
        }, f)
        mk("UICorner", {CornerRadius = UDim.new(0, 6)}, box)
        local minus = mk("TextButton", {Size = UDim2.fromOffset(24, 22), BackgroundTransparency = 1, Text = "‹", TextColor3 = C.sub, Font = Enum.Font.GothamBold, TextSize = 15}, box)
        local plus  = mk("TextButton", {Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, -24, 0, 0), BackgroundTransparency = 1, Text = "›", TextColor3 = C.sub, Font = Enum.Font.GothamBold, TextSize = 15}, box)
        local lbl = mk("TextLabel", {
            Size = UDim2.new(1, -48, 1, 0),
            Position = UDim2.new(0, 24, 0, 0),
            BackgroundTransparency = 1,
            Text = "",
            TextColor3 = C.accent,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
        }, box)
        local function render()
            local r = RARITIES[getVal()]
            lbl.Text = r and r.name or "Any"
            lbl.TextColor3 = r and r.color or C.accent
        end
        minus.MouseButton1Click:Connect(function()
            setVal(math.max(1, getVal() - 1)); render()
        end)
        plus.MouseButton1Click:Connect(function()
            setVal(math.min(#RARITIES, getVal() + 1)); render()
        end)
        render()
    end

    -- automation
    section("AUTOMATION")
    UI.tAutoSteal  = toggle("Auto Steal", true,  function(v) State.autoSteal = v end)
    UI.tAutoReturn = toggle("Auto Return to Base", true, function(v) State.autoReturn = v end)
    UI.tAutoDrop   = toggle("Auto Drop", true, function(v) State.autoDrop = v end)
    UI.tAutoCollect= toggle("Auto Collect (base)", false, function(v) State.autoCollect = v end)

    section("PLAYER")
    UI.tEsp     = toggle("ESP Highlights", true, function(v) State.esp = v end)
    UI.tNoclip  = toggle("Noclip", false, function(v) State.noclip = v end)
    UI.tAntiAfk = toggle("Anti-AFK", true, function(v) State.antiAfk = v end)

    section("SETTINGS")
    stepper("Min Rarity", function() return State.minTier end, function(v) State.minTier = v end)
    UI.sSpeed = slider("Walk Speed", 20, 1000, 500, "", function(v) State.speed = v; if State.mode == "idle" then setLock(v) end end)
    UI.sSlow  = slider("Slow Near Egg", 8, 60, 22, "", function(v) State.slowSpeed = v end)

    section("DEBUG LOG")
    UI.logBox = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 96),
        BackgroundTransparency = 1,
        LayoutOrder = 9999,
    }, scroll)
    mk("UIListLayout", {Padding = UDim.new(0, 1)}, UI.logBox)
    UI.logLines = {}

    -- footer
    local footer = mk("Frame", {
        Size = UDim2.new(1, -24, 0, 46),
        Position = UDim2.new(0, 12, 1, -58),
        BackgroundTransparency = 1,
    }, main)

    local rescan = mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = C.card,
        Text = "Rescan World",
        TextColor3 = C.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        AutoButtonColor = false,
    }, footer)
    mk("UICorner", {CornerRadius = UDim.new(0, 6)}, rescan)

    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        Position = UDim2.new(0, 0, 0, 28),
        BackgroundTransparency = 1,
        Text = "RightShift = toggle  •  drag header",
        TextColor3 = C.sub,
        Font = Enum.Font.Gotham,
        TextSize = 10,
    }, footer)

    rescan.MouseButton1Click:Connect(function()
        blacklist = {}
        pcall(scanEggs); pcall(scanBase)
        log("manual rescan")
    end)

    -- drag
    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = i.Position
            startPos = main.Position
        end
    end)
    bind(UIS.InputChanged, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    bind(UIS.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- collapse
    local collapsed = false
    minBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        scroll.Visible = not collapsed
        status.Visible = not collapsed
        footer.Visible = not collapsed
        main.Size = collapsed and UDim2.fromOffset(274, 48) or UDim2.fromOffset(274, 486)
        minBtn.Text = collapsed and "+" or "–"
    end)

    return true
end

local guiOK, guiErr = pcall(buildUI)
if not guiOK then
    warn(P .. " GUI ERROR:", guiErr)
else
    log("GUI built, parent =", UI.sg and UI.sg.Parent and UI.sg.Parent:GetFullName())
end

-- in-GUI log
local function uiLog(msg)
    log(msg)
    if not UI.logLines then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, 11)
    l.Font = Enum.Font.Code
    l.TextSize = 10
    l.TextColor3 = Color3.fromRGB(150,200,160)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = "› " .. tostring(msg)
    l.Parent = UI.logBox
    table.insert(UI.logLines, l)
    while #UI.logLines > 8 do
        local o = table.remove(UI.logLines, 1)
        pcall(function() o:Destroy() end)
    end
end

--=========================================================
--  MAIN LOOP
--=========================================================
local lastEggScan, lastBaseScan, lastMove, lastTick = 0, 0, 0, os.clock()

local function onTick()
    local now = os.clock()
    local dt = now - lastTick
    lastTick = now

    if not State.enabled then
        UI.statusLbl.Text = "Paused"
        return
    end

    if now - lastEggScan > 0.55 then lastEggScan = now; pcall(scanEggs) end
    if now - lastBaseScan > 2.0 then lastBaseScan = now; pcall(scanBase) end
    pcall(updateESP)

    local char, hum, root = getChar(), getHum(), getRoot()
    if not char or not hum or not root then
        State.mode = "idle"
        return
    end

    -- noclip
    if State.noclip then
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
        end
    end

    -- anti stuck
    State.lastPos = State.lastPos or root.Position
    if now - (State.lastMoveCheck or 0) > 1.0 then
        State.lastMoveCheck = now
        local moved = (root.Position - State.lastPos).Magnitude
        State.lastPos = root.Position
        if State.mode ~= "idle" and moved < 3 then
            hum.Jump = true
            State.stuckCount = (State.stuckCount or 0) + 1
            if State.stuckCount > 4 then
                failTarget(State.target, "stuck")
                State.stuckCount = 0
            end
        else
            State.stuckCount = 0
        end
    end

    local function dist(v) return (root.Position - v).Magnitude end

    -- auto collect on base
    if State.autoCollect and myBase and now - (State.lastCollect or 0) > 1.2 then
        State.lastCollect = now
        fireInteracts(myBase.obj)
    end

    if State.mode == "idle" then
        State.target = nil
        if State.autoSteal then
            local t = pickTarget()
            if t then
                State.target = t
                State.mode = "goToEgg"
                State.timer = now
                State.dwell = 0
                uiLog("target " .. t.rarity.name .. " (" .. t.inst.Name .. ")")
            else
                setLock(State.speed)
            end
        else
            setLock(State.speed)
        end
        return
    end

    if State.mode == "goToEgg" then
        local t = State.target
        if not t or not t.inst or not t.inst:IsDescendantOf(workspace) then
            State.mode = "idle"; return
        end
        t.pos = centerOf(t.inst) or t.pos
        local d = dist(t.pos)
        if d > 5 then
            setLock(speedFor(d))
            if now - lastMove > 0.12 then hum:MoveTo(t.pos); lastMove = now end
            if now - State.timer > 18 then failTarget(t, "egg unreachable") end
        else
            setLock(State.slowSpeed)
            hum:MoveTo(t.pos)
            State.dwell = (State.dwell or 0) + dt
            if math.random() < 0.06 then hum.Jump = true end
            fireInteracts(t.inst)
            if State.dwell > 1.1 then
                if State.autoReturn then
                    State.mode = "goHome"; State.timer = now; State.dwell = 0
                else
                    State.mode = "idle"; State.dwell = 0
                end
            end
        end
        return
    end

    if State.mode == "goHome" then
        local home = (myBase and myBase.pos) or homeFallback
        if not home then State.mode = "idle"; return end
        local d = dist(home)
        if d > 6 then
            setLock(speedFor(d))
            if now - lastMove > 0.12 then hum:MoveTo(home); lastMove = now end
            if now - State.timer > 25 then uiLog("home timeout"); State.mode = "idle" end
        else
            setLock(State.slowSpeed)
            hum:MoveTo(home)
            State.dwell = (State.dwell or 0) + dt
            if myBase then fireInteracts(myBase.obj) end
            if State.dwell > (State.autoDrop and 0.8 or 0.4) then
                State.mode = "idle"; State.dwell = 0
            end
        end
        return
    end
end

bind(RunService.Heartbeat, onTick)

--=========================================================
--  ANTI-AFK
--=========================================================
bind(LP.Idled, function()
    if not State.antiAfk then return end
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.new())
    end)
end)

--=========================================================
--  KEYBIND
--=========================================================
bind(UIS.InputBegan, function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        State.enabled = not State.enabled
        uiLog(State.enabled and "ENABLED" or "PAUSED")
    end
end)

--=========================================================
--  HOME FALLBACK + STARTUP
--=========================================================
pcall(function()
    local c = getChar()
    if c then homeFallback = c:GetPivot().Position end
end)

pcall(scanEggs)
pcall(scanBase)

uiLog("ready — eggs:" .. #eggs .. " base:" .. (myBase and "found" or "NOT found"))
if not myBase then uiLog("base not found — using spawn") end

-- status refresh
bind(RunService.Heartbeat, (function()
    local last = 0
    return function()
        local now = os.clock()
        if now - last < 0.25 then return end
        last = now
        if not UI.statusLbl then return end
        UI.statusLbl.Text = State.enabled and (State.mode == "idle" and "Scanning…" or State.mode) or "Paused"
        local t = State.target
        UI.targetLbl.Text = t and ("Target: " .. t.rarity.name .. "  •  " .. t.inst.Name) or "Target: —"
        UI.targetLbl.TextColor3 = t and t.rarity.color or Color3.fromRGB(138,144,158)
        UI.countLbl.Text = "Eggs " .. #eggs .. "   Base " .. (myBase and "found" or "—") .. "   Speed " .. lock
    end
end)())

--=========================================================
--  UNLOAD
--=========================================================
local function unload()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for inst, h in pairs(espObjs) do pcall(function() h:Destroy() end) end
    if UI.sg then pcall(function() UI.sg:Destroy() end) end
    if getgenv then getgenv().__SAE_UNLOAD = nil end
    log("unloaded")
end
if getgenv then getgenv().__SAE_UNLOAD = unload end

log("ready. eggs=" .. #eggs .. " base=" .. tostring(myBase ~= nil))