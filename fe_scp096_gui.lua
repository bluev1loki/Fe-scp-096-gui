-- fe_scp096_gui.lua (LocalScript - FE)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local player = Players.LocalPlayer

-- Konfiguration (ersetze bei Bedarf)
local TRANSFORM_WALKSPEED = 40
local TRANSFORM_JUMPPOWER = 75
local SCREAM_SOUND_ID = "rbxassetid://183860253"
local ATTACK_ANIM_ID = "rbxassetid://507766666"
local ATTACK_SOUND_ID = "rbxassetid://12221967"
local ATTACK_PARTICLE_TEXTURE = "rbxassetid://243660709"
local ATTACK_COOLDOWN = 1.2
local REMOTE_EVENT_NAME = "SCP_AttackEvent"

local remote = ReplicatedStorage:FindFirstChild(REMOTE_EVENT_NAME)

local original = {}
local lastAttack = 0

local function waitForChildOfClass(parent, className, timeout)
	local t0 = tick()
	local obj = parent:FindFirstChildOfClass(className)
	while not obj and tick() - t0 < (timeout or 5) do
		parent.ChildAdded:Wait()
		obj = parent:FindFirstChildOfClass(className)
	end
	return obj
end

local function saveOriginals(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	original.walkSpeed = humanoid.WalkSpeed
	original.jumpPower = humanoid.JumpPower
	original.hipHeight = humanoid.HipHeight
	original.partColors = {}
	for _,part in pairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			original.partColors[part:GetFullName()] = {Color = part.Color, Transparency = part.Transparency, Material = part.Material}
		end
	end
end

local function applyTransform(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	if not original.walkSpeed then saveOriginals(character) end
	humanoid.WalkSpeed = TRANSFORM_WALKSPEED
	humanoid.JumpPower = TRANSFORM_JUMPPOWER
	if humanoid.HipHeight then humanoid.HipHeight = 2 end

	for _, part in pairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			if not original.partColors[part:GetFullName()] then
				original.partColors[part:GetFullName()] = {Color = part.Color, Transparency = part.Transparency, Material = part.Material}
			end
			part.Color = Color3.fromRGB(240,240,250)
			if part ~= character:FindFirstChild("Head") then
				part.Transparency = math.clamp(part.Transparency + 0.06, 0, 0.45)
			end
		end
	end

	local head = character:FindFirstChild("Head")
	if head then
		local face = head:FindFirstChild("face") or head:FindFirstChildWhichIsA("Decal")
		if face then face.Transparency = 1 end
		if SCREAM_SOUND_ID and SCREAM_SOUND_ID ~= "" then
			local s = Instance.new("Sound", head)
			s.Name = "SCP096_ScreamLocal"
			s.SoundId = SCREAM_SOUND_ID
			s.Looped = false
			s:Play()
			Debris:AddItem(s, 6)
		end
	end
end

local function restoreOriginals(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if original.walkSpeed then humanoid.WalkSpeed = original.walkSpeed end
		if original.jumpPower then humanoid.JumpPower = original.jumpPower end
		if original.hipHeight then humanoid.HipHeight = original.hipHeight end
	end
	for _, part in pairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local data = original.partColors and original.partColors[part:GetFullName()]
			if data then
				part.Color = data.Color
				part.Transparency = data.Transparency
				part.Material = data.Material
			end
		end
	end
	local head = character:FindFirstChild("Head")
	if head then
		local face = head:FindFirstChild("face") or head:FindFirstChildWhichIsA("Decal")
		if face then face.Transparency = 0 end
	end
	original = {}
end

-- GUI erstellen
local playerGui = player:WaitForChild("PlayerGui")
local existing = playerGui:FindFirstChild("SCP096_GUI")
if existing then existing:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SCP096_GUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 260, 0, 170)
mainFrame.Position = UDim2.new(0, 20, 0, 60)
mainFrame.BackgroundTransparency = 0.25
mainFrame.BackgroundColor3 = Color3.fromRGB(20,20,20)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui
mainFrame.Active = true
mainFrame.Draggable = true

local title = Instance.new("TextLabel", mainFrame)
title.Size = UDim2.new(1, -10, 0, 32)
title.Position = UDim2.new(0, 5, 0, 5)
title.BackgroundTransparency = 1
title.Text = "SCP-096 — Verwandlung"
title.TextColor3 = Color3.fromRGB(230,230,230)
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left

local btnTransform = Instance.new("TextButton", mainFrame)
btnTransform.Size = UDim2.new(0, 240, 0, 36)
btnTransform.Position = UDim2.new(0, 10, 0, 42)
btnTransform.Text = "Verwandeln"
btnTransform.Font = Enum.Font.SourceSans
btnTransform.TextSize = 18

local btnAttack = Instance.new("TextButton", mainFrame)
btnAttack.Size = UDim2.new(0, 116, 0, 30)
btnAttack.Position = UDim2.new(0, 10, 0, 84)
btnAttack.Text = "Attack"
btnAttack.Font = Enum.Font.SourceSansBold
btnAttack.TextSize = 16

local btnReset = Instance.new("TextButton", mainFrame)
btnReset.Size = UDim2.new(0, 116, 0, 30)
btnReset.Position = UDim2.new(0, 134, 0, 84)
btnReset.Text = "Zurücksetzen"
btnReset.Font = Enum.Font.SourceSans
btnReset.TextSize = 14

local hint = Instance.new("TextLabel", mainFrame)
hint.Size = UDim2.new(0, 240, 0, 24)
hint.Position = UDim2.new(0, 10, 0, 122)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.SourceSansItalic
hint.TextSize = 12
hint.TextColor3 = Color3.fromRGB(200,200,200)
hint.Text = "Kosmetisch lokal + optional Server-validated Attack"

-- FX / Animation helpers
local function playAnimation(character, animId)
	if not character or not animId or animId == "" then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = tostring(animId)
	local track = animator:LoadAnimation(anim)
	track:Play()
	track.Stopped:Connect(function() anim:Destroy() end)
end

local function playLocalAttackFX(character)
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
	local head = character:FindFirstChild("Head")
	if root then
		local attach = Instance.new("Attachment", root)
		attach.Position = Vector3.new(0, 0, -1)
		local pe = Instance.new("ParticleEmitter", attach)
		pe.EmissionRate = 0
		pe.Lifetime = NumberRange.new(0.25, 0.6)
		pe.Speed = NumberRange.new(6, 12)
		pe.RotSpeed = NumberRange.new(-180, 180)
		pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0,0.6), NumberSequenceKeypoint.new(1,0)})
		pe.Texture = ATTACK_PARTICLE_TEXTURE
		pe:Emit(20)
		Debris:AddItem(attach, 1.2)
	end
	if head and ATTACK_SOUND_ID and ATTACK_SOUND_ID ~= "" then
		local s = Instance.new("Sound", head)
		s.SoundId = ATTACK_SOUND_ID
		s.Volume = 1
		s:Play()
		Debris:AddItem(s, 4)
	end
end

local function doAttack()
	local now = tick()
	if now - lastAttack < ATTACK_COOLDOWN then return end
	lastAttack = now
	local char = player.Character
	if not char then return end
	if ATTACK_ANIM_ID and ATTACK_ANIM_ID ~= "" then playAnimation(char, ATTACK_ANIM_ID) end
	playLocalAttackFX(char)
	if remote and remote:IsA("RemoteEvent") then
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			remote:FireServer(root.Position, root.CFrame.LookVector)
		else
			remote:FireServer()
		end
	end
end

-- Button Events
btnTransform.MouseButton1Click:Connect(function() applyTransform(player.Character or player.CharacterAdded:Wait()) end)
btnReset.MouseButton1Click:Connect(function() restoreOriginals(player.Character) end)
btnAttack.MouseButton1Click:Connect(function() doAttack() end)

-- Respawn handling
player.CharacterAdded:Connect(function(char)
	waitForChildOfClass(char, "Humanoid", 5)
	if original.walkSpeed then applyTransform(char) end
end)

if player.Character then waitForChildOfClass(player.Character, "Humanoid", 5) end
