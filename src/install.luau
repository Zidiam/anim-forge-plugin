--!nonstrict
--[[
	install.luau — dense payload → KeyframeSequence → the rig's AnimSaves.

	Ported from the engine's AF.install/AF.bake conventions, which mirror what the
	Animation Clip Editor actually does (verified in the source workspace):

	* The editor keeps animations at ServerStorage.RBX_ANIMSAVES.<rigName>.<clipName>
	  and an ObjectValue named "AnimSaves" inside the rig POINTS at that folder.
	* BOTH halves get a copy, always: the ServerStorage folder is what the editor's
	  Load list reads; the ObjectValue's CHILDREN are the only copy a client script can
	  reach at runtime (ServerStorage does not replicate). One half is a silent bug.
	* Existing clips by OTHER names are left alone (a user's own saved animations must
	  survive); same-named clips are replaced.
	* Every Pose is named for the CHILD PART it drives; the tree mirrors the part
	  hierarchy rooted at a "HumanoidRootPart" Pose. Joints absent from the payload
	  get identity Poses — a joint with no Pose is a partial track that blends
	  unpredictably against whatever else is playing.
	* Poses are Linear/In: the dense bake already carries all shaping; linear segments
	  between dense frames are what the engine previewed.
	* The final keyframe is named "End" (the convention every shipped Roblox animation
	  uses); marker frames carry their marker name and fire KeyframeReached.

	Payload (PLAN §5): { name, fps, frameCount, duration, loop, priority, hipHeight,
	  rigType, markers?: {frameIndex: name}, joints: {jointName: {angles: [[x,y,z]..],
	  offsets: [[px,py,pz]..]|nil}} }  — angles are plain-XYZ euler DEGREES (the server
	  normalises hip composition before shipping).
]]

local Install = {}

--[[
	Undo support. Every mutation this module makes to the user's place is wrapped
	in a ChangeHistoryService recording, so Ctrl+Z behaves the way it does for any
	other Studio edit. A plugin that writes instances outside the undo stack
	leaves the user unable to back out of a change they didn't want — and it
	desyncs the stack for everything else they do afterwards.

	TryBeginRecording returns nil when a recording is already open (nested calls,
	or another plugin mid-edit); in that case we still run the operation, just
	without owning a waypoint.
]]
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local function recorded(name, displayName, fn)
	local id = nil
	pcall(function()
		id = ChangeHistoryService:TryBeginRecording(name, displayName)
	end)
	local ok, a, b = pcall(fn)
	if id then
		pcall(function()
			ChangeHistoryService:FinishRecording(
				id,
				ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
			)
		end)
	end
	if not ok then
		return nil, tostring(a)
	end
	return a, b
end
Install.recorded = recorded

local function jointGraph(model)
	-- child part name -> { jointName, parentPartName }, both joint generations
	local joints = {}
	local byParent = {}
	for _, d in ipairs(model:GetDescendants()) do
		local parentPart, childPart, jointName
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			parentPart, childPart, jointName = d.Part0, d.Part1, d.Name
		elseif d:IsA("AnimationConstraint") and d.Attachment0 and d.Attachment1 then
			local p0, p1 = d.Attachment0.Parent, d.Attachment1.Parent
			if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
				parentPart, childPart, jointName = p0, p1, d.Name
			end
		end
		if parentPart and childPart then
			joints[childPart.Name] = { jointName = jointName, parentName = parentPart.Name }
			byParent[parentPart.Name] = byParent[parentPart.Name] or {}
			table.insert(byParent[parentPart.Name], childPart.Name)
		end
	end
	-- root: drives a joint, driven by none; prefer HumanoidRootPart
	local isChild = {}
	for childName in pairs(joints) do
		isChild[childName] = true
	end
	local rootName
	for parentName in pairs(byParent) do
		if not isChild[parentName] then
			if parentName == "HumanoidRootPart" then
				rootName = parentName
				break
			end
			rootName = rootName or parentName
		end
	end
	return joints, byParent, rootName
end

local function poseCFrame(joints, payloadJoints, childName, frame)
	local info = joints[childName]
	if not info then
		return CFrame.new()
	end
	-- payload keys by JOINT name on R15 and by CHILD PART name on R6; accept either
	local track = payloadJoints[info.jointName] or payloadJoints[childName]
	if not track then
		return CFrame.new()
	end
	local a = track.angles and track.angles[frame]
	local o = track.offsets and track.offsets[frame]
	local cf = CFrame.new()
	if o then
		cf = CFrame.new(o[1], o[2], o[3])
	end
	if a then
		cf = cf * CFrame.Angles(math.rad(a[1]), math.rad(a[2]), math.rad(a[3]))
	end
	return cf
end

--- Build the KeyframeSequence from a dense payload against a rig Model.
function Install.buildSequence(model, payload)
	local joints, byParent, rootName = jointGraph(model)
	if not rootName then
		return nil, "rig has no joint graph"
	end

	local kfs = Instance.new("KeyframeSequence")
	kfs.Name = payload.name
	kfs.Loop = payload.loop and true or false
	local prio = Enum.AnimationPriority.Action
	pcall(function()
		prio = Enum.AnimationPriority[payload.priority]
	end)
	kfs.Priority = prio
	kfs.AuthoredHipHeight = payload.hipHeight or 2

	local n = payload.frameCount
	local fps = payload.fps
	local markers = payload.markers or {}

	local function buildPose(partName, frame)
		local p = Instance.new("Pose")
		p.Name = partName
		p.Weight = 1
		p.EasingStyle = Enum.PoseEasingStyle.Linear
		p.EasingDirection = Enum.PoseEasingDirection.In
		if partName == rootName then
			p.CFrame = CFrame.new()
		else
			p.CFrame = poseCFrame(joints, payload.joints, partName, frame)
		end
		for _, childName in ipairs(byParent[partName] or {}) do
			buildPose(childName, frame).Parent = p
		end
		return p
	end

	for i = 0, n - 1 do
		local t = math.min(i / fps, payload.duration)
		local kf = Instance.new("Keyframe")
		kf.Name = markers[tostring(i)] or (i == n - 1 and "End" or "Keyframe")
		kf.Time = t
		buildPose(rootName, i + 1).Parent = kf
		kf.Parent = kfs
	end
	return kfs
end

--- The two AnimSaves halves for a rig: the ServerStorage folder (what the editor's
--- Load list reads) and the ObjectValue link inside the rig (runtime copy). Returns
--- (rigFolder, link); creates them when `create` is true.
function Install.halves(model, create)
	local ServerStorage = game:GetService("ServerStorage")
	local root = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	if not root and create then
		root = Instance.new("Folder")
		root.Name = "RBX_ANIMSAVES"
		root.Parent = ServerStorage
	end
	local link = model:FindFirstChild("AnimSaves")

	-- Follow the rig's OWN link before falling back to a name lookup. The folder
	-- is named after the model, so renaming the rig would otherwise strand the
	-- existing animations in the old folder while a fresh empty one is created —
	-- the editor's Load list and the runtime copy would then disagree.
	local rigFolder
	if link and link:IsA("ObjectValue") and link.Value and link.Value.Parent == root then
		rigFolder = link.Value
		if create and rigFolder.Name ~= model.Name and not root:FindFirstChild(model.Name) then
			rigFolder.Name = model.Name -- keep it discoverable under the current name
		end
	end
	rigFolder = rigFolder or (root and root:FindFirstChild(model.Name))
	if not rigFolder and create then
		rigFolder = Instance.new("Folder")
		rigFolder.Name = model.Name
		rigFolder.Parent = root
	end

	if link and not link:IsA("ObjectValue") then
		if not create then
			return rigFolder, link -- legacy Folder container: still enumerable
		end
		-- A user's own AnimSaves Folder is THEIR data. Migrate every child across
		-- — not just KeyframeSequences — and keep the folder itself, renamed,
		-- rather than destroying it. Losing a creator's hand-authored animations
		-- on first install is unrecoverable and unforgivable.
		local legacy = link
		link = nil
		local movedAll = true
		for _, c in ipairs(legacy:GetChildren()) do
			if c:IsA("KeyframeSequence") and rigFolder and not rigFolder:FindFirstChild(c.Name) then
				c:Clone().Parent = rigFolder
			elseif not c:IsA("KeyframeSequence") then
				movedAll = false -- something we don't understand: never drop it
			end
		end
		if movedAll then
			legacy:Destroy()
		else
			-- park it beside the new link so nothing is lost and the name is free
			legacy.Name = "AnimSaves_Backup"
		end
	end
	if not link and create then
		link = Instance.new("ObjectValue")
		link.Name = "AnimSaves"
		link.Parent = model
	end
	if link and link:IsA("ObjectValue") and rigFolder then
		link.Value = rigFolder
	end
	return rigFolder, link
end

--- Install into AnimSaves, both halves. Replaces a same-named clip, preserves others.
--- meta (optional): { jobId, prompt, clip } — the sparse clip is embedded in the
--- KeyframeSequence as a StringValue so the Edit tab can run AI refinements later.
function Install.install(model, payload, meta)
	local kfs, err = Install.buildSequence(model, payload)
	if not kfs then
		return nil, err
	end
	return recorded("AnimForgeInstall", ('Install "%s"'):format(tostring(payload.name)), function()
		return Install._install(model, kfs, meta)
	end)
end

function Install._install(model, kfs, meta)

	-- Only the job id is embedded. This StringValue lives inside the rig, so it
	-- replicates to clients and ships inside any place the user publishes —
	-- stamping their raw prompt and the full sparse clip into it would publish
	-- private content they never chose to share. The recipe stays server-side and
	-- the Edit tab fetches it by id when a refine is actually requested.
	if meta and meta.jobId then
		local HttpService = game:GetService("HttpService")
		local tag = Instance.new("StringValue")
		tag.Name = "AnimForgeMeta"
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, { jobId = meta.jobId })
		if ok then
			tag.Value = encoded
			tag.Parent = kfs
		end
	end

	local rigFolder, link = Install.halves(model, true)

	local old = rigFolder:FindFirstChild(kfs.Name)
	if old then
		old:Destroy()
	end
	kfs.Parent = rigFolder

	local runtimeOld = link:FindFirstChild(kfs.Name)
	if runtimeOld then
		runtimeOld:Destroy()
	end
	kfs:Clone().Parent = link

	return kfs
end

---------------------------------------------------------------- edit operations
-- All edits apply to BOTH halves (one half drifting is a silent bug — the editor
-- shows one thing, runtime plays another). The ServerStorage copy is canonical.

--- List a rig's saved animations: { {name, kfs, meta?} } sorted by name.
--- kfs is the canonical (ServerStorage) copy when present.
function Install.listAnimations(model)
	local HttpService = game:GetService("HttpService")
	local rigFolder, link = Install.halves(model, false)
	local byName = {}
	local function scan(container, canonical)
		if not container then
			return
		end
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("KeyframeSequence") then
				if canonical or not byName[c.Name] then
					byName[c.Name] = c
				end
			end
		end
	end
	scan(link, false)
	scan(rigFolder, true)

	local out = {}
	for name, kfs in pairs(byName) do
		local meta
		local tag = kfs:FindFirstChild("AnimForgeMeta")
		if tag and tag:IsA("StringValue") and tag.Value ~= "" then
			pcall(function()
				meta = HttpService:JSONDecode(tag.Value)
			end)
		end
		table.insert(out, { name = name, kfs = kfs, meta = meta })
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- Run fn on every copy of the named animation (both halves). Returns count touched.
local function eachCopy(model, name, fn)
	local rigFolder, link = Install.halves(model, false)
	local touched = 0
	for _, container in ipairs({ rigFolder, link }) do
		if container then
			local kfs = container:FindFirstChild(name)
			if kfs and kfs:IsA("KeyframeSequence") then
				fn(kfs)
				touched += 1
			end
		end
	end
	return touched
end

function Install.durationOf(kfs)
	local d = 0
	for _, kf in ipairs(kfs:GetChildren()) do
		if kf:IsA("Keyframe") and kf.Time > d then
			d = kf.Time
		end
	end
	return d
end

function Install.setLoop(model, name, loop)
	return recorded("AnimForgeLoop", "Set animation loop", function()
		return eachCopy(model, name, function(kfs)
			kfs.Loop = loop
		end) > 0
	end)
end

function Install.setPriority(model, name, priorityName)
	local prio = Enum.AnimationPriority[priorityName]
	if not prio then
		return false
	end
	return recorded("AnimForgePriority", "Set animation priority", function()
		return eachCopy(model, name, function(kfs)
			kfs.Priority = prio
		end) > 0
	end)
end

--- factor > 1 = faster (times shrink), factor < 1 = slower. Applied once per call.
function Install.retime(model, name, factor)
	if factor <= 0 then
		return false, "speed must be positive"
	end
	local touched = recorded("AnimForgeRetime", "Retime animation", function()
		return eachCopy(model, name, function(kfs)
			for _, kf in ipairs(kfs:GetChildren()) do
				if kf:IsA("Keyframe") then
					kf.Time = kf.Time / factor
				end
			end
		end)
	end)
	-- report what actually happened: silently claiming success when nothing was
	-- found sends the user back to an unchanged animation with a green checkmark
	if not touched or touched == 0 then
		return false, "animation not found on this rig"
	end
	return true
end

function Install.rename(model, oldName, newName)
	if newName == "" or newName == oldName then
		return false, "pick a different name"
	end
	local rigFolder, link = Install.halves(model, false)
	for _, container in ipairs({ rigFolder, link }) do
		if container and container:FindFirstChild(newName) then
			return false, ('an animation named "%s" already exists'):format(newName)
		end
	end
	local n = eachCopy(model, oldName, function(kfs)
		kfs.Name = newName
	end)
	return n > 0, n == 0 and "animation not found" or nil
end

function Install.duplicate(model, name)
	local rigFolder, link = Install.halves(model, false)
	local source = (rigFolder and rigFolder:FindFirstChild(name))
		or (link and link:FindFirstChild(name))
	if not source or not source:IsA("KeyframeSequence") then
		return nil, "animation not found"
	end
	local copyName = name .. " copy"
	local i = 2
	while
		(rigFolder and rigFolder:FindFirstChild(copyName))
		or (link and link:FindFirstChild(copyName))
	do
		copyName = ("%s copy %d"):format(name, i)
		i += 1
	end
	for _, container in ipairs({ rigFolder, link }) do
		if container then
			local c = source:Clone()
			c.Name = copyName
			c.Parent = container
		end
	end
	return copyName
end

function Install.delete(model, name)
	return recorded("AnimForgeDelete", ('Delete "%s"'):format(tostring(name)), function()
		return eachCopy(model, name, function(kfs)
			kfs:Destroy()
		end) > 0
	end)
end

---------------------------------------------------------------- clip extraction
--- Rebuild a sparse clip from an installed KeyframeSequence so ANY animation —
--- not just ones Anim Forge generated — can be AI-refined. Samples ≤14 evenly
--- spaced keyframes per track and drops identity tracks. rigType "R15" keys
--- tracks by joint name, "R6" by child part name (the server's clip contract).
function Install.extractClip(model, kfs, rigType)
	local r2 = function(x)
		return math.floor(x * 100 + 0.5) / 100
	end
	local r3 = function(x)
		return math.floor(x * 1000 + 0.5) / 1000
	end

	local joints = {} -- child part name -> joint name
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			joints[d.Part1.Name] = d.Name
		elseif d:IsA("AnimationConstraint") and d.Attachment0 and d.Attachment1 then
			local p0, p1 = d.Attachment0.Parent, d.Attachment1.Parent
			if p0 and p1 then
				joints[p1.Name] = d.Name
			end
		end
	end

	local frames = {}
	for _, kf in ipairs(kfs:GetChildren()) do
		if kf:IsA("Keyframe") then
			table.insert(frames, kf)
		end
	end
	table.sort(frames, function(a, b)
		return a.Time < b.Time
	end)
	if #frames == 0 then
		return nil, "animation has no keyframes"
	end
	local duration = frames[#frames].Time
	if duration <= 0 then
		return nil, "animation has no duration"
	end

	local MAXK = 14
	local picked = {}
	if #frames <= MAXK then
		picked = frames
	else
		local seen = {}
		for i = 1, MAXK do
			local idx = math.floor((i - 1) * (#frames - 1) / (MAXK - 1) + 0.5) + 1
			if not seen[idx] then
				seen[idx] = true
				table.insert(picked, frames[idx])
			end
		end
	end

	local byTrack = {} -- track key -> { keys }
	local function visit(pose, t)
		local jointName = joints[pose.Name]
		if jointName then
			local trackKey = rigType == "R6" and pose.Name or jointName
			local cf = pose.CFrame
			local rx, ry, rz = cf:ToEulerAnglesXYZ()
			local p = cf.Position
			byTrack[trackKey] = byTrack[trackKey] or {}
			table.insert(byTrack[trackKey], {
				t = r3(t),
				v = { r2(math.deg(rx)), r2(math.deg(ry)), r2(math.deg(rz)), r3(p.X), r3(p.Y), r3(p.Z) },
			})
		end
		for _, child in ipairs(pose:GetChildren()) do
			if child:IsA("Pose") then
				visit(child, t)
			end
		end
	end
	for _, kf in ipairs(picked) do
		for _, root in ipairs(kf:GetChildren()) do
			if root:IsA("Pose") then
				visit(root, kf.Time)
			end
		end
	end

	local tracks = {}
	for trackKey, keys in pairs(byTrack) do
		local moves = false
		for _, k in ipairs(keys) do
			for i = 1, 3 do
				if math.abs(k.v[i]) > 0.25 then
					moves = true
				end
			end
			for i = 4, 6 do
				if math.abs(k.v[i]) > 0.005 then
					moves = true
				end
			end
		end
		if moves then
			table.insert(tracks, { joint = trackKey, keys = keys })
		end
	end
	table.sort(tracks, function(a, b)
		return a.joint < b.joint
	end)
	if #tracks == 0 then
		return nil, "animation doesn't move any joints"
	end

	return {
		name = kfs.Name,
		fps = 30,
		duration = r3(duration),
		loop = kfs.Loop and true or false,
		priority = tostring(kfs.Priority.Name),
		tracks = tracks,
	}
end

---------------------------------------------------------------- live preview
--[[
	Play a dense payload on the rig live, in Edit mode, WITHOUT installing anything.

	This is exactly how the Animation Clip Editor previews: the dense frames become a
	KeyframeSequence (the same one Install would bake), which is registered LOCALLY —
	no upload, no asset id — via KeyframeSequenceProvider, loaded onto the rig's own
	Animator, and advanced each frame with Animator:StepAnimations (Edit mode does not
	step animators on its own). Nothing is saved to the place and no undo waypoint is
	created; stopping returns the rig to rest. Verified in Studio: setting Motor6D
	.Transform directly does NOT move a rig in Edit mode, but this path does.

	If the rig has no Animator we add a transient one and remove it on stop.

	Returns a controller { play, stop, onFinished } or (nil, reason).
]]
function Install.makePreview(model, payload)
	if not model or not payload then
		return nil, "no animation data to preview"
	end
	local kfs, berr = Install.buildSequence(model, payload)
	if not kfs then
		return nil, berr or "could not build the animation"
	end
	kfs.Loop = payload.loop and true or false

	local controller = model:FindFirstChildOfClass("Humanoid")
		or model:FindFirstChildOfClass("AnimationController")
	if not controller then
		return nil, "this rig has no Humanoid or AnimationController to play on"
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	local createdAnimator = false
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
		createdAnimator = true
	end

	local KSP = game:GetService("KeyframeSequenceProvider")
	local RunService = game:GetService("RunService")
	local okReg, animId = pcall(function()
		return KSP:RegisterKeyframeSequence(kfs)
	end)
	if not okReg or not animId then
		if createdAnimator and animator.Parent then
			animator:Destroy()
		end
		return nil, "could not register the preview animation"
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId

	local ctrl = { onFinished = nil }
	local track, conn, stoppedConn = nil, nil, nil

	function ctrl.stop()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if stoppedConn then
			stoppedConn:Disconnect()
			stoppedConn = nil
		end
		if track then
			pcall(function()
				track:Stop(0)
			end)
			track = nil
		end
		-- Stopping the track alone leaves the last frame applied in Edit mode;
		-- clearing every joint's Transform returns the rig cleanly to rest (verified
		-- in Studio — this reset takes effect, a bare Stop does not).
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Motor6D") or d:IsA("AnimationConstraint") then
				pcall(function()
					d.Transform = CFrame.identity
				end)
			end
		end
		pcall(function()
			animator:StepAnimations(0)
		end)
		if createdAnimator and animator and animator.Parent then
			animator:Destroy()
			createdAnimator = false
		end
	end

	function ctrl.play()
		if track then
			return
		end
		local ok2, t = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if not ok2 or not t then
			return
		end
		track = t
		track.Looped = kfs.Loop
		if not kfs.Loop then
			stoppedConn = track.Stopped:Connect(function()
				local cb = ctrl.onFinished
				ctrl.stop()
				if cb then
					pcall(cb)
				end
			end)
		end
		track:Play(0.1)
		-- Edit mode doesn't advance animators; drive it ourselves every frame.
		conn = RunService.Heartbeat:Connect(function(dt)
			pcall(function()
				animator:StepAnimations(dt)
			end)
		end)
	end

	return ctrl
end

return Install
