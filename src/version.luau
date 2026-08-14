--!nonstrict
--[[
	version.luau — the plugin's own build identity.

	BUILD is the ordered integer the server compares against MIN_PLUGIN_BUILD; it
	must increase monotonically on every release. VERSION is the display string
	shown in Settings and used in support reports. Both ride on every request as
	X-AF-Plugin-Version / X-AF-Plugin-Build.

	Bumping BUILD alone does nothing. The server decides what is too old: raise
	MIN_PLUGIN_BUILD there (server/src/config.ts) to lock older installs out, and
	only do that for changes that genuinely break the wire contract — every locked
	user must go update before they can generate again.
]]

return {
	VERSION = "1.6.0",
	BUILD = 134,
}
