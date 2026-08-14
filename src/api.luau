--!nonstrict
-- api.luau — HTTP client for the Anim Forge server (PLAN §3 contract).
-- Auth header: X-Roblox-User-Id, plus the install id. Every request also carries
-- the plugin build so the server can lock out installs that are too old to speak
-- the current contract (see version.luau).
--
-- The address is compiled in and cannot be changed from the UI. It used to be a
-- Settings field, which meant anyone could point the plugin at their own server
-- and generate for free: the entitlement check, the credit spend and the
-- metering all live on our side of this connection.

local HttpService = game:GetService("HttpService")
local StudioService = game:GetService("StudioService")

local Version = require(script.Parent.version)

local Api = {}

--- The one server this plugin talks to. Change it here and rebuild for local
--- development; it is deliberately not reachable from the running plugin.
local SERVER_URL = "https://animforge-production.up.railway.app"

function Api.new(settings)
	local self = {}

	-- Set from the last response that carried client-compat info. The UI reads this
	-- to decide whether to lock itself; the server enforces the same thing.
	self.updateRequired = false
	self.latestVersion = nil

	local function headers()
		local h = {
			["Content-Type"] = "application/json",
			["X-Roblox-User-Id"] = tostring(StudioService:GetUserId()),
			["X-AF-Plugin-Build"] = tostring(Version.BUILD),
			["X-AF-Plugin-Version"] = Version.VERSION,
			-- proves a generation belongs to THIS install (see settings.installId)
			["X-AF-Install"] = settings.installId(),
		}
		return h
	end

	local function request(method, path, body)
		local ok, res = pcall(function()
			return HttpService:RequestAsync({
				Url = SERVER_URL .. path,
				Method = method,
				Headers = headers(),
				Body = body and HttpService:JSONEncode(body) or nil,
			})
		end)
		if not ok then
			return nil,
				"HTTP request failed: "
					.. tostring(res)
					.. " (is the server running, and is HTTP enabled for this place?)"
		end
		local decoded
		local okJson = pcall(function()
			decoded = HttpService:JSONDecode(res.Body)
		end)
		if not okJson or type(decoded) ~= "table" then
			return nil, ("server returned %d: %s"):format(res.StatusCode, string.sub(res.Body or "", 1, 120))
		end
		-- the server tells every response whether this build is still supported
		if decoded.client ~= nil and type(decoded.client) == "table" then
			self.updateRequired = decoded.client.updateRequired == true
			self.latestVersion = decoded.client.latestVersion
		end
		if res.StatusCode == 426 or decoded.error == "UPDATE_REQUIRED" then
			self.updateRequired = true
			return nil, tostring(decoded.message or "This version of Anim Forge is out of date."), decoded
		end
		if res.StatusCode >= 400 then
			return nil, decoded.message or decoded.error or ("HTTP " .. res.StatusCode), decoded
		end
		return decoded
	end

	function self.entitlement()
		return request("GET", "/v1/entitlement")
	end

	--- Prove this Studio install belongs to the Roblox account it claims, by
	--- putting a one-time code on that account's own profile. Needed after a
	--- reinstall, because spending an account's credits is bound to the install
	--- that first proved itself.
	function self.linkStart()
		return request("POST", "/v1/account/link/start", {})
	end

	--- Ask the server to read the profile and check for the code. Takes no code
	--- from us on purpose: the server compares Roblox's answer against what it
	--- stored, so nothing the client says enters the decision.
	function self.linkConfirm()
		return request("POST", "/v1/account/link/confirm", {})
	end

	--- Turn a credit code into credits on this account. The code is the only thing
	--- sent: it carries no identity of its own, so the account that redeems it is
	--- whichever account these headers name. The server decides whether a code is
	--- real and grants it exactly once, even if two clients race the same code —
	--- nothing here may assume a second attempt is safe.
	function self.redeem(code)
		return request("POST", "/v1/redeem", { code = code })
	end

	function self.generate(prompt, rig, model, previousClip, critique, parentJobId)
		return request("POST", "/v1/generate", {
			prompt = prompt,
			rig = rig,
			model = model,
			previousClip = previousClip,
			critique = critique,
			parentJobId = parentJobId,
		})
	end

	function self.job(jobId)
		return request("GET", "/v1/jobs/" .. HttpService:UrlEncode(tostring(jobId)))
	end

	function self.cancel(jobId)
		return request("POST", "/v1/jobs/" .. HttpService:UrlEncode(tostring(jobId)) .. "/cancel")
	end

	function self.history()
		return request("GET", "/v1/history?limit=50")
	end

	--- Every saved version of one animation (the History version picker).
	function self.lineage(rootId)
		return request("GET", "/v1/lineage/" .. HttpService:UrlEncode(tostring(rootId)))
	end

	function self.installed(jobId)
		return request("POST", "/v1/jobs/" .. HttpService:UrlEncode(tostring(jobId)) .. "/installed")
	end

	return self
end

return Api
