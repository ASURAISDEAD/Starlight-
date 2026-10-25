-- Steal an Egg — WalkSpeed 500 + anticheat bypass  (by akkiwi, open source)
local SPEED = 500

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local genv = type(getgenv) == "function" and getgenv() or nil
if genv and genv.__SpeedBypassLoaded then
	return warn("[SpeedBypass] already running")
end

local missing = {}
if type(hookmetamethod) ~= "function" then table.insert(missing, "hookmetamethod") end
if type(hookfunction) ~= "function" then table.insert(missing, "hookfunction") end
if type(getgc) ~= "function" then table.insert(missing, "getgc") end
if type(islclosure) ~= "function" then table.insert(missing, "islclosure") end
if type(debug) ~= "table" or type(debug.info) ~= "function" or type(debug.getupvalues) ~= "function" then
	table.insert(missing, "debug.info/getupvalues")
end
if #missing > 0 then
	return warn("[SpeedBypass] your executor can't bypass the anticheat — missing: " .. table.concat(missing, ", "))
end

local lock = SPEED
local oldIndex
local newIndex = function(self, key, value)
	if lock and key == "WalkSpeed" and value ~= lock then
		local char = player.Character
		if char and self == char:FindFirstChildOfClass("Humanoid") then
			return
		end
	end
	return oldIndex(self, key, value)
end
if type(newcclosure) == "function" then
	newIndex = newcclosure(newIndex)
end
oldIndex = hookmetamethod(game, "__newindex", newIndex)

local targets = {}
for _, fn in next, getgc() do
	if typeof(fn) == "function" and islclosure(fn) then
		local okSrc, src = pcall(debug.info, fn, "s")
		if okSrc and type(src) == "string" and src:find("ContentCatalog%.Runtime") then
			local okA, params = pcall(debug.info, fn, "a")
			local okU, ups = pcall(debug.getupvalues, fn)
			if okA and params == 3 and okU and type(ups) == "table" and #ups == 5 then
				table.insert(targets, fn)
			end
		end
	end
end

local blinded = 0
for _, fn in ipairs(targets) do
	local orig
	local wrapper = function(a, b, c)
		local sample = orig(a, b, c)
		if type(sample) == "table" and sample.WalkSpeed and sample.Position and sample.Timestamp then
			sample.WalkSpeed = 100000
		end
		return sample
	end
	if type(newlclosure) == "function" then
		wrapper = newlclosure(wrapper)
	end
	local ok = pcall(function()
		orig = hookfunction(fn, wrapper)
	end)
	if ok and type(orig) == "function" then
		blinded += 1
	end
end

RunService.Heartbeat:Connect(function()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.WalkSpeed ~= SPEED then
		hum.WalkSpeed = SPEED
	end
end)

if genv then
	genv.__SpeedBypassLoaded = true
end

if blinded > 0 then
	print(("[SpeedBypass] WalkSpeed %d — anticheat bypassed"):format(SPEED))
else
	warn(("[SpeedBypass] WalkSpeed %d set, but the anticheat sampler wasn't found — expect rubber-banding"):format(SPEED))
end