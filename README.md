# Anim Forge

Describe a movement in a sentence and get a real animation on your rig: Anim
Forge is a Roblox Studio plugin that turns "heavy zombie lunge attack" into
keyframes sitting in your place, ready to open in the Animation Editor.

This repository is the plugin. Not a sample of it, not a stripped copy — the
whole client, exactly what is inside the `.rbxm` you download. It is public
because installing a plugin file from the internet is a real thing to ask of
someone, and the only honest answer to "why should I trust this?" is to hand
over every line and invite you to check.

**Plugin 1.6.1 (build 135)** · MIT licensed · [website](https://animforge-production.up.railway.app) · [report a bug](https://github.com/Zidiam/anim-forge-plugin/issues)

## Install

1. Download `AnimForge.rbxm` from [Releases](https://github.com/Zidiam/anim-forge-plugin/releases), or from
   [https://animforge-production.up.railway.app/download](https://animforge-production.up.railway.app/download).
2. Drop it in your local plugins folder:
   - **Windows** — `%LOCALAPPDATA%\Roblox\Plugins`
   - **macOS** — `~/Documents/Roblox/Plugins`
3. Restart Studio. Anim Forge appears in the **Plugins** tab.

Updating is the same three steps, with the new file replacing the old one.
Studio does not auto-update a plugin installed this way — that only happens for
plugins installed from the Creator Store, and this one is not distributed there.

Generation needs HTTP: if the plugin says requests are disabled, turn on
**Game Settings → Security → Allow HTTP Requests** for the place you are in.

## Build it yourself

Nothing here is compiled, minified or packed — the `.rbxm` is these files, as
they are, and [Rojo](https://rojo.space) is what turns one into the other:

```sh
rojo build . -o AnimForge.rbxm
```

Then install the file you just built instead of the one you downloaded. If you
would rather trust your own build than a stranger's binary, that is the
supported path, not a workaround.

Rojo's output is deterministic, so you can go further and check that the
release really is this source — the releases are built with Rojo 7.7.0:

```sh
rojo build . -o mine.rbxm
sha256sum mine.rbxm AnimForge.rbxm      # certutil -hashfile <file> SHA256 on Windows
```

Same source and same Rojo version means the same bytes. If the two differ,
something is wrong and I would like to hear about it.

What you are building:

| file | what it is |
| --- | --- |
| [`src/main.server.luau`](src/main.server.luau) | The whole dock UI — tabs, the composer, History, Settings, the first-run consent card. One long file because it is one widget. |
| [`src/api.luau`](src/api.luau) | Every network call the plugin can make, and the single address it makes them to. |
| [`src/install.luau`](src/install.luau) | Turns returned keyframes into a KeyframeSequence in your place (an AnimSaves folder in ServerStorage, linked from the rig), inside a ChangeHistoryService recording so Ctrl+Z undoes it. |
| [`src/descriptor.luau`](src/descriptor.luau) | Reads the selected rig into the JSON that gets sent: joint names, the exact C0/C1 offsets, part sizes. |
| [`src/settings.luau`](src/settings.luau) | Plugin-local settings and the random install id, stored with plugin:SetSetting — nothing leaves this machine from here. |
| [`src/icons.luau`](src/icons.luau) | Asset ids for the toolbar icons. Generated file. |
| [`src/version.luau`](src/version.luau) | The version and build number this tree is. |

## What leaves your machine, and when

The plugin asks before it does anything. This is what it says on first run,
word for word — [`src/main.server.luau`](src/main.server.luau), the consent
card, and this README is generated from that source so the two cannot drift:

> Anim Forge builds animations on its own server, using a third-party AI service, so generating sends it:
>
> - the description you type,
> - the shape of the character you pick — joint names, sizes and offsets,
> - your Roblox user id, and a random id for this Studio install, so your credits stay yours,
> - the animation you start from, if you pick one — its keyframes go too, so they can be edited.
>
> Nothing else is read from your place — no scripts, no models, no other animations — and your animations stay private to you unless you publish them yourself.
>
> Every animation costs credits. You start with free ones; more are bought in packs, either on the Anim Forge website or with Robux inside the Anim Forge experience on Roblox.
>
> Anim Forge is installed from a file rather than through the Creator Store, so nobody vetted it for you. Its full source is public — read it before you trust it:
> https://github.com/Zidiam/anim-forge-plugin

Generation runs on the project's server because the model that writes the
animation is far too large to run inside Studio. That is the entire reason
anything leaves your machine at all.

### Every request the plugin can make

All of them go to one address, compiled into
[`src/api.luau`](src/api.luau) — `https://animforge-production.up.railway.app`. There is no setting that
changes it and no second host. Each request carries
`X-Roblox-User-Id`, `X-AF-Plugin-Build`, `X-AF-Plugin-Version`, `X-AF-Install`, and nothing else identifying.

| request | in the source | when |
| --- | --- | --- |
| `GET /v1/entitlement` | `api.entitlement` | On opening the window, and after anything that changes your balance. Asks how many credits you have. |
| `POST /v1/account/link/start` | `api.linkStart` | When you move your credits to a new Studio install. Returns a one-time code to put on your Roblox profile. |
| `POST /v1/account/link/confirm` | `api.linkConfirm` | When you press Check afterwards. The server reads your public profile and compares. |
| `POST /v1/redeem` | `api.redeem` | When you paste a credit code into Settings. |
| `POST /v1/generate` | `api.generate` | When you press Generate, or send an edit. This is the one that carries your prompt and your rig. |
| `GET /v1/jobs/{jobId}` | `api.job` | Every couple of seconds while a generation is running, for progress. |
| `POST /v1/jobs/{jobId}/cancel` | `api.cancel` | When you cancel a running generation. |
| `GET /v1/history?limit=50` | `api.history` | When you open the History tab. |
| `GET /v1/lineage/{rootId}` | `api.lineage` | When you expand one animation to see its earlier versions. |
| `POST /v1/jobs/{jobId}/installed` | `api.installed` | After an animation lands in your place, so the server knows the credit was actually delivered. |

## What it does not do

- **No remote code.** No `loadstring`, no `require` by asset id, no
  `InsertService`, no `LinkedSource`. What you read here is all that ever
  runs — the plugin cannot fetch new behaviour later.
- **No telemetry.** No analytics service, no event pings, no crash reporting.
  The requests in the table above are all of them.
- **It does not read your place.** The rig you select is read — joints, part
  sizes, offsets — and nothing else. Not your scripts, not your other models,
  not your other animations.
- **No keys, no secrets, no credentials** anywhere in this tree. There is
  nothing here worth stealing, which is also why publishing it costs nothing.
- **Your animations are yours.** They install into your place and stay private
  to you unless you publish them yourself.

### Check that yourself

```sh
grep -rn "loadstring\|getfenv\|setfenv\|InsertService\|LinkedSource" src/   # remote code
grep -rniE "api[_-]?key|secret|token|password|credential" src/               # anything key-shaped
grep -rn "HttpService" src/                                                  # every network call
grep -rn "RequestAsync" src/                                                 # ...all in api.luau
```

The script that builds this repo runs those same checks and refuses to write a
README whose claims have stopped being true.

## Credits

Generating costs credits — the server does real work per animation. You get
free ones to start. After that a credit is a standard animation (a quick one
costs half, the best setting costs two), edits to an animation you already made
are free for the first few, and credits never expire.

More credits come from two places: packs on [the website](https://animforge-production.up.railway.app), which
give you a code to paste into **Settings → Redeem a code**, or Robux inside the
Anim Forge experience on Roblox, which land on your account automatically. The
plugin itself is free and always will be.

## Bugs, and everything else

Open an issue: https://github.com/Zidiam/anim-forge-plugin/issues. Include the plugin version from the Settings
tab (this tree is 1.6.1, build 135) and what you typed — a prompt that
produced something silly is a useful bug report.

## Licence

MIT — see [LICENSE](LICENSE). The plugin is yours to read, fork and build. The
server it talks to, the animation engine and the reference corpus are not part
of this repository.
