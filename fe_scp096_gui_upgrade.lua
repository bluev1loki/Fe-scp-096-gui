-- fe_scp096_tools_core.lua (LocalScript - StarterPlayerScripts)
-- TEIL 1: Tool-Erzeugung + Psycho-Controller Grundgerüst
-- Konfiguration (falls du anpassen willst)
local AUTO_EQUIP = true          -- von deiner Wahl: AUTO_EQUIP = JA
local LOCK_MOVEMENT = true       -- LOCK_MOVEMENT = JA
local REMOTE_FAILSAFE = true
local DUPLICATE_BEHAVIOR = "CLEAN_REPLACE" -- CLEAN_REPLACE chosen earlier
local RESPAWN_REBUILD = true     -- RESPAWN_REBUILD = JA

-- Names used by client/server
local REMOTE_ATTACK_NAME = "SCP_AttackEvent"
local REMOTE_DASH_NAME = "SCP_DashEvent"

-- Tools/Attacks list (names)
local TOOLS_DEF = {
	{ Name = "Psy_ClawSwipe",    Display = "ClawSwipe", ToolId = "ATK1" }, -- front AoE
	{ Name = "Psy_NeckSnap",     Display = "NeckSnap",  ToolId = "ATK2" }, -- single target kill
	{ Name = "Psy_Leap",         Display = "Leap",      ToolId = "ATK3" }, -- dash + hit
	{ Name = "Psy_HeadRip",      Display = "HeadRip",   ToolId = "ATK4" }, -- grab kill
	{ Name = "Psy_ScreamStun",   Display = "Scream",    ToolId = "ATK5" }  -- stun + shake
}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
if not player then return end

-- State
local remoteAttack = nil
local remoteDash = nil
local createdTools = {}        -- map toolName -> instance
local psychoActive = false
local originalMovement = {}    -- to restore movement
local charHumanoidSignal = nil

-- UTIL: cleanup existing GUIs/Tools/Remotes if requested
local function cleanupExisting()
	-- remove previously created playergui items starting with SCP096_
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _,c in pairs(pg:GetChildren()) do
			if type(c.Name) == "string" and c.Name:match("^SCP096_") then
				pcall(function() c:Destroy() end)
			end
		end
	end

	-- remove tools in Backpack that we previously created
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _,t in pairs(backpack:GetChildren()) do
			if t:IsA("Tool") and t.Name:match("^Psy_") then
				pcall(function() t:Destroy() end)
			end
		end
	end

	-- optional: remove client-created remotes (best-effort)
	if REMOTE_FAILSAFE and ReplicatedStorage then
		pcall(function()
			local r = ReplicatedStorage:FindFirstChild(REMOTE_ATTACK_NAME)
			if r and r:IsA("RemoteEvent") and r:GetAttribute("clientCreated") then r:Destroy() end
			local d = ReplicatedStorage:FindFirstChild(REMOTE_DASH_NAME)
			if d and d:IsA("RemoteEvent") and d:GetAttribute("clientCreated") then d:Destroy() end
		end)
	end
end

-- Ensure RemoteEvents exist (client failsafe)
local function ensureRemotes()
	if not ReplicatedStorage then return end
	pcall(function()
		if not ReplicatedStorage:FindFirstChild(REMOTE_ATTACK_NAME) then
			if REMOTE_FAILSAFE then
				local e = Instance.new("RemoteEvent")
				e.Name = REMOTE_ATTACK_NAME
				e:SetAttribute("clientCreated", true)
				e.Parent = ReplicatedStorage
			end
		end
		if not ReplicatedStorage:FindFirstChild(REMOTE_DASH_NAME) then
			if REMOTE_FAILSAFE then
				local d = Instance.new("RemoteEvent")
				d.Name = REMOTE_DASH_NAME
				d:SetAttribute("clientCreated", true)
				d.Parent = ReplicatedStorage
			end
		end
	end)
	remoteAttack = ReplicatedStorage:FindFirstChild(REMOTE_ATTACK_NAME)
	remoteDash = ReplicatedStorage:FindFirstChild(REMOTE_DASH_NAME)
end

-- Movement lock/unlock
local function lockMovement(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	-- save originals
	originalMovement.WalkSpeed = humanoid.WalkSpeed
	originalMovement.JumpPower = humanoid.JumpPower
	pcall(function() humanoid.WalkSpeed = 0 end)
	pcall(function() humanoid.JumpPower = 0 end)
end

local function unlockMovement(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	pcall(function() if originalMovement.WalkSpeed then humanoid.WalkSpeed = originalMovement.WalkSpeed end end)
	pcall(function() if originalMovement.JumpPower then humanoid.JumpPower = originalMovement.JumpPower end end)
	originalMovement = {}
end

-- Helper: find player by UserId
local function playerByUserId(uid)
	for _,p in pairs(Players:GetPlayers()) do
		if p.UserId == uid then return p end
	end
	return nil
end

-- Client-side target prefilter (NOT_SAME_TEAM)
local function findTargets(originPos, radius)
	local targets = {}
	for _,plr in pairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
			local sameTeam = false
			pcall(function()
				if plr.Team and player.Team and plr.Team == player.Team then sameTeam = true end
			end)
			if not sameTeam then
				local root = plr.Character:FindFirstChild("HumanoidRootPart")
				if root and (root.Position - originPos).Magnitude <= radius then
					table.insert(targets, plr.UserId)
				end
			end
		end
	end
	return targets
end

-- Tool action helpers (these prepare arguments and fire remote)
-- NOTE: server will re-validate targets + apply damage
local function sendAttackRemote(originPos, lookVector, comboLevel, targetUserIds)
	if not remoteAttack or not remoteAttack:IsA("RemoteEvent") then return end
	pcall(function()
		remoteAttack:FireServer(originPos, lookVector, comboLevel or 1, targetUserIds or {})
	end)
end

local function sendDashRemote(originPos, lookVec)
	if not remoteDash or not remoteDash:IsA("RemoteEvent") then return end
	pcall(function()
		remoteDash:FireServer(originPos, lookVec)
	end)
end

-- Create a Tool instance with basic properties and activation handler
local function createTool(def)
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		-- Try to wait for one (unlikely to be nil long)
		backpack = player:WaitForChild("Backpack", 5)
		if not backpack then return nil end
	end

	-- If tool exists, remove (clean replace)
	local existing = backpack:FindFirstChild(def.Name)
	if existing then pcall(function() existing:Destroy() end) end

	local tool = Instance.new("Tool")
	tool.Name = def.Name
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.Parent = backpack

	-- Create a simple Handle for visuals (optional)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1,1,1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Parent = tool
	-- Tool grip default
	tool.Grip = CFrame.new()

	-- Activation behavior depends on def.ToolId
	tool.Activated:Connect(function()
		-- defensive checks
		local char = player.Character
		if not char or not char:FindFirstChild("HumanoidRootPart") then return end
		local root = char.HumanoidRootPart
		local origin = root.Position
		local look = root.CFrame.LookVector

		-- Choose different behavior per tool
		if def.ToolId == "ATK1" then
			-- ClawSwipe: front AoE -> send targets in radius in front
			local radius = 6
			local targets = findTargets(origin, radius)
			sendAttackRemote(origin, look, 1, targets)
		elseif def.ToolId == "ATK2" then
			-- NeckSnap: pick nearest valid target within small radius -> single target reported
			local radius = 5
			local candidates = findTargets(origin, radius)
			-- choose nearest
			local nearest = nil
			local nearestDist = math.huge
			for _,uid in ipairs(candidates) do
				local p = playerByUserId(uid)
				if p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
					local d = (p.Character.HumanoidRootPart.Position - origin).Magnitude
					if d < nearestDist then nearestDist = d; nearest = uid end
				end
			end
			if nearest then
				sendAttackRemote(origin, look, 2, {nearest})
			end
		elseif def.ToolId == "ATK3" then
			-- Leap: client visual dash forward; send server dash event and small AoE targets
			local dashDir = look
			-- Move client quickly (visual)
			pcall(function()
				local targetPos = root.Position + dashDir * 18
				root.CFrame = CFrame.new(targetPos)
			end)
			-- After jump, send attack remote with radius hit
			local targets = findTargets(root.Position, 5)
			sendAttackRemote(root.Position, dashDir, 1, targets)
			sendDashRemote(root.Position, dashDir)
		elseif def.ToolId == "ATK4" then
			-- HeadRip: attempt to grab nearest target in close range and report single target (special)
			local radius = 4
			local candidates = findTargets(origin, radius)
			local nearest, nearestDist = nil, math.huge
			for _,uid in ipairs(candidates) do
				local p = playerByUserId(uid)
				if p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
					local d = (p.Character.HumanoidRootPart.Position - origin).Magnitude
					if d < nearestDist then nearestDist = d; nearest = uid end
				end
			end
			if nearest then
				sendAttackRemote(origin, look, 3, {nearest})
			end
		elseif def.ToolId == "ATK5" then
			-- ScreamStun: AoE stun -> send targets in radius
			local radius = 8
			local targets = findTargets(origin, radius)
			sendAttackRemote(origin, look, 1, targets) -- server may treat as stun-type by checking ToolId from client? We'll send comboLevel=1 and server must infer type by target list and possibly attacker state.
		end
	end)

	-- store for later reference
	createdTools[def.Name] = tool

	return tool
end

-- Build all tools
local function buildAllTools()
	-- first ensure Backpack exists
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then backpack = player:WaitForChild("Backpack", 5) end
	if not backpack then return end

	for _,def in ipairs(TOOLS_DEF) do
		createTool(def)
	end

	-- auto-equip primary tool if requested
	if AUTO_EQUIP then
		-- try to equip first tool
		local firstDef = TOOLS_DEF[1]
		local tool = backpack:FindFirstChild(firstDef.Name)
		if tool and player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			pcall(function()
				if humanoid and humanoid.Parent then
					humanoid:EquipTool(tool)
				end
			end)
		end
	end
end

-- Toggle Psycho Mode (core state): apply movement lock / auto-equip all tools when active
local function enablePsychoMode()
	if psychoActive then return end
	psychoActive = true
	-- lock movement if requested
	local char = player.Character
	if char and LOCK_MOVEMENT then lockMovement(char) end

	-- auto-equip all tools so player can use them even when locked
	if AUTO_EQUIP then
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		local backpack = player:FindFirstChild("Backpack")
		if humanoid and backpack then
			for _,def in ipairs(TOOLS_DEF) do
				local t = backpack:FindFirstChild(def.Name)
				if t then
					pcall(function() humanoid:EquipTool(t) end)
				end
			end
		end
	end
end

local function disablePsychoMode()
	if not psychoActive then return end
	psychoActive = false
	-- restore movement
	local char = player.Character
	if char and LOCK_MOVEMENT then unlockMovement(char) end
	-- optionally unequip tools (we leave them in backpack)
end

-- Rebuild pipeline (on startup & respawn)
local function rebuildEverything()
	-- cleanup if CLEAN_REPLACE
	if DUPLICATE_BEHAVIOR == "CLEAN_REPLACE" then
		cleanupExisting()
	end
	ensureRemotes()
	buildAllTools()
end

-- Character add handler
local function onCharacterAdded(char)
	wait(0.1)
	-- store humanoid signal for later (if needed)
	if charHumanoidSignal then pcall(function() charHumanoidSignal:Disconnect() end) end
	local humanoid = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	if humanoid then
		-- optional: if psychoActive was on before respawn, reapply lock & auto-equip
		if psychoActive then
			if LOCK_MOVEMENT then lockMovement(char) end
			if AUTO_EQUIP then
				for _,def in ipairs(TOOLS_DEF) do
					local tool = player.Backpack and player.Backpack:FindFirstChild(def.Name)
					if tool then
						pcall(function() humanoid:EquipTool(tool) end)
					end
				end
			end
		end
	end
end

-- Public API for other client modules (later parts) to toggle psycho state
local ClientAPI = {}
function ClientAPI.EnablePsycho()
	enablePsychoMode()
end
function ClientAPI.DisablePsycho()
	disablePsychoMode()
end
function ClientAPI.IsPsycho()
	return psychoActive
end
function ClientAPI.GetTool(name)
	return createdTools[name]
end

-- Expose API on Player object for other local scripts to use (simple pattern)
pcall(function()
	player:SetAttribute("SCP_ClientAPI", true) -- marker
	-- store API in a lookup on player (nonstandard but works local)
	_G = _G or {}
	_G.SCP096_ClientAPI = ClientAPI
end)

-- Startup
rebuildEverything()
-- connect respawn rebuild
player.CharacterAdded:Connect(function(char)
	onCharacterAdded(char)
	if RESPAWN_REBUILD then
		-- small delay to allow Backpack to exist
		wait(0.5)
		rebuildEverything()
	end
end)

print("[SCP-CLIENT] Tools core initialized (Part 1)")

-- fe_scp096_effects.lua (LocalScript - StarterPlayerScripts)
-- TEIL 2: Animations, Psycho Effects (P1..P6) & Tool Attack Visuals
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
if not player then return end

-- Wait for ClientAPI from Part1
local tries = 0
while not _G.SCP096_ClientAPI and tries < 40 do
	tries = tries + 1
	wait(0.1)
end
local API = _G.SCP096_ClientAPI
if not API then
	warn("[SCP-096 EFFECTS] ClientAPI not found; ensure fe_scp096_tools_core.lua runs first.")
	return
end

-- Asset defaults (standard anims / particles / sounds)
local ATTACK_ANIM_IDS = {
	"rbxassetid://507766666", -- atk1
	"rbxassetid://507766667", -- atk2
	"rbxassetid://507766668"  -- atk3 (used where applicable)
}
local HEAVY_ANIM_ID = "rbxassetid://507766669" -- headrip / heavy (fallback)
local DASH_ANIM_ID = "rbxassetid://507766700"
local SCREAM_SOUND_ID = "rbxassetid://183860253"
local ATTACK_SFX_ID = "rbxassetid://12221967"
local PARTICLE_TEXTURE = "rbxassetid://243660709"

-- Psycho-mode effect params (P1..P6)
local PSYCHO = {
	cameraShakeIntensity = 0.8,
	cameraShakeDuration = math.huge, -- continuous while psycho on, we implement custom loop
	vignette = {Enabled=true, Contrast=0.15, Saturation=-0.4},
	screenFlicker = true,
	headJitterAmount = 0.04,
	scaleAmount = 1.12,
	lightFlickerRate = 0.08,
	screamLoopVolume = 1.0
}

-- Internal state
local psychoOn = false
local screamSoundInst = nil
local ppInstances = {} -- to store effects (Blur/Color/Vignette etc.)
local psychoConn = nil
local lightFlickerConn = nil

-- Small utilities
local function safeFindTool(name)
	return API.GetTool and API.GetTool(name) or nil
end

local function playSoundAt(part, assetId, loop, volume)
	if not part then return nil end
	local s = Instance.new("Sound", part)
	s.SoundId = tostring(assetId)
	s.Looped = loop or false
	s.Volume = volume or 1
	s:Play()
	Debris:AddItem(s, 15)
	return s
end

local function spawnBurstAt(pos, amount, tex)
	local attach = Instance.new("Attachment")
	attach.WorldPosition = pos
	local pe = Instance.new("ParticleEmitter", attach)
	pe.Texture = tex or PARTICLE_TEXTURE
	pe.Lifetime = NumberRange.new(0.25, 0.7)
	pe.Speed = NumberRange.new(6, 14)
	pe.RotSpeed = NumberRange.new(-180, 180)
	pe.Rate = 0
	pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0)})
	pe:Emit(amount or 32)
	Debris:AddItem(attach, 1.2)
end

local function smallScreenFlash()
	local gui = Instance.new("ScreenGui", player:WaitForChild("PlayerGui"))
	gui.Name = "SCP_TEMP_FLASH"
	local frame = Instance.new("Frame", gui)
	frame.Size = UDim2.new(1,0,1,0)
	frame.BackgroundColor3 = Color3.new(1,1,1)
	frame.BackgroundTransparency = 1
	for i=1,6 do frame.BackgroundTransparency = 1 - i*0.14; wait(0.015) end
	for i=1,6 do frame.BackgroundTransparency = i*0.14; wait(0.015) end
	gui:Destroy()
end

-- camera shake (one-shot)
local function cameraShakeOnce(intensity, duration)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local orig = cam.CFrame
	local t0 = tick()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local dt = tick() - t0
		if dt > duration then
			conn:Disconnect()
			cam.CFrame = orig
			return
		end
		local pct = 1 - dt/duration
		local x = (math.random()-0.5)*2*intensity*pct
		local y = (math.random()-0.5)*2*intensity*pct
		local z = (math.random()-0.5)*2*intensity*pct
		cam.CFrame = orig * CFrame.new(x,y,z)
	end)
end

-- persistent psycho camera jitter (P1)
local psychoShakeConn = nil
local function startPsychoCameraJitter()
	if psychoShakeConn then return end
	local cam = workspace.CurrentCamera
	local t0 = tick()
	local orig = cam.CFrame
	psychoShakeConn = RunService.RenderStepped:Connect(function()
		if not psychoOn then
			psychoShakeConn:Disconnect(); psychoShakeConn = nil
			cam.CFrame = orig
			return
		end
		local i = PSYCHO.cameraShakeIntensity * 0.5
		local x = (math.sin(tick()*12) * i) + ((math.random()-0.5)*i*0.25)
		local y = (math.cos(tick()*10) * i*0.6) + ((math.random()-0.5)*i*0.25)
		local z = (math.random()-0.5)*i*0.2
		cam.CFrame = orig * CFrame.new(x,y,z)
	end)
end

-- postprocessing (P2)
local function enablePsychoPostProcessing()
	-- Blur
	if not Lighting:FindFirstChild("SCP_Psycho_Blur") then
		local blur = Instance.new("BlurEffect", Lighting)
		blur.Name = "SCP_Psycho_Blur"; blur.Size = 0
		TweenService:Create(blur, TweenInfo.new(0.6), {Size = 22}):Play()
		ppInstances.blur = blur
	end
	-- Color correction / vignette via ColorCorrectionEffect & Bloom
	if not Lighting:FindFirstChild("SCP_Psycho_Color") then
		local cc = Instance.new("ColorCorrectionEffect", Lighting)
		cc.Name = "SCP_Psycho_Color"; cc.Saturation = 0
		TweenService:Create(cc, TweenInfo.new(0.6), {Saturation = -0.6, Contrast = 0.1}):Play()
		ppInstances.cc = cc
	end
	if not Lighting:FindFirstChild("SCP_Psycho_Bloom") then
		local bloom = Instance.new("BloomEffect", Lighting)
		bloom.Name = "SCP_Psycho_Bloom"; bloom.Intensity = 0
		TweenService:Create(bloom, TweenInfo.new(0.6), {Intensity = 1.6}):Play()
		ppInstances.bloom = bloom
	end
end

local function disablePsychoPostProcessing()
	if ppInstances.blur then
		TweenService:Create(ppInstances.blur, TweenInfo.new(0.4), {Size = 0}):Play()
		Debris:AddItem(ppInstances.blur,0.6); ppInstances.blur = nil
	end
	if ppInstances.cc then
		TweenService:Create(ppInstances.cc, TweenInfo.new(0.4), {Saturation = 0, Contrast = 0}):Play()
		Debris:AddItem(ppInstances.cc,0.6); ppInstances.cc = nil
	end
	if ppInstances.bloom then
		TweenService:Create(ppInstances.bloom, TweenInfo.new(0.4), {Intensity = 0}):Play()
		Debris:AddItem(ppInstances.bloom,0.6); ppInstances.bloom = nil
	end
end

-- head jitter (P4)
local headJitterConn = nil
local function startHeadJitter()
	if headJitterConn then return end
	headJitterConn = RunService.Heartbeat:Connect(function()
		if not psychoOn then headJitterConn:Disconnect(); headJitterConn = nil; return end
		local char = player.Character
		if not char then return end
		local head = char:FindFirstChild("Head")
		if head then
			local angle = math.sin(tick()*20) * PSYCHO.headJitterAmount
			pcall(function() head.CFrame = head.CFrame * CFrame.Angles(0, math.rad(angle*10), math.rad(angle*6)) end)
		end
	end)
end

-- body scale (P5)
local origScales = {}
local function applyBodyScale()
	local char = player.Character
	if not char then return end
	for _,part in pairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			if not origScales[part] then origScales[part] = {Size = part.Size} end
			pcall(function() part.Size = part.Size * PSYCHO.scaleAmount end)
		end
	end
end
local function restoreBodyScale()
	local char = player.Character
	if not char then return end
	for part,data in pairs(origScales) do
		if part and part.Parent then
			pcall(function() part.Size = data.Size end)
		end
	end
	origScales = {}
end

-- light flicker (P6) - clientside random intensity adjustments to Lighting (best-effort)
local function startLightFlicker()
	if lightFlickerConn then return end
	lightFlickerConn = RunService.Heartbeat:Connect(function()
		if not psychoOn then lightFlickerConn:Disconnect(); lightFlickerConn = nil; return end
		-- vary ambient and outdoorAmbient slightly
		local t = 0.5 + math.abs(math.sin(tick()*6))*0.5
		Lighting.Ambient = Color3.fromRGB(50 * t, 50 * t, 55 * t)
		-- small, rapidly decaying flicker effect
		if math.random() < PSYCHO.lightFlickerRate then
			local pulse = 0.3 + math.random()*0.7
			local old = Lighting.Brightness
			TweenService:Create(Lighting, TweenInfo.new(0.08), {Brightness = old * pulse}):Play()
			delay(0.08, function() pcall(function() Lighting.Brightness = old end) end)
		end
	end)
end

-- scream loop (P3)
local function startScreamLoop()
	local char = player.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end
	if screamSoundInst and screamSoundInst.Parent == head then return end
	screamSoundInst = Instance.new("Sound", head)
	screamSoundInst.Name = "SCP_Psycho_Scream"
	screamSoundInst.SoundId = SCREAM_SOUND_ID
	screamSoundInst.Looped = true
	screamSoundInst.Volume = PSYCHO.screamLoopVolume
	screamSoundInst:Play()
	Debris:AddItem(screamSoundInst, 30)
end
local function stopScreamLoop()
	if screamSoundInst then
		pcall(function() screamSoundInst:Stop(); screamSoundInst:Destroy() end)
		screamSoundInst = nil
	end
end

-- Psycho ON/OFF
local function enablePsychoEffects()
	if psychoOn then return end
	psychoOn = true
	-- camera jitter
	startPsychoCameraJitter()
	-- postprocessing
	enablePsychoPostProcessing()
	-- head jitter
	startHeadJitter()
	-- scale body
	applyBodyScale()
	-- light flicker
	startLightFlicker()
	-- scream loop
	startScreamLoop()
end

local function disablePsychoEffects()
	if not psychoOn then return end
	psychoOn = false
	-- stop camera jitter handled by its conn
	-- postprocessing restore
	disablePsychoPostProcessing()
	-- restore head and body transforms
	if headJitterConn then headJitterConn:Disconnect(); headJitterConn = nil end
	restoreBodyScale()
	stopScreamLoop()
	-- restore lighting to defaults (best-effort)
	pcall(function()
		Lighting.Ambient = Color3.fromRGB(128,128,128)
		Lighting.Brightness = 2
	end)
end

-- Tool-specific visual enhancement handlers
local function hookToolVisuals(tool)
	if not tool or not tool:IsA("Tool") then return end
	-- avoid multiple binds
	if tool:GetAttribute("SCP_VisualHooked") then return end
	tool:SetAttribute("SCP_VisualHooked", true)

	tool.Activated:Connect(function()
		local char = player.Character
		if not char or not char:FindFirstChild("HumanoidRootPart") then return end
		local root = char.HumanoidRootPart
		local pos = root.Position
		-- small common effects
		spawnBurstAt = spawnBurstAt or spawnBurstAt -- keep local reference
		-- identify by tool name prefix "Psy_"
		local n = tool.Name
		if n:match("ClawSwipe") or n:match("Claw") then
			-- ATK1 visual: quick swipe anim, forward cone particle, small shake
			pcall(function() playAnim(char, ATTACK_ANIM_IDS[1]) end)
			spawnBurstAt(pos + root.CFrame.LookVector * 2, 28, PARTICLE_TEXTURE)
			cameraShakeOnce(0.6, 0.3)
		elseif n:match("NeckSnap") then
			-- ATK2 visual: heavy two-hand animation, head snap local overlay (on nearest)
			pcall(function() playAnim(char, ATTACK_ANIM_IDS[2]) end)
			cameraShakeOnce(1.0, 0.45)
			-- local hit mark on nearest target
			local radius = 6
			local nearest = nil; local nd = math.huge
			for _,pl in pairs(Players:GetPlayers()) do
				if pl ~= player and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") then
					local d = (pl.Character.HumanoidRootPart.Position - pos).Magnitude
					if d < nd and d <= radius then nearest = pl; nd = d end
				end
			end
			if nearest and nearest.Character then
				local head = nearest.Character:FindFirstChild("Head")
				if head then
					local mark = Instance.new("Attachment", head)
					mark.WorldPosition = head.Position
					local pe = Instance.new("ParticleEmitter", mark)
					pe.Texture = PARTICLE_TEXTURE
					pe.Lifetime = NumberRange.new(0.3,0.6)
					pe.Rate = 0
					pe:Emit(18)
					Debris:AddItem(mark, 1)
				end
			end
		elseif n:match("Leap") then
			-- ATK3 visual: dash blur + ground smash
			pcall(function() playAnim(char, DASH_ANIM_ID) end)
			cameraShakeOnce(0.9, 0.45)
			spawnBurstAt(pos, 36, PARTICLE_TEXTURE)
		elseif n:match("HeadRip") then
			-- ATK4 visual: heavy gore-ish animation, big screen flash
			pcall(function() playAnim(char, HEAVY_ANIM_ID) end)
			screenFlash()
			cameraShakeOnce(1.2, 0.6)
			spawnBurstAt(pos, 50, PARTICLE_TEXTURE)
		elseif n:match("Scream") or n:match("Stun") then
			-- ATK5 visual: scream pulse: vignette + tremor
			pcall(function() playAnim(char, ATTACK_ANIM_IDS[1]) end)
			-- temporary strong color shift
			local cc = Instance.new("ColorCorrectionEffect", Lighting)
			cc.Saturation = -1; cc.Contrast = 0.15; cc.Name = "SCP_TEMP_PULSE"
			Debris:AddItem(cc, 0.9)
			cameraShakeOnce(1.0, 0.5)
			-- local scream sound burst
			playSoundAt(char:FindFirstChild("Head") or root, ATTACK_SFX_ID, false, 1.2)
		else
			-- fallback small effect
			spawnBurstAt(pos, 18, PARTICLE_TEXTURE)
			cameraShakeOnce(0.35, 0.25)
		end
	end)
end

-- Helper to play animation with animator
function playAnim(character, animId)
	if not character or not animId then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then animator = Instance.new("Animator", humanoid) end
	local anim = Instance.new("Animation")
	anim.AnimationId = tostring(animId)
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	if ok and track then
		track:Play()
		track:AdjustSpeed(1)
		track.Stopped:Connect(function() pcall(function() anim:Destroy() end) end)
		return track
	else
		pcall(function() anim:Destroy() end)
	end
end

-- Hook all created tools (from Part1)
local function hookAllTools()
	for _,def in pairs({"Psy_ClawSwipe","Psy_NeckSnap","Psy_Leap","Psy_HeadRip","Psy_ScreamStun"}) do
		local t = API.GetTool(def)
		if t then
			hookToolVisuals(t)
		end
	end
end

-- Psycho toggle UI (small center toggle so you can enable Psycho mode quickly)
local function buildPsychoToggleGUI()
	local pg = player:WaitForChild("PlayerGui")
	-- remove existing
	local existing = pg:FindFirstChild("SCP096_PSYCHO_TOGGLE")
	if existing then existing:Destroy() end
	local sg = Instance.new("ScreenGui", pg); sg.Name = "SCP096_PSYCHO_TOGGLE"; sg.ResetOnSpawn = false
	local btn = Instance.new("TextButton", sg)
	btn.Size = UDim2.new(0, 180, 0, 40)
	btn.Position = UDim2.new(0.5, -90, 0.85, 0)
	btn.Text = "Psycho Mode: OFF"
	btn.Font = Enum.Font.SourceSansBold
	btn.TextSize = 18
	btn.BackgroundTransparency = 0.25
	btn.TextColor3 = Color3.new(1,1,1)
	btn.MouseButton1Click:Connect(function()
		if not psychoOn then
			-- enable both client controller (API) and visual effects
			pcall(function() API.EnablePsycho() end)
			enablePsychoEffects()
			btn.Text = "Psycho Mode: ON"
			btn.BackgroundColor3 = Color3.fromRGB(80,0,0)
		else
			pcall(function() API.DisablePsycho() end)
			disablePsychoEffects()
			btn.Text = "Psycho Mode: OFF"
			btn.BackgroundColor3 = Color3.new()
		end
	end)
end

-- Watch for character changes to reapply scream loop or head jitter if psycho active
player.CharacterAdded:Connect(function(char)
	wait(0.2)
	if psychoOn then
		startPsychoCameraJitter()
		startHeadJitter()
		applyBodyScale()
		startLightFlicker()
		startScreamLoop()
	end
	-- rehook tools after respawn
	wait(0.4)
	hookAllTools()
end)

-- init hookup
hookAllTools()
buildPsychoToggleGUI()

print("[SCP-096 EFFECTS] loaded (Part 2)")

-- fe_scp096_gui_upgrade.lua (LocalScript - StarterPlayerScripts)
-- TEIL 3: GUI Panel Upgrade, Viewport Previews, Heavy Camera Sequences & final bindings
-- Erwartet: fe_scp096_tools_core.lua (Part1) und fe_scp096_effects.lua (Part2) bereits vorhanden
-- Platziere diese Datei ebenfalls in StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
if not player then return end

-- wait for ClientAPI from Part1
local tries = 0
while not _G.SCP096_ClientAPI and tries < 50 do
	tries = tries + 1
	wait(0.08)
end
local API = _G.SCP096_ClientAPI
if not API then
	warn("[SCP-096 GUI UPGRADE] ClientAPI missing. Stelle sicher, dass Part1 geladen wurde.")
	return
end

-- CONFIG (passt zu deinen Vorgaben)
local GUI_NAME = "SCP096_GUI_PANEL" -- panel name (center/dark)
local PANEL_THEME = "DARK" -- DARK = dunkel
local AUTO_EQUIP = true

-- small helper: safe play animation wrapper (uses Part2 helper if available)
local function safePlayAnim(char, animId)
	if not char or not animId then return end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then animator = Instance.new("Animator", humanoid) end
		local anim = Instance.new("Animation")
		anim.AnimationId = tostring(animId)
		local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
		if ok and track then
			track:Play()
			track.Stopped:Connect(function() pcall(function() anim:Destroy() end) end)
			return track
		else
			pcall(function() anim:Destroy() end)
		end
	end
end

-- Camera heavy sequence (for HeadRip / Heavy attacks)
local function heavyCameraSequence(duration, intensity)
	duration = duration or 0.8
	intensity = intensity or 2.0
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local orig = cam.CFrame
	-- zoom in slightly and quick rotate
	local target = orig * CFrame.new(0, -1.2, -3) * CFrame.Angles(math.rad(-8), 0, 0)
	local tween = TweenService:Create(cam, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {CFrame = target})
	pcall(function() tween:Play() end)
	-- small shake loop
	local t0 = tick()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local dt = tick() - t0
		if dt > duration then
			conn:Disconnect()
			pcall(function() cam.CFrame = orig end)
			return
		end
		local pct = 1 - dt / duration
		local x = (math.random()-0.5)*0.05*intensity*pct
		local y = (math.random()-0.5)*0.05*intensity*pct
		local z = (math.random()-0.5)*0.05*intensity*pct
		pcall(function() cam.CFrame = (orig * CFrame.new(0, -1.2, -3)) * CFrame.new(x,y,z) end)
	end)
end

-- small util to create a viewport preview model for a tool (simple parts as placeholder)
local function makeViewportModel(toolName)
	local model = Instance.new("Model")
	model.Name = "VP_"..toolName
	-- placeholder: create a few parts to represent the tool visually
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(1.5, 0.3, 1.5)
	base.Anchored = true
	base.CanCollide = false
	base.Position = Vector3.new(0, 0, 0)
	base.Material = Enum.Material.Metal
	base.Parent = model

	local spike = Instance.new("Part")
	spike.Name = "Spike"
	spike.Size = Vector3.new(0.2, 1.0, 0.2)
	spike.Anchored = true
	spike.CanCollide = false
	spike.Position = Vector3.new(0, 0.7, 0)
	spike.CFrame = spike.CFrame * CFrame.Angles(0, math.rad(45), 0)
	spike.Material = Enum.Material.SmoothPlastic
	spike.Parent = model

	-- small decoration
	local orb = Instance.new("Part")
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(0.5,0.5,0.5)
	orb.Anchored = true
	orb.Position = Vector3.new(0.6, 0.5, 0)
	orb.Material = Enum.Material.Neon
	orb.Parent = model

	return model
end

-- Build the central panel (centered, dark)
local function buildPanel()
	-- ensure previous removed
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild(GUI_NAME)
	if existing then existing:Destroy() end

	local sg = Instance.new("ScreenGui", pg)
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true

	local frame = Instance.new("Frame", sg)
	frame.Name = "MainFrame"
	frame.Size = UDim2.new(0, 520, 0, 320)
	frame.AnchorPoint = Vector2.new(0.5,0.5)
	frame.Position = UDim2.new(0.5, 0.5, 0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(12,12,12)
	frame.BackgroundTransparency = 0.14
	frame.BorderSizePixel = 0
	frame.ZIndex = 2
	frame.Active = true
	frame.Draggable = true

	-- Title
	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -24, 0, 36)
	title.Position = UDim2.new(0, 12, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "SCP-096 — Psycho Panel"
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(235,235,235)
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left

	-- Left column: viewport previews (3)
	local left = Instance.new("Frame", frame")
	left.Name = "Left"
	left.Size = UDim2.new(0, 200, 1, -56)
	left.Position = UDim2.new(0, 12, 0, 52)
	left.BackgroundTransparency = 1

	-- create three viewportFrames stacked to preview tools (ATK1..ATK3)
	for i=1,3 do
		local vp = Instance.new("ViewportFrame", left)
		vp.Size = UDim2.new(1, 0, 0, 60)
		vp.Position = UDim2.new(0, 0, 0, (i-1)*66)
		vp.BackgroundTransparency = 0.6
		vp.BorderSizePixel = 0
		vp.Name = "VP_"..tostring(i)
		-- model
		local model = makeViewportModel("ToolVP"..i)
		model.Parent = vp
		-- set camera
		local cam = Instance.new("Camera")
		cam.FieldOfView = 70
		cam.CFrame = CFrame.new(Vector3.new(0,2.5,6), Vector3.new(0,0,0))
		cam.Parent = vp
		vp.CurrentCamera = cam
		-- simple rotate animation
		spawn(function()
			while vp and vp.Parent do
				for a=0,360,4 do
					cam.CFrame = CFrame.new(Vector3.new(0,2.5,6), Vector3.new(0,0,0)) * CFrame.Angles(0, math.rad(a), 0)
					wait(0.03)
				end
			end
		end)
	end

	-- Right column: buttons (Attack Tools) and status
	local right = Instance.new("Frame", frame)
	right.Name = "Right"
	right.Size = UDim2.new(0, 292, 1, -56)
	right.Position = UDim2.new(0, 228, 0, 52)
	right.BackgroundTransparency = 1

	-- Buttons grid
	local btnNames = {
		{Key="Psy_ClawSwipe", Label="ClawSwipe"},
		{Key="Psy_NeckSnap", Label="NeckSnap"},
		{Key="Psy_Leap", Label="Leap"},
		{Key="Psy_HeadRip", Label="HeadRip"},
		{Key="Psy_ScreamStun", Label="ScreamStun"}
	}
	local startY = 0
	for idx,info in ipairs(btnNames) do
		local r = math.floor((idx-1)/2)
		local c = ((idx-1)%2)
		local btn = Instance.new("TextButton", right)
		btn.Name = info.Key.."_Btn"
		btn.Size = UDim2.new(0, 140, 0, 46)
		btn.Position = UDim2.new(0, c*146, 0, r*56 + startY)
		btn.BackgroundTransparency = 0.12
		btn.Text = info.Label
		btn.Font = Enum.Font.GothamSemibold
		btn.TextSize = 16
		btn.TextColor3 = Color3.fromRGB(240,240,240)
		btn.AutoButtonColor = true

		-- bind click: equip & activate the corresponding tool (so tools are used as interface)
		btn.MouseButton1Click:Connect(function()
			-- if tool exists in backpack or character, equip it and activate
			local tool = API.GetTool(info.Key)
			if tool then
				-- equip first
				local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					pcall(function() humanoid:EquipTool(tool) end)
				end
				-- simulate activation by firing the tool's Activated event: tools will run their code when activated normally.
				-- There is no direct way to call Activated; equipping + sending a MouseClick/simulated activation can be achieved by invoking tool:Activate() (not public API),
				-- so we instead simulate by toggling the tool's handle and calling a protected method via RemoteEvent: We'll directly call Tool:Activate if present.
				pcall(function()
					if tool and tool.Parent and tool:FindFirstChild("Handle") then
						-- attempt to call the server-friendly way: just fire a click through a small debounce and let the tool.Activated listeners run
						-- Use humanoid:EquipTool above to ensure tool is equipped; then simulate click by briefly setting a custom attribute that tool listeners might watch.
						-- As fallback, trigger tool.Activated by calling a BindableEvent on the tool if available
						local be = tool:FindFirstChild("SCP_ManualActivate")
						if be and be:IsA("BindableEvent") then
							be:Fire()
						else
							-- many tool scripts listen to tool.Activated, but it's only fired by user input.
							-- We attempt to emulate by briefly unequipping/equipping to reset, and then asking user to click or rely on AutoEquip+Click
							-- Fallback: call a custom function on the tool if it exists
							if tool.Activate then
								pcall(function() tool:Activate() end)
							end
						end
					end
				end)
			else
				warn("Tool nicht gefunden:", info.Key)
			end
		end)
	end

	-- Psycho toggle and small status
	local psychoBtn = Instance.new("TextButton", right)
	psychoBtn.Name = "PsychoToggle"
	psychoBtn.Size = UDim2.new(0, 292, 0, 44)
	psychoBtn.Position = UDim2.new(0, 0, 0, 176)
	psychoBtn.Text = "Psycho: OFF"
	psychoBtn.Font = Enum.Font.GothamBold
	psychoBtn.TextSize = 18
	psychoBtn.BackgroundTransparency = 0.08
	psychoBtn.TextColor3 = Color3.fromRGB(240,240,240)

	psychoBtn.MouseButton1Click:Connect(function()
		-- toggle via ClientAPI from Part1 and Part2
		if API.IsPsycho and API.IsPsycho() then
			pcall(function() API.DisablePsycho() end)
			-- also ensure visual effects disabled if present (Part2 functions will handle)
			pcall(function() disablePsychoEffects() end)
			psychoBtn.Text = "Psycho: OFF"
			psychoBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
		else
			pcall(function() API.EnablePsycho() end)
			pcall(function() enablePsychoEffects() end)
			psychoBtn.Text = "Psycho: ON"
			psychoBtn.BackgroundColor3 = Color3.fromRGB(100,8,8)
			-- auto-equip all tools
			if AUTO_EQUIP and player.Character then
				local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					for _,tdef in pairs({"Psy_ClawSwipe","Psy_NeckSnap","Psy_Leap","Psy_HeadRip","Psy_ScreamStun"}) do
						local t = API.GetTool(tdef)
						if t then pcall(function() humanoid:EquipTool(t) end) end
					end
				end
			end
		end
	end)

	-- Close button
	local closeBtn = Instance.new("TextButton", frame)
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -36, 0, 8)
	closeBtn.Text = "X"
	closeBtn.Font = Enum.Font.SourceSansBold
	closeBtn.TextSize = 18
	closeBtn.BackgroundTransparency = 0.45
	closeBtn.TextColor3 = Color3.fromRGB(220,220,220)
	closeBtn.MouseButton1Click:Connect(function() sg:Destroy() end)

	return sg, frame
end

-- Hook to call heavy camera sequence from Part2 when HeadRip tool is used
-- We'll attach a listener to the tool activation to trigger the sequence locally for dramatic effect
local function hookHeavyCameraOnHeadRip()
	local tool = API.GetTool("Psy_HeadRip")
	if not tool then return end
	tool.Activated:Connect(function()
		-- play heavy cam locally
		heavyCameraSequence(1.0, 2.2)
	end)
end

-- Attempt to call Part2's enable/disable functions if they exist in global scope
-- These are defined in Part2; if not present, ignore gracefully
local function enablePsychoEffects() 
	if _G and _G.SCP096_ClientAPI then
		-- Part2 created functions in its local scope; if not accessible, they'll be handled by its toggle UI.
	end
	-- Try to call global named function if it exists in environment (fallback)
	pcall(function() if enablePsychoEffects then enablePsychoEffects() end end)
end
local function disablePsychoEffects()
	pcall(function() if disablePsychoEffects then disablePsychoEffects() end end)
end

-- Initialize GUI
local ok, sg = pcall(function() return buildPanel() end)
if not ok then warn("[SCP-096 GUI UPGRADE] Fehler beim Erstellen des Panels:", sg) end

-- Hook heavy camera on HeadRip and hook visuals for tools (ensure Part2 hooked visuals too)
hookHeavyCameraOnHeadRip()
-- Try to hook visuals on all tools (some hooks already created in Part2)
spawn(function()
	wait(0.6)
	-- try a few times for tools to be created
	for i=1,8 do
		for _,n in ipairs({"Psy_ClawSwipe","Psy_NeckSnap","Psy_Leap","Psy_HeadRip","Psy_ScreamStun"}) do
			local t = API.GetTool(n)
			if t then
				-- ensure Part2's hookToolVisuals is called (it runs on script init, but double-call safe)
				pcall(function()
					-- call a harmless activation bindable if available
					if t:GetAttribute("SCP_VisualHooked") then else t:SetAttribute("SCP_VisualHooked", true) end
				end)
			end
		end
		wait(0.25)
	end
end)

-- Clean-up on script disable/destroy
script.Destroying:Connect(function()
	pcall(function()
		local pg = player:FindFirstChild("PlayerGui")
		if pg then
			local e = pg:FindFirstChild(GUI_NAME)
			if e then e:Destroy() end
		end
	end)
end)

print("[SCP-096 GUI UPGRADE] loaded (Part 3)")
