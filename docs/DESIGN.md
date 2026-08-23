# Design — Signal-Triggered Discord Voice Ducking on PipeWire

**Host:** workstation (CachyOS) · **Author:** K-Sugar · **Date:** 2026-08-23
**Supersedes:** `~/Downloads/discord-ducking-plan.md` (kept as the source brief; where the two
disagree, this document wins — see §3 for every deviation and why).

---

## 1. Objective and success criteria

Reproduce Discord's "Attenuation (when others speak)" — shipped on Windows and macOS, absent on
Linux — at the audio-server level. When audio is present on Discord's playback stream, all other
application audio is attenuated in real time; when Discord is silent, it returns to full volume.

**Signal-triggered, not call-state-triggered.** Ducking that persists for the whole call duration
is an explicit non-goal and constitutes a failed implementation.

1. Someone speaks in a Discord call -> other audio drops by a configurable amount within ~10 ms,
   and recovers within ~500 ms of them stopping.
2. Discord's own audio is never attenuated by its own signal. No self-ducking, no feedback loop.
3. Added latency on the Discord voice path is under ~40 ms.
4. Configuration survives reboot and PipeWire/WirePlumber restarts with no manual steps.
5. **Configuration survives switching output devices**, which the source brief did not require.
   See §3.1 — on this machine this is the dominant constraint.
6. A single documented command tears the whole thing down and restores stock behaviour.

---

## 2. Verified environment

Every value below was observed on 2026-08-23, not assumed.

| Item | Value |
|---|---|
| PipeWire | 1.6.8 |
| WirePlumber | 0.5.15 |
| pipewire-pulse | 1:1.6.8-1 (`Server Name: PulseAudio (on PipeWire 1.6.8)`) |
| Discord | native pacman `discord 1:1.0.152-1`, running self-updated `app-1.0.154`. **Not Flatpak.** |
| Discord playback node | `media.class=Stream/Output/Audio`, `node.name="WEBRTC VoiceEngine"`, `application.name="WEBRTC VoiceEngine"`, `application.process.binary="Discord"`, `media.name="playStream"` |
| Discord capture node | identical `node.name`/`application.name`, `media.class=Stream/Input/Audio` |
| Discord client API | `client.api = pipewire-pulse` |
| Default sink at survey time | `bluez_output.XX_XX_XX_XX_XX_XX.1` (AirPods, A2DP) |
| Other sinks | USB Audio SPDIF / Speakers / Front Headphones, AD102 HDMI |
| Default source | `alsa_input.usb-USB_Mic_...` — a **separate USB mic**, not the AirPods |
| Installed | `pavucontrol 1:6.2-1.1`, `qpwgraph 1.0.3-1.1` |
| Installed 2026-08-23 (step 6.1) | `easyeffects 8.2.8-1.1` (Qt6/QML), `lsp-plugins-lv2 1.2.33-2.1` |
| LSP LV2 layout | single bundle `/usr/lib/lv2/lsp-plugins.lv2/`, contains `sc_compressor` — needed for the §9 filter-chain port, not for the EasyEffects path (its compressor is built in) |
| `~/.config/pipewire/` | **does not exist** — will be created |
| `~/.config/wireplumber/wireplumber.conf.d/` | contains only `00-plasma-pa.conf`, which is plasma-pa-generated. **Do not edit.** |
| Live at survey time | `discord_capture` nodes pulling Zen + spotifyd audio (screen-share with audio) |

### 2.1 Answered open questions

| Source brief §15 question | Answer |
|---|---|
| Discord flavour? | Native package. |
| Hardware sink stable? | **No — the user switches output devices regularly.** Dominant design constraint. |
| Discord volume independently adjustable? | No. Unity-gain pass-through. Trivially reversible later. |
| EasyEffects-first or filter-chain directly? | EasyEffects first. See §3.4. |

---

## 3. Deviations from the source brief

The brief was written before the machine was surveyed. Several of its assumptions do not hold here.

### 3.1 There is no stable hardware sink — no device name may be hardcoded

The brief hardcodes `<HW_SINK_NAME>` in the Phase 2 loopback and implicitly again in the
EasyEffects output leg. This machine has five sinks and the user switches between them routinely.
Worse, the Bluetooth node name embeds the **profile index** (`bluez_output.<MAC>.**1**`), so it is
not stable even for a single device across a profile change.

**Resolution:** no configuration file names a device anywhere. Both output legs are ordinary
streams that WirePlumber routes to the current default sink and *re-routes automatically* when the
default changes. This is achieved by **omitting** `target.object` on the loopback's `playback.props`
rather than setting it.

### 3.2 `node.dont-reconnect = true` must be removed

The brief sets this on the loopback playback leg. With a Bluetooth target it is actively harmful:
one AirPods disconnect kills Discord audio permanently and silently until a full PipeWire restart.
It is also incompatible with §3.1. **Omitted.**

### 3.3 The brief's WirePlumber routing key would have silently done nothing

The brief's Approach A proposes a WirePlumber rule and correctly warns against guessing the key.
Investigation of the shipped scripts settles it: the only stream-facing rules section in
WirePlumber 0.5.15 is `stream.rules`, consumed by `scripts/node/state-stream.lua`. That script
passes the rules through `JsonUtils.match_rules_update_properties` into a **local copy** of the
properties used solely for state-key forming and the `state.restore-*` flags. It never pushes
properties back onto the node. `stream.rules` is therefore **not a routing mechanism** and setting
`target.object` there would have failed exactly as the brief feared.

**Resolution:** routing is done in Discord itself (§4.3), with a PipeWire-side `pulse.rules`
drop-in as the fallback — valid here because Discord is confirmed `client.api = pipewire-pulse`.

### 3.4 Approach B (pavucontrol + saved state) is rejected outright

WirePlumber 0.5.15 keys saved stream state on `application.name`, which for Discord is
`"WEBRTC VoiceEngine"` — libwebrtc's generic name, **not Discord-specific**. Signal is installed and
running (`signal-desktop`, clients `ringrtc` and `Signal`) and plausibly presents the same
`application.name` during a call. Approach B would therefore risk dragging Signal call audio into
`DiscordSink` too. The in-app selector and binary-matched rules both avoid this. Approach B is not
used.

### 3.5 The brief's rollback is wrong and destructive

The brief's rollback runs `rm -f ~/.local/state/wireplumber/restore-stream`. That path **does not
exist** in WirePlumber 0.5.15 — the file is `stream-properties`. Deleting it would wipe the saved
volume, mute state, channel map and routing for **every application on the system**, not just
Discord. Rollback here is surgical and never touches that file (§8).

### 3.6 The exclusion list is incomplete in a way that breaks the whole design

The brief requires excluding Discord from EasyEffects. Necessary but not sufficient: the loopback's
playback leg is itself a `Stream/Output/Audio` node, so "process all output streams" will pull it
onto `easyeffects_sink` and create precisely the self-ducking feedback path this design exists to
prevent. It is given a distinctive `application.name` (`DiscordDirectOut`) purely so it can be
excluded. **Hard requirement, same tier as excluding Discord.**

---

### 3.7 EasyEffects' blocklist matches `node.name`, NOT `application.name`

**Discovered empirically 2026-08-23 during step 6.6; cost several debug cycles and is the single
most important correction in this document.**

§3.6 correctly identified that `discord_direct_playback` must be excluded, but prescribed excluding
it by the `application.name` (`DiscordDirectOut`) that §4.2 deliberately sets. **That does not
work.** With `DiscordDirectOut` in the blocklist the loopback was still captured onto
`easyeffects_sink`, putting Discord's own audio through the compressor its own signal drives —
live self-ducking, exactly the §3.6 failure.

Bisected by testing one candidate string at a time against the same node:

| Blocklist entry | Property it corresponds to | Result |
|---|---|---|
| `DiscordDirectOut` | `application.name` | **captured — no match** |
| `Discord Direct Out` | `node.description` | **captured — no match** |
| `Discord Direct Out output` | `media.name` | **captured — no match** |
| `discord_direct_playback` | **`node.name`** | **excluded — match** |

The rule is `node.name`. This stayed hidden for ordinary applications because pulse clients
generally have identical `node.name` and `application.name` — Zen is `Zen` either way, Discord is
`WEBRTC VoiceEngine` either way. The distinction only surfaces on a **native PipeWire node**, where
the two differ. A control test confirmed the mechanism itself was working the whole time: adding
`Zen` to the blocklist correctly kept Zen on the hardware sink.

**Consequence for §4.2:** the `application.name = "DiscordDirectOut"` property is retained because
it makes the node identifiable in `pavucontrol` and `pactl`, but it is **decorative, not
functional**. The blocklist entry that does the work is `discord_direct_playback`. Anyone renaming
`node.name` in `20-discord-loopback.conf` must change the blocklist to match or self-ducking
returns silently.

### 3.8 Verified working topology (2026-08-23)

```
DiscordSink:monitor ─┬─> discord_direct_capture ──> <default sink>   (Discord, never ducked)
                     └─> ee_soe_compressor:probe                     (sidechain trigger)
easyeffects_sink:monitor ─> ee_soe_compressor:input ─> <default sink> (everything else, ducked)
```

Observed stream placement with everything running under `systemd --user`:

| Stream (`application.name`) | Sink | Correct? |
|---|---|---|
| `WEBRTC VoiceEngine` (Discord playback) | `DiscordSink` | yes |
| `DiscordDirectOut` (loopback out) | hardware sink | yes — bypasses compressor |
| `Zen` | `easyeffects_sink` | yes — gets ducked |
| `PipeWire ALSA [spotifyd]` | `easyeffects_sink` | yes — gets ducked |

### 3.9 The brief's -30 dB threshold never triggers on this system

**Root-caused 2026-08-23 after the first build reported "no audible ducking".**

The brief's Phase 5 starting parameters specify `Threshold: -30 dB`. Measured against the actual
signal on `DiscordSink.monitor` during a live call (10 ms RMS windows, matching the sidechain
reactivity):

| Metric | Level |
|---|---|
| Median (silence / noise floor) | -59.1 dBFS |
| 90th percentile | -44.0 dBFS |
| 95th percentile | -41.8 dBFS |
| 99th percentile | -38.6 dBFS |
| **Peak over 16 s of conversation** | **-34.8 dBFS** |
| **Time spent above -30 dBFS** | **0.0%** |

Real speech never crosses -30 dB in this chain, so the compressor correctly did nothing. The
compressor, sidechain wiring and routing were all working the entire time — only the threshold was
mis-calibrated. **Do not tune this by ear from the brief's numbers; measure the sidechain.**

Settings changed: `threshold=-50` (9 dB above the measured noise floor, well under speech),
`ratio=12`.

**Verification method** (repeatable; the whole ducking path end-to-end): play a 440 Hz tone into
`easyeffects_sink` and a 1000 Hz tone into `DiscordSink`, capture the hardware sink's monitor, and
compare per-frequency magnitude with and without the Discord tone. Two distinct frequencies allow
the ducked signal and the trigger signal to be measured independently in one capture.

| Discord-side trigger | 440 Hz music delta | 1 kHz Discord delta |
|---|---|---|
| -11 dBFS (unrealistically loud) | **-16.65 dB** | +81.9 dB (unducked) |
| -37 dBFS (matches measured 99th-pct speech) | **-12.12 dB** | +35.1 dB (unducked) |

### 3.10 Capturing a sink monitor requires `stream.capture.sink=true`

A methodological trap that produced two rounds of false conclusions. `pw-record --target
<sink>.monitor` does **not** capture that sink's monitor — it silently falls back to the **default
source** (here, the microphone), yielding plausible-looking but entirely wrong levels. Spectral
analysis exposed it: the captures contained room rumble and unrelated tones rather than the
injected test frequencies.

Correct invocation, mirroring what `20-discord-loopback.conf` does:

```bash
pw-record --target <sink-node-name> -P 'stream.capture.sink=true' out.wav
```

**Always confirm a capture contains the injected test tone before trusting any level derived from
it.** Absolute levels that look implausible are usually a wrong capture target, not a real defect.

### 3.11 Discord has TWO playback nodes; only the voice one is routed

Observed 2026-08-23. Discord emits playback on two separate nodes:

| Node | `application.name` | Carries | Routed to |
|---|---|---|---|
| voice | `WEBRTC VoiceEngine` | call audio (`media.name=playStream`) | `DiscordSink` |
| Electron/Chromium | `Chromium` | notification pings, UI sounds | `easyeffects_sink` |

The Chromium node is **transient** — it exists only while a sound is playing, which is why it is
easy to miss when inspecting the graph.

**This split is desirable and is the intended behaviour.** Notification and UI sounds sit on the
ducked layer: they are attenuated when someone speaks, and they do **not** themselves trigger
ducking of your music. This supersedes the original brief's Phase 5 note (and risk R5), which
predicted that join/leave pings would trigger attenuation — they do not, because they never reach
`DiscordSink`.

It holds because Discord's in-app **Output Device** selector moves only the WebRTC voice stream;
the Electron audio node is unaffected by that setting. The `pulse.rules` fallback in §4.3 must
therefore be constrained by `application.name`, or it would capture the Electron node too and
reintroduce ping-triggered ducking.

## 4. Architecture

```
Discord ──(in-app output select)──► [ DiscordSink ]  null sink
                                          │
                                          ├─► loopback ─────────────────► default sink   (unity, never ducked)
                                          │
                                          └─► monitor ──► sidechain ┐
                                                                    ▼
Everything else ──► [ easyeffects_sink ] ──► LSP sc_compressor ─────► default sink   (ducked)
```

Two load-bearing properties:

- **Discord bypasses the compressor entirely**, so it structurally cannot duck itself. This is
  stronger than any threshold or exclusion setting — there is no signal path from Discord into its
  own attenuator.
- **The sidechain taps `DiscordSink.monitor` upstream of the loopback.** The duck therefore engages
  marginally *ahead* of the audible voice rather than behind it, and any Bluetooth buffering sits
  downstream of both paths equally. Success criterion 3 is satisfied by construction, not by tuning.

The default sink remains the **real hardware device**. `easyeffects_sink` is deliberately *not* made
the default; EasyEffects' "process all output streams" is what pulls other applications onto it.
This is what allows §3.1 to hold — see risk R1, which is the single assumption this rests on.

### 4.1 Null sink

File: `~/.config/pipewire/pipewire.conf.d/10-discord-sink.conf`

```
context.objects = [
  { factory = adapter
    args = {
      factory.name             = support.null-audio-sink
      node.name                = "DiscordSink"
      node.description         = "Discord (ducking source)"
      media.class              = Audio/Sink
      audio.position           = [ FL FR ]
      monitor.channel-volumes  = true
    }
  }
]
```

Unchanged from the source brief. SPA-JSON, not strict JSON.

### 4.2 Loopback to the default sink

File: `~/.config/pipewire/pipewire.conf.d/20-discord-loopback.conf`

```
context.modules = [
  { name = libpipewire-module-loopback
    args = {
      node.description = "Discord Direct Out"
      capture.props = {
        node.name           = "discord_direct_capture"
        target.object       = "DiscordSink"
        stream.capture.sink = true
        node.passive        = true
      }
      playback.props = {
        node.name        = "discord_direct_playback"
        application.name = "DiscordDirectOut"
        media.class      = "Stream/Output/Audio"
      }
    }
  }
]
```

- `stream.capture.sink = true` captures DiscordSink's **monitor** rather than a source.
- `node.passive = true` keeps DiscordSink from forcing the graph awake when nothing is playing.
- **No `target.object` on `playback.props`** — this is the §3.1 fix, not an omission.
- **No `node.dont-reconnect`** — this is the §3.2 fix, not an omission.
- `application.name = "DiscordDirectOut"` exists solely to make this node excludable in §4.4.
- `media.class` is the module default; stated explicitly for clarity.

### 4.2.1 Follow-the-default: verified 2026-08-23

`pw-link -l` after creating the loopback:

```
DiscordSink:monitor_FL          -> discord_direct_capture:input_FL
DiscordSink:monitor_FR          -> discord_direct_capture:input_FR
discord_direct_playback:output_FL -> <current default sink>:playback_FL
discord_direct_playback:output_FR -> <current default sink>:playback_FR
```

The playback leg was observed re-linking automatically across three default-sink changes:
Bluetooth -> HDMI -> Bluetooth -> S/PDIF -> Bluetooth. **§3.1 is confirmed working.**

**Note on which sinks can be made default at all:** the USB DAC's `Speaker` and `Headphones` ports
report `not available` (nothing plugged into those jacks), so WirePlumber refuses to make their
sinks the default and `pactl set-default-sink` on them is silently rejected. This is pre-existing
hardware state, unrelated to this project. The switchable set at present is **AirPods (A2DP),
HDMI, and S/PDIF**. If the front jacks are later populated, those sinks become switchable too and
require no change here — nothing hardcodes a device name.

### 4.3 Routing Discord into DiscordSink

**Primary — in-app.** Discord → Settings → Voice & Video → Output Device → "Discord (ducking
source)".

**Discord must be restarted if it was running when the sink was created.** It enumerates audio
devices via libpulse once at startup and caches the result, so `DiscordSink` will not appear in the
selector otherwise. The same applies after any uninstall/reinstall cycle: the sink is destroyed and
recreated, and Discord keeps a stale reference until restarted. Observed 2026-08-23 — the device
list came back incomplete after a cycle and a restart fixed it. This is Discord/Electron behaviour,
not something this project can work around. Confirmed viable: Discord's playback node already carries an explicit
`target.object`, meaning a specific device is selected in-app rather than "Default", so the
dropdown is authoritative and `DiscordSink` will appear in it once created.

This is strictly better than any config-file approach here: it is persistent in Discord's own
settings, it is playback-only by construction (Discord's input selector is separate, so the
`WEBRTC VoiceEngine` capture stream is untouched), and it introduces zero syntax risk. It also
avoids a conflict — a config-set target would *fight* Discord's own pinned selection.

**Fallback — only if `DiscordSink` does not appear in the dropdown.**

**Before installing the rule, set Discord's in-app Output Device to "Default".** Discord is
currently pinning `target.object` itself (§2); if that pin is left in place it contests the rule at
stream creation and the routing becomes non-deterministic.

File: `~/.config/pipewire/pipewire-pulse.conf.d/50-discord-target.conf`

```
pulse.rules = [
  { matches = [
      { application.process.binary = "Discord"
        application.name           = "WEBRTC VoiceEngine"
        media.class                = "Stream/Output/Audio" }
    ]
    actions = {
      update-props = { target.object = "DiscordSink" }
    }
  }
]
```

**All three constraints are required** (see also §3.11):
- `application.process.binary` keeps Signal out — it may present the same libwebrtc
  `application.name` during a call.
- `media.class` keeps Discord's *microphone capture* stream out.
- `application.name = "WEBRTC VoiceEngine"` keeps Discord's **Electron/Chromium** audio node out.
  That node also reports `application.process.binary = "Discord"`, so a rule matching only the
  binary would drag notification and UI sounds into `DiscordSink` as well.

Matching on `application.process.binary` (not `application.name`) is what keeps Signal out — see
§3.4. Matching on `media.class` is what keeps Discord's microphone capture stream out. Both
constraints are required; either alone is insufficient. Syntax confirmed against the `pulse.rules`
block in `/usr/share/pipewire/pipewire-pulse.conf`.

### 4.4 EasyEffects

1. Output chain: **Compressor** (LSP `sc_compressor_stereo`), Sidechain type **External**, sidechain
   input **DiscordSink monitor**.
2. Starting parameters — Mode Downward, Threshold −30 dB, Ratio 8:1, Attack 5 ms, Release 500 ms,
   Knee −6 dB, Makeup 0 dB, sidechain RMS with ~10 ms reactivity and 0 dB preamp. Tuned in §6.7.
3. Preferences → **"Process all output streams" ON**. This is the catch-all that routes other
   applications onto `easyeffects_sink` without `easyeffects_sink` needing to be the default sink.
4. Blocklist (`blocklist=` under `[StreamOutputs]` in `easyeffectsrc`, comma-separated).
   **Entries are matched against `node.name` — see §3.7:**
   - `WEBRTC VoiceEngine`  ← Discord's playback node
   - `discord_direct_playback`  ← the loopback; **omitting this creates live self-ducking**
   - `Discord` — retained as belt-and-braces for any other node Discord may create; matches
     nothing today, since Discord's playback node is named `WEBRTC VoiceEngine`.
   Do **not** use `DiscordDirectOut` here; it is an `application.name` and will not match.
5. Output device: **follow default** — `useDefaultOutputDevice=true` (§4.4.1). Non-optional; this is what makes §3.1 hold on the EasyEffects side.
6. Autostart: a **systemd user unit**, not an XDG autostart entry. This machine runs Caelestia
   alongside KDE and autostart handling differs between the two sessions; a user unit is
   session-agnostic. EasyEffects ships **no** unit of its own (verified against the package file
   list), so this one is ours to maintain. Flag verified against `easyeffects --help` on 8.2.8:
   `--service-mode` is current and **`--gapplication-service` is deprecated**.

```ini
[Unit]
Description=EasyEffects audio processing
After=graphical-session.target pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/easyeffects --service-mode
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

**Why `graphical-session.target` and not `default.target`:** EasyEffects 8.2.8 is a **Qt6/QML**
application (verified via `ldd`; the 7.x GTK4 rewrite is gone) and needs `WAYLAND_DISPLAY`/`DISPLAY`
present in the systemd user environment even in service mode.
`WantedBy=default.target` fires at `systemd --user` startup, which races or precedes the session's
environment import — GTK init then fails and the unit only limps up via `Restart=on-failure`.

**Caveat that must be tested, not assumed:** KDE activates `graphical-session.target` reliably;
whether the Caelestia session does depends on its uwsm / exec-once setup. The unit must therefore be
verified to start in **both** sessions (see 6.6). If Caelestia never reaches the target, fall back
to EasyEffects' own built-in autostart toggle for that session.

### 4.4.1 Where EasyEffects 8 keeps its settings (verified 2026-08-23)

The Qt rewrite dropped GSettings/dconf. Two separate stores:

- **Application settings** — KConfig INI at `~/.config/easyeffects/db/easyeffectsrc`, written on
  clean exit (`easyeffects --quit`). Editable headlessly **while EasyEffects is stopped**; a running
  instance holds settings in memory and will overwrite the file on exit. Relevant keys, all under
  `[StreamOutputs]`:
  - `processAllOutputs=true|false` — the catch-all from §4.4 step 3
  - `useDefaultOutputDevice=true` — **the follow-the-default hook §3.1 depends on.** Without it,
    EasyEffects pins `outputDevice=` to whatever device was current and will not follow a switch.
- **The blocklist lives in the preset JSON, not in `easyeffectsrc`.** Confirmed from the binary's
  own error strings (`load_blocklist(const PipelineType&, ...)`). A related key,
  `blocklistUsesMediaName`, switches matching from application name to `media.name`. This is why
  §4.4's exclusions are configured in the GUI and exported, not hand-written into the INI.

**Empirical confirmation that §3.6 is a real hazard, not a theoretical one:** during the 6.2 probe,
Discord's own `WEBRTC VoiceEngine` playback stream was pulled onto `easyeffects_sink` along with
everything else, with no exclusions configured. The exclusion list is load-bearing exactly as §3.6
states, and the same will apply to `discord_direct_playback` once it exists.

**On preset files:** the JSON schema under `~/.config/easyeffects/output/` differs across
EasyEffects major versions. Configure the working preset in the GUI first and export it; use that
export as the schema reference. Do not hand-author the sidechain keys.

---

### 4.4.2 FINAL TUNED VALUES (user-approved 2026-08-23)

`~/.config/easyeffects/db/compressorrc`, section `[soe][Compressor#0]`:

```ini
mode=0                            # Downward
threshold=-50                     # measured, not from the brief — see §3.9
ratio=24                          # user-tuned for a firm, predictable drop
attack=5
release=700                       # user-tuned; longer than the brief's 500 ms
knee=-6
makeup=0
sidechainType=2                   # External
sidechainMode=1                   # RMS
sidechainInputDevice=DiscordSink
sidechainReactivity=10
sidechainPreamp=0
```

`~/.config/easyeffects/db/easyeffectsrc`, `[StreamOutputs]`:

```ini
processAllOutputs=true
useDefaultOutputDevice=true
blocklist=Discord,WEBRTC VoiceEngine,discord_direct_playback
plugins=compressor#0
```

These are the numbers to port to a `filter-chain` drop-in if §9 is ever pursued. The high ratio
(24:1) with a threshold near the noise floor produces close to a fixed-depth duck rather than a
proportional one, which is what matches the Windows behaviour being reproduced.

**Note:** EasyEffects persists GUI parameter changes to these files immediately. To edit them by
hand, stop the service first (`systemctl --user stop easyeffects`), edit, then start — a running
instance holds settings in memory and overwrites the file on exit.

### 4.4.3 Calibration tooling must not need numpy

`measure-sidechain.sh` is the one step no user may skip (§3.9), so it is written against the Python
standard library only. Making numpy a hard dependency would pull 49 MiB — plus `cblas` and
`lapack` — into a 50 KB package, and pacman does not install `optdepends` automatically, so an
optional numpy would mean the mandatory tool fails on a fresh install. The stdlib version was
verified to produce byte-identical output to the numpy implementation, and runs in ~370 ms for 16 s
of stereo audio. Only `test-ducking.sh` still uses numpy, for its FFT, and it is genuinely optional.

**Null-sink silence must be excluded from the noise floor.** `DiscordSink` is a null sink, so with
no Discord audio its monitor is *exact digital silence* — those windows floor at -240 dBFS and, if
included, drag the median low enough to produce a meaningless recommendation (observed: a -133 dB
suggestion). The floor is therefore computed only from windows above -100 dBFS, and when speech and
floor are closer than 6 dB the recommendation falls back to `speech - 12 dB` rather than a midpoint
that would sit at speech level and barely trigger.

## 5. Safety rules for the implementer

- **Never** use `pactl load-module` for anything persistent — those modules vanish on restart.
  Drop-in files only.
- **Never** edit anything under `/usr/share/pipewire/` or `/usr/share/wireplumber/`.
- **Never** write into `~/.config/wireplumber/wireplumber.conf.d/00-plasma-pa.conf` — it is
  plasma-pa-generated and will be overwritten.
- **Never** copy `/usr/share/pipewire/pipewire.conf` into `~/.config/pipewire/` — it goes stale on
  upgrades. Create only the `pipewire.conf.d/` subdirectory.
- Config files are SPA-JSON. Unquoted keys and `=` are valid.
- Apply changes with `systemctl --user restart wireplumber pipewire pipewire-pulse`, then
  **immediately** run `journalctl --user -u pipewire -n 50` and confirm the units are up. A
  malformed drop-in crashes PipeWire on start and leaves the machine with no audio at all.
- The rollback script is written **first**, before any config file exists.

---

## 6. Build order

Each step has a verification gate. Do not proceed past a failed gate.

**6.0 — Rollback first.** Write and `chmod +x` `scripts/uninstall.sh` (§8) before creating
any config file. *Gate:* script exists, is executable, and is safe to run when nothing is installed.

**6.1 — Install packages.** `easyeffects` and `lsp-plugins-lv2` (the standalone LV2 package; the
`lsp-plugins` metapackage pulls in CLAP/VST/GStreamer/standalone builds that are not needed).
*Gate:* both install cleanly; `easyeffects --version` runs; and the correct service flag for the
§4.4 unit is confirmed against the installed binary via `easyeffects --help` (do not assume
`--gapplication-service`).

**6.2 — Risk gate R1.** Before building anything on top, empirically determine whether "process all
output streams" intercepts streams while `easyeffects_sink` is **not** the default sink. *Gate:*
launch EasyEffects with the setting on, keep the real device as default, start audio in Zen, and
confirm in `wpctl status` that the stream lands on `easyeffects_sink`. **If it does not, stop and
report** — the fallback changes the design materially (see R1).

**Then turn "process all output streams" back OFF and quit EasyEffects** until step 6.6. Leaving it
on would let EasyEffects capture `discord_direct_playback` the moment it is created in 6.4 —
before the §3.6 exclusion exists — producing a feedback loop and a misleading 6.4 gate result.

**6.3 — Null sink.** Create `10-discord-sink.conf`, restart, check journal. *Gate:* `wpctl status`
lists `DiscordSink`; `pactl list sources short` shows `DiscordSink.monitor`.

**6.4 — Loopback.** Create `20-discord-loopback.conf`, restart, check journal. *Gate:* `pw-link -l`
shows `discord_direct_playback` linked to the current default sink's ports. **Then switch output
devices and confirm the link follows** — this is the §3.1 acceptance test and the reason the design
differs from the brief.

**6.5 — Route Discord.** Select "Discord (ducking source)" in Discord's Voice & Video settings.
*Gate:* with a call active, `wpctl status` shows the Discord playback stream nested under
`DiscordSink`, and the `WEBRTC VoiceEngine` **capture** stream still on the USB mic. If
`DiscordSink` is absent from the dropdown, fall back to §4.3's `pulse.rules` drop-in.

**6.6 — Compressor.** Build the chain per §4.4. **Enter all three exclusions from §4.4 step 4
before re-enabling "process all output streams"**, not after — the ordering matters (see 6.2). *Gate:* in
`qpwgraph`, `DiscordSink` monitor ports connect to the compressor's sidechain inputs;
`easyeffects_sink` output feeds the hardware sink; and **`discord_direct_playback` is NOT on
`easyeffects_sink`**. *Gate:* the systemd user unit starts cleanly in **both** the KDE and Caelestia
sessions (§4.4 caveat); if Caelestia never activates `graphical-session.target`, use EasyEffects'
built-in autostart toggle there.

**6.7 — Tune.** Set threshold by watching the gain-reduction meter on a live call, not by ear.
Too high and quiet talkers never trigger it; too low and keyboard clatter ducks constantly. Release
400–600 ms; shorter pumps audibly between words. For a fixed predictable drop, raise the ratio
(12:1+) and place the threshold where voices reliably cross it.

**6.8 — Verify R2.** Confirm Discord screen-share-with-audio still captures Zen/spotifyd correctly
after the re-routing.

**6.9 — Full-cycle test.** Reboot, then: both sinks exist unattended → music lands on
`easyeffects_sink` → Discord lands on `DiscordSink` → someone speaks, other audio ducks and Discord
does not → silence, audio recovers → quit and restart Discord, routing holds → **switch output
device mid-session, everything follows.**

---

## 7. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| **R1** | ~~"Process all output streams" may only intercept when `easyeffects_sink` IS the default sink.~~ | **RESOLVED 2026-08-23 — PASS** | Tested at 6.2. With default sink = `bluez_output...` and `easyeffects_sink` **not** default, all four live streams (Zen, spotifyd, a `pw-play` test tone, and Discord) were moved onto `easyeffects_sink` (sink id 508). Interception does **not** require being the default sink. The no-hardcoded-names design is sound. |
| R2 | `discord_capture` screen-share audio breaks when apps move to `easyeffects_sink` | Medium | Capture taps app output nodes directly, so it most likely survives. Verified explicitly at 6.8, not assumed. |
| R3 | Malformed drop-in crashes PipeWire, leaving no audio at all | High | Rollback written first (6.0); journal checked after every single restart. |
| R4 | Bluetooth profile switch renames the sink mid-session | Low | No device name is hardcoded, so nothing to break. The separate USB mic means a call should not force an A2DP→HFP switch; confirmed at 6.9. |
| R5 | ~~Discord notification pings trigger ducking~~ | **Does not occur — see §3.11** | Pings come from Discord's separate Electron audio node, which stays on `easyeffects_sink`. They are ducked *by* speech rather than triggering it. Confirmed desirable by the user; the §4.3 fallback rule is constrained to preserve it. |
| R6 | EasyEffects preset schema differs by version | Low | Configure in GUI, export, use the export as reference. Never hand-author sidechain keys. |
| R7 | Discord's self-updater changes node properties | Low | The in-app selector (§4.3) is unaffected by property changes; only the `pulse.rules` fallback would need re-checking against `pw-dump`. |

---

## 8. Rollback

Single command: `scripts/uninstall.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

rm -f ~/.config/pipewire/pipewire.conf.d/10-discord-sink.conf
rm -f ~/.config/pipewire/pipewire.conf.d/20-discord-loopback.conf
rm -f ~/.config/pipewire/pipewire-pulse.conf.d/50-discord-target.conf

systemctl --user disable --now easyeffects.service 2>/dev/null || true
rm -f ~/.config/systemd/user/easyeffects.service
systemctl --user daemon-reload

systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 2
systemctl --user --no-pager --lines=0 status pipewire pipewire-pulse wireplumber || true
```

**Deliberately NOT done** — `rm ~/.local/state/wireplumber/stream-properties`. The source brief
called for this (under the non-existent name `restore-stream`); it would wipe every application's
saved volume and routing. If Discord's saved state ever needs clearing, remove only its entries.

**Manual steps after running it:**
1. Discord → Settings → Voice & Video → Output Device → set back to your real output device.
   *(Required — Discord will otherwise point at a sink that no longer exists.)*
2. EasyEffects → turn off "Process all output streams", or uninstall:
   `sudo pacman -Rns easyeffects lsp-plugins-lv2`.

---

## 9. Deferred

- **Port to a native PipeWire `filter-chain`** once the compressor numbers are settled, dropping the
  EasyEffects dependency entirely. Attractive for a configure-once system, and `lsp-plugins-lv2`
  will already be installed. Blocked on R1's outcome: if EasyEffects turns out to be the only thing
  providing the catch-all that routes other applications onto the effect sink, a filter-chain port
  needs its own answer to that problem first.
- **Independent Discord volume.** Currently unity-gain pass-through per §2.1. Adding a volume
  control on the loopback is a one-line change if wanted later.
