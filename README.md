# discord-ducking

**Discord's "Attenuation (when others speak)" for Linux.**

Discord ships automatic audio attenuation on Windows only. This reproduces it on PipeWire: when
someone talks in a Discord call, your game/music/browser audio drops in real time and comes back
when they stop.

It is **signal-triggered**, not call-state-triggered. Audio ducks while people are *actually
speaking*, not for the whole duration of the call. Discord's own audio is never ducked by its own
voice — that is guaranteed structurally, not by tuning.

Built and running on CachyOS with PipeWire 1.6.8 / WirePlumber 0.5.15.

---

## How it works

```
Discord ──(in-app output select)──► [ DiscordSink ]  (null sink)
                                          │
                                          ├─► loopback ─────────────────► default sink   (unity, never ducked)
                                          │
                                          └─► monitor ──► sidechain ┐
                                                                    ▼
Everything else ──► [ easyeffects_sink ] ──► compressor ───────────► default sink   (ducked)
```

Discord is routed into a dedicated null sink. That sink's monitor does two jobs: it feeds a
loopback straight to your speakers at full volume, and it drives the **external sidechain** of a
compressor that every *other* application passes through.

Two properties make this work:

- **Discord bypasses the compressor entirely**, so it structurally cannot duck itself. There is no
  signal path from Discord into its own attenuator.
- **The sidechain taps the monitor upstream of the loopback**, so the duck engages slightly *ahead*
  of the audible voice rather than lagging it.

### No device names are hardcoded

Both output paths follow whatever your **current default sink** is, and re-link automatically when
you switch devices. Verified across Bluetooth → HDMI → S/PDIF. Swap headsets freely; nothing needs
editing. This is why the loopback deliberately omits `target.object` and `node.dont-reconnect`.

---

## Requirements

- PipeWire + WirePlumber (`pipewire-pulse` for the PulseAudio layer)
- `easyeffects` (8.x) and `lsp-plugins-lv2`
- `python-numpy` — only for the measurement scripts
- A Discord build whose **Voice & Video → Output Device** selector lists PipeWire sinks
  (the native Arch package does; Flatpak may differ)

```bash
sudo pacman -S --needed easyeffects lsp-plugins-lv2 python-numpy
```

---

## Install

### As a package (recommended for Arch / CachyOS)

```bash
cd discord-ducking
makepkg -si            # builds from this tree; no remote or tarball needed
discord-ducking install
```

This installs the tooling to `/usr/share/discord-ducking` with a `discord-ducking`
command, and pulls in `easyeffects` / `lsp-plugins-lv2` as real package dependencies.

Configuration lives in your home directory, which pacman must not write to, so
`discord-ducking install` is the separate per-user step. Everything is available as
subcommands:

```
discord-ducking install     deploy config into ~/.config, enable the service
discord-ducking verify      health check (exit 0 = all good)
discord-ducking measure     measure speech level, recommend a threshold
discord-ducking test        two-tone end-to-end proof
discord-ducking uninstall   full teardown
```

Uninstalling: run `discord-ducking uninstall` **before** `pacman -R discord-ducking`,
since pacman will not remove per-user config.

### Straight from the repo

```bash
git clone <this repo> && cd discord-ducking
./scripts/install.sh
```

The installer backs up anything it touches to `~/.local/share/discord-ducking/backup-<timestamp>/`,
and **merges** into your EasyEffects config rather than overwriting it — an existing effects chain
and blocklist are preserved.

Then three manual steps:

**1. Point Discord at the sink**

Discord → Settings → Voice & Video → **Output Device** → `Discord (ducking source)`

**2. Check it**

```bash
./scripts/verify.sh
```

**3. Calibrate the threshold — do not skip this**

```bash
./scripts/measure-sidechain.sh     # run while someone is actually talking
```

This is the step people get wrong. See below.

---

## Calibration is mandatory, and it is per-machine

The correct compressor threshold depends on your Discord volume, your output device and the
speaker's mic — it is **not** portable between systems.

On the reference machine, measured Discord speech looked like this:

| Metric | Level |
|---|---|
| Median (silence / noise floor) | −59.1 dBFS |
| 95th percentile | −41.8 dBFS |
| Peak over 16 s of conversation | −34.8 dBFS |

The threshold value commonly suggested for this kind of setup is **−30 dB**. Real speech crossed it
**0.0 % of the time** — the compressor was wired perfectly and simply never triggered. Symptom:
"everything looks right but I hear no difference."

`measure-sidechain.sh` records the real sidechain signal, prints the level distribution, and
recommends a threshold midway between your noise floor and your speech level. Apply it with:

```bash
systemctl --user stop easyeffects
sed -i 's/^threshold=.*/threshold=-50/' ~/.config/easyeffects/db/compressorrc
systemctl --user start easyeffects
```

To prove the whole chain end-to-end without needing a second person:

```bash
./scripts/test-ducking.sh
```

It injects a 440 Hz "music" tone and a 1000 Hz "voice" tone, captures the output, and reports the
per-frequency change. Two distinct frequencies let the ducked signal and the trigger be measured
independently in a single capture.

---

## Tuning

Reference values (`~/.config/easyeffects/db/compressorrc`):

| Setting | Value | Notes |
|---|---|---|
| `threshold` | `-50` | **calibrate this yourself** |
| `ratio` | `24` | high ratio ⇒ near fixed-depth duck, like Windows |
| `attack` | `5` | ms |
| `release` | `700` | ms; below ~400 pumps between words |
| `sidechainType` | `2` | External |
| `sidechainMode` | `1` | RMS |
| `sidechainReactivity` | `10` | ms |

- Quiet talkers do not trigger it → **lower** the threshold
- Background noise / keyboard ducks constantly → **raise** it
- Audible pumping between words → **lengthen** release

> **Stop the service before hand-editing these files.** A running EasyEffects holds settings in
> memory and overwrites the file on exit.

Discord's join/leave notification pings will also trigger ducking. That is inherent to
signal-triggered attenuation and matches Windows. Not a bug.

---

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the drop-ins and the unit, turns the catch-all off, clears the blocklist entries and
restarts the audio stack. Afterwards, set Discord's Output Device back to your real device — it
will otherwise point at a sink that no longer exists.

It deliberately does **not** delete `~/.local/state/wireplumber/stream-properties`, which holds
saved volume and routing for *every* application on the system.

---

## Troubleshooting

**Everything looks correct but nothing ducks.**
Almost always the threshold. Run `./scripts/measure-sidechain.sh`. See the calibration section.

**Discord ducks itself / its audio sounds compressed.**
The loopback got captured by EasyEffects. The blocklist must contain **`discord_direct_playback`**.
EasyEffects matches the blocklist against **`node.name`, not `application.name`** — so the node's
`application.name` (`DiscordDirectOut`) will *not* work. If you rename `node.name` in
`20-discord-loopback.conf`, you must update the blocklist to match or self-ducking returns silently.

**Ducking stops after switching headphones.**
Check `useDefaultOutputDevice=true` in `easyeffectsrc`. Without it EasyEffects pins one device.

**`DiscordSink` is missing from Discord's dropdown.**
Set Discord's output to `Default` first, then install the optional `pulse.rules` fallback described
in `docs/DESIGN.md` §4.3.

**Bluetooth audio goes mono / sounds bad during calls.**
Check `pactl list cards | grep 'Active Profile'`. If it says `headset-head-unit`, the device has
dropped to HFP (mono, ~24 kHz). WirePlumber switches Bluetooth devices to the headset profile when
any application opens a capture stream — *even if that application records from a different
microphone*. Unrelated to ducking, but it degrades everything you hear during a call. If you always
use a separate mic, disable it in `~/.config/wireplumber/wireplumber.conf.d/51-no-hfp.conf`:

```
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
```

Note that port names change with the channel layout (`output_FL`/`output_FR` when stereo,
`output_MONO` when mono) — anything inspecting the graph must not assume stereo.

**No audio at all after installing.**
A malformed drop-in can stop PipeWire from starting. Run `./scripts/uninstall.sh`, then
`journalctl --user -u pipewire -n 50`.

**Writing your own measurement scripts?**
`pw-record --target <sink>.monitor` does **not** capture that sink's monitor — it silently falls
back to the default source (your microphone) and yields plausible but completely wrong numbers.
Use `pw-record --target <sink> -P 'stream.capture.sink=true'`.

---

## Layout

```
PKGBUILD                  builds from the working tree; makepkg -si
discord-ducking.install   post-install notes shown by pacman
bin/discord-ducking       CLI front-end (subcommand dispatcher)
config/
  pipewire/pipewire.conf.d/10-discord-sink.conf      null sink
  pipewire/pipewire.conf.d/20-discord-loopback.conf  loopback (follows default sink)
  systemd/user/easyeffects.service                   graphical-session.target, not default.target
  easyeffects/compressorrc                           compressor + sidechain parameters
  easyeffects/easyeffectsrc.reference                keys install.sh merges (reference only)
scripts/
  install.sh            idempotent installer, backs up and merges
  uninstall.sh          full teardown
  verify.sh             health check; exit 0 = all good
  measure-sidechain.sh  measures real speech level, recommends a threshold
  test-ducking.sh       two-tone end-to-end proof
docs/
  DESIGN.md             full spec, and every deviation with the evidence behind it
  BUILD-LOG.md          gated build checklist with results
```

`docs/DESIGN.md` §3 is the interesting part: ten documented deviations from the original plan, each
with the measurement that forced it.

---

## Known limitations

- Discord notification sounds trigger ducking (inherent; matches Windows).
- The threshold needs re-calibrating if you substantially change your Discord volume or output
  device chain.
- `easyeffects.service` is verified under KDE Plasma. Other sessions must activate
  `graphical-session.target`; if yours does not, use EasyEffects' own autostart toggle instead.
- Discord screen-share-with-audio was not re-verified after the routing change. It taps application
  output nodes directly so it is expected to be unaffected.

---

## License

MIT — see [LICENSE](LICENSE).
