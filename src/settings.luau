--!nonstrict
-- settings.luau — plugin-scoped persistent settings.
--
-- Deliberately holds NO server address, NO provider key and NO staff key.
-- Generation runs on the Anim Forge server and nowhere else: a settable server
-- URL would let anyone point the plugin at their own backend, and a personal
-- provider key would let them generate without spending credits. Either one is
-- the credit system, bypassed. Operator tooling is a separate local program.
--
-- This file ships inside the published .rbxm and is readable by anyone who
-- downloads the plugin, so it must not name the AI provider or any model. Sizes
-- are stored as small/mid/max and nothing here maps those to anything more
-- specific — the server owns that translation.

local Settings = {}

local DEFAULTS = {
	model = "mid", -- "small" | "mid" | "max"
	installId = "", -- minted on first run; see installId() below
	acceptedTerms = false, -- first-run data-use disclosure has been shown and accepted
}

-- Must list every size main.server.luau offers. While this still said
-- standard/ultra the getter rejected every stored value, so the size picker
-- silently reset to the default on each reload and no choice ever stuck.
local VALID_MODEL = { small = true, mid = true, max = true }

local HttpService = game:GetService("HttpService")

function Settings.new(plugin)
	local self = { plugin = plugin }
	function self.get(key)
		local ok, v = pcall(function()
			return plugin:GetSetting("animforge_" .. key)
		end)
		if not ok or v == nil or v == "" then
			return DEFAULTS[key]
		end
		-- anything not in the current vocabulary (including values written by
		-- older builds) falls back to the default rather than being translated
		if key == "model" and not VALID_MODEL[v] then
			return DEFAULTS.model
		end
		return v
	end
	function self.set(key, value)
		pcall(function()
			plugin:SetSetting("animforge_" .. key, value)
		end)
	end

	--[[
		A random id for THIS Studio install, minted once and kept forever.

		The server has no way to authenticate a plugin — X-Roblox-User-Id is a
		header anyone can type, and Roblox user ids are public — so this is what
		makes "your generations are yours" mean anything: a finished animation is
		released to the install that asked for it, not to whoever claims to be its
		owner. It identifies an install, never a person, and is not a credential
		the user picks or needs to know about.
	]]
	function self.installId()
		local id = self.get("installId")
		if type(id) ~= "string" or #id < 16 then
			id = HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false)
			self.set("installId", id)
		end
		return id
	end

	return self
end

return Settings
