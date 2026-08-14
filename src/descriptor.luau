--!nonstrict
--[[
	descriptor.luau — read a rig Model into the server's RigDescriptor JSON.

	Carries the EXACT c0/c1 (12 CFrame components each) plus part sizes, so the
	server's headless bake runs against identical geometry to this rig. Handles both
	joint generations: classic Motor6D (C0/C1) and modern AnimationConstraint
	(Attachment0/1 CFrames) — same normalisation the engine's readRig uses.
]]

local Descriptor = {}

local function comps(cf)
	return { cf:GetComponents() }
end

--- Classify a rig Model: "R15" | "R6" | "Custom". The server supports R15/R6 in v1;
--- Custom (nonstandard skeletons, creature rigs) is detected and surfaced as
--- unsupported rather than silently misread.
function Descriptor.classify(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		return "Custom"
	end
	local isR6Enum = tostring(hum.RigType):find("R6") ~= nil
	if isR6Enum then
		-- a real R6 has Torso with the classic six parts
		if model:FindFirstChild("Torso") and model:FindFirstChild("Left Arm") then
			return "R6"
		end
		return "Custom"
	end
	-- a real R15 has the LowerTorso/UpperTorso split
	if model:FindFirstChild("LowerTorso") and model:FindFirstChild("UpperTorso") then
		return "R15"
	end
	return "Custom"
end

--- Find candidate rigs: Models under Workspace with a Humanoid and at least one joint.
--- Returns { { model, rigType, supported } } sorted supported-first, then by name.
function Descriptor.findRigs()
	local rigs = {}
	for _, m in ipairs(workspace:GetDescendants()) do
		if m:IsA("Model") then
			local hum = m:FindFirstChildOfClass("Humanoid")
			if hum then
				local hasJoint = false
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("Motor6D") or d:IsA("AnimationConstraint") then
						hasJoint = true
						break
					end
				end
				if hasJoint then
					local rigType = Descriptor.classify(m)
					table.insert(rigs, {
						model = m,
						rigType = rigType,
						supported = rigType == "R15" or rigType == "R6",
					})
				end
			end
		end
	end
	table.sort(rigs, function(a, b)
		if a.supported ~= b.supported then
			return a.supported
		end
		return a.model.Name < b.model.Name
	end)
	return rigs
end

--- Build the descriptor for a rig Model. Returns descriptor, joints-keyed-by-name, or nil+error.
function Descriptor.describe(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil, "no Humanoid"
	end
	local rigType = tostring(hum.RigType):find("R6") and "R6" or "R15"

	local joints = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			table.insert(joints, {
				name = d.Name,
				parent = d.Part0.Name,
				child = d.Part1.Name,
				c0 = comps(d.C0),
				c1 = comps(d.C1),
			})
		elseif d:IsA("AnimationConstraint") and d.Attachment0 and d.Attachment1 then
			local p0, p1 = d.Attachment0.Parent, d.Attachment1.Parent
			if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
				table.insert(joints, {
					name = d.Name,
					parent = p0.Name,
					child = p1.Name,
					c0 = comps(d.Attachment0.CFrame),
					c1 = comps(d.Attachment1.CFrame),
				})
			end
		end
	end
	if #joints == 0 then
		return nil, "no Motor6D or AnimationConstraint joints"
	end

	local parts = {}
	local seen = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and not seen[d.Name] then
			seen[d.Name] = true
			table.insert(parts, { name = d.Name, size = { d.Size.X, d.Size.Y, d.Size.Z } })
		end
	end

	return {
		type = rigType,
		hipHeight = hum.HipHeight,
		joints = joints,
		parts = parts,
	}
end

return Descriptor
