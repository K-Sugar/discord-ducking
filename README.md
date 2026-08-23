<div align="center">
  <img src="img/discord-ducking.png" alt="discord-ducking logo" width="96">
  <h1>discord-ducking</h1>
  <p><strong>Discord's "Attenuation (when others speak)" for Linux.</strong></p>
</div>

Discord ships automatic audio attenuation on Windows and macOS, but not on Linux. This reproduces
it on PipeWire: when someone talks in a Discord call, your game/music/browser audio drops in real
time and comes back when they stop.

It is **signal-triggered**, not call-state-triggered. Audio ducks while people are *actually
speaking*, not for the whole duration of the call. Discord's own audio is never ducked by its own
voice, and that is guaranteed structurally rather than by tuning.

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
- `python-numpy` is **optional**, only for `discord-ducking test` (the two-tone proof).
  Threshold calibration needs nothing beyond the Python standard library.
- A Discord build whose **Voice & Video → Output Device** selector lists PipeWire sinks
  (the native Arch package does; Flatpak may differ)

```bash
sudo pacman -S --needed easyeffects lsp-plugins-lv2
# optional, only for `discord-ducking test`:
sudo pacman -S --needed python-numpy
```

---

## Install

### As a package (recommended for Arch / CachyOS)

```bash
git clone https://github.com/K-Sugar/discord-ducking
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
discord-ducking bt-mic on|off|status   Bluetooth mic vs playback quality
discord-ducking uninstall   full teardown
```

### Straight from the repo

```bash
git clone https://github.com/K-Sugar/discord-ducking
cd discord-ducking
./scripts/install.sh
```

The installer backs up anything it touches to `~/.local/share/discord-ducking/backup-<timestamp>/`,
and **merges** into your EasyEffects config rather than overwriting it, so an existing effects chain
and blocklist are preserved.

### Then three manual steps

These apply to both install methods. The package form is shown first, the from-the-repo form second.

**1. Point Discord at the sink**

Discord → Settings → Voice & Video → **Output Device** → `Discord (ducking source)`

If Discord was already running during the install, **restart it first**. It caches its device list
at startup and will not show the new sink otherwise.

**2. Check it**

```bash
discord-ducking verify      # or: ./scripts/verify.sh
```

**3. Calibrate the threshold, and do not skip this**

```bash
discord-ducking measure     # or: ./scripts/measure-sidechain.sh
```

Run it while someone is actually talking. This is the step people get wrong. See below.

---

## Calibration is mandatory, and it is per-machine

The correct compressor threshold depends on your Discord volume, your output device and the
speaker's mic. It is **not** portable between systems.

On the reference machine, measured Discord speech looked like this:

| Metric | Level |
|---|---|
| Median (silence / noise floor) | -59.1 dBFS |
| 95th percentile | -41.8 dBFS |
| Peak over 16 s of conversation | -34.8 dBFS |

The threshold value commonly suggested for this kind of setup is **-30 dB**. Real speech crossed it
**0.0 % of the time**. The compressor was wired perfectly and simply never triggered. Symptom:
"everything looks right but I hear no difference."

`discord-ducking measure` records the real sidechain signal, prints the level distribution, and
recommends a threshold midway between your noise floor and your speech level. Apply it with:

```bash
systemctl --user stop easyeffects
sed -i 's/^threshold=.*/threshold=-50/' ~/.config/easyeffects/db/compressorrc
systemctl --user start easyeffects
```

Or just type it into the **Threshold** box in the EasyEffects window, with no stopping and no
restarting. See [Tuning](#tuning) for what every other control on that page does.

To prove the whole chain end-to-end without needing a second person:

```bash
discord-ducking test
```

It injects a 440 Hz "music" tone and a 1000 Hz "voice" tone, captures the output, and reports the
per-frequency change. Two distinct frequencies let the ducked signal and the trigger be measured
independently in a single capture.

---

## Tuning

Everything below lives in one compressor. You can change it two ways: in the **EasyEffects
window**, or by editing the config file. The window is easier and safer, so start there.

### In the EasyEffects window

Launch `easyeffects`, stay on the **Output** tab, and click **Compressor** in the effects list.
Changes apply to live audio immediately and are saved for you. No restart, no file editing.

The **Gain reduction** meter on that page is the fastest tuning tool you have: get someone to
talk (or run `discord-ducking test` in another terminal) and watch it. If it never moves,
your threshold is too high. If it never returns to 0, it is too low.

| Control | Config key | What it does |
|---|---|---|
| **Threshold** | `threshold` | How loud the Discord voice must be before ducking starts. **The one you must calibrate.** Never triggers → lower it. Ducks on keyboard noise → raise it. |
| **Ratio** | `ratio` | How hard it ducks once triggered. High values give a near fixed-depth duck, which is what Windows does. Lower it for a gentler dip. |
| **Attack** | `attack` | How fast the duck engages, in ms. Too slow and the first word gets through at full volume. |
| **Release** | `release` | How fast the volume comes back, in ms. **The setting most worth your time.** Below ~400 ms it pumps audibly between words; too high and music stays quiet long after the talking stops. |
| **Knee** | `knee` | How abruptly ducking starts around the threshold. A softer knee makes the onset less noticeable. |
| **Makeup** | `makeup` | Adds gain back after compression. Leave at 0, because you *want* the level drop. |
| **Compression mode** | `mode` | Must stay **Downward**. Upward or Boosting inverts the effect. |
| **Sidechain → Type** | `sidechainType` | Must stay **External**. This is what makes the compressor listen to Discord instead of to the music. Changing it breaks the whole design. |
| **Sidechain → Input device** | `sidechainInputDevice` | Must stay **DiscordSink**. This is where the trigger signal comes from. |
| **Sidechain → Mode** | `sidechainMode` | **RMS** averages over a short window and tracks perceived loudness; **Peak** reacts to instantaneous spikes and is twitchier on speech. |
| **Sidechain → Reactivity** | `sidechainReactivity` | Size of that RMS averaging window, in ms. Raise it if brief consonants cause flutter. |
| **Sidechain → Preamp** | `sidechainPreamp` | Gain applied to the trigger signal only. An alternative to lowering the threshold if a quiet talker never triggers ducking. |
| **Sidechain → Lookahead** | `sidechainLookahead` | Delays the audio so the duck can start *before* the trigger. Not needed here, because the sidechain already taps upstream of the loopback, so the duck leads the voice slightly. |
| **Sidechain → Listen** | `sidechainListen` | Diagnostic toggle: replaces the output with the trigger signal itself, so you *hear* what the compressor is reacting to. Turn it on and you should hear Discord voice and nothing else. If you hear your own microphone or your music, the sidechain is wired to the wrong source. Turn it back off when done. |

The two rows marked *must stay* are structural. Everything else is taste.

### In the config file

Reference values (`~/.config/easyeffects/db/compressorrc`), for scripting or for copying a known-good
setup to another machine:

| Setting | Value | Notes |
|---|---|---|
| `threshold` | `-50` | **calibrate this yourself** |
| `ratio` | `24` | high ratio ⇒ near fixed-depth duck, like Windows |
| `attack` | `5` | ms |
| `release` | `700` | ms; below ~400 pumps between words |
| `knee` | `-6` | dB |
| `makeup` | `0` | dB |
| `mode` | `0` | Downward |
| `sidechainType` | `2` | External |
| `sidechainInputDevice` | `DiscordSink` | the trigger source |
| `sidechainMode` | `1` | RMS |
| `sidechainReactivity` | `10` | ms |

> **Stop the service before hand-editing these files.** A running EasyEffects holds settings in
> memory and overwrites the file on exit, so your edit silently disappears. This is the reason to
> prefer the window: it has no such trap.

```bash
systemctl --user stop easyeffects
sed -i 's/^release=.*/release=700/' ~/.config/easyeffects/db/compressorrc
systemctl --user start easyeffects
```

### Quick reference

- Quiet talkers do not trigger it → **lower** the threshold (or raise sidechain preamp)
- Background noise / keyboard ducks constantly → **raise** it
- Audible pumping between words → **lengthen** release
- First word slips through at full volume → **shorten** attack
- Duck is too aggressive → **lower** the ratio

Discord's join/leave notification pings will also trigger ducking. That is inherent to
signal-triggered attenuation and matches Windows. Not a bug.

---

## Uninstall

```bash
discord-ducking uninstall   # or: ./scripts/uninstall.sh
```

Removes the drop-ins and the unit, turns the catch-all off, clears the blocklist entries and
restarts the audio stack. Afterwards, set Discord's Output Device back to your real device, since
it will otherwise point at a sink that no longer exists.

If you installed the package, run `discord-ducking uninstall` **before** `pacman -R discord-ducking`,
because pacman will not remove per-user config.

It deliberately does **not** delete `~/.local/state/wireplumber/stream-properties`, which holds
saved volume and routing for *every* application on the system.

---

## Troubleshooting

**Everything looks correct but nothing ducks.**
Almost always the threshold. Run `discord-ducking measure`. See the calibration section.

**Discord ducks itself / its audio sounds compressed.**
The loopback got captured by EasyEffects. The blocklist must contain **`discord_direct_playback`**.
EasyEffects matches the blocklist against **`node.name`, not `application.name`**, so the node's
`application.name` (`DiscordDirectOut`) will *not* work. If you rename `node.name` in
`20-discord-loopback.conf`, you must update the blocklist to match or self-ducking returns silently.

**Ducking stops after switching headphones.**
Check `useDefaultOutputDevice=true` in `easyeffectsrc`. Without it EasyEffects pins one device.

**`DiscordSink` is missing from Discord's dropdown.**
**Restart Discord first.** Discord enumerates audio devices through libpulse at startup and caches
the list, so a sink created (or recreated) while it is running will not appear until it restarts.
This is the usual cause right after installing, and after any install/uninstall cycle, where
Discord can also end up holding a stale reference to the old sink and showing an incomplete device
list until restarted.

Only if it is still absent after a restart, set Discord's output to `Default` and install the
optional `pulse.rules` fallback described in `docs/DESIGN.md` §4.3.

**Bluetooth audio goes mono / sounds bad during calls.**
Check `discord-ducking bt-mic status`. If the active profile is `headset-head-unit`, the device is
in HSP/HFP: mono, ~24 kHz. Unrelated to ducking, but it degrades everything you hear for the whole
call.

Two different causes, with different fixes:

*WirePlumber switched it.* It flips Bluetooth devices to headset mode whenever any application
opens a capture stream, **even when that app records from a different microphone**. Switch back
with `discord-ducking bt-mic off`. To stop it happening at all, enable the optional drop-in:

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
cp config/wireplumber/wireplumber.conf.d/51-bt-no-autoswitch.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

Trade-off: your Bluetooth mic then stops being selected automatically. Use it deliberately, with
`discord-ducking bt-mic on` before you need it and `off` afterwards. This is the better setup if you
usually use a separate mic but occasionally want the headset one.

*The device connected as a headset.* If `bt-mic status` shows **no A2DP profile at all**, no
software switch can fix it, because the profile was never negotiated. This happens when the device
connects while an app is already recording. Disconnect and reconnect it with nothing recording.

**No audio at all after installing.**
A malformed drop-in can stop PipeWire from starting. Run `discord-ducking uninstall`, then
`journalctl --user -u pipewire -n 50`.

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
  wireplumber/.../51-bt-no-autoswitch.conf           OPTIONAL: stop BT dropping to headset mode
scripts/
  install.sh            idempotent installer, backs up and merges
  uninstall.sh          full teardown
  verify.sh             health check; exit 0 = all good
  measure-sidechain.sh  measures real speech level, recommends a threshold
  test-ducking.sh       two-tone end-to-end proof
  bt-profile.sh         Bluetooth A2DP <-> headset-mic toggle
docs/
  DESIGN.md             full spec, and every deviation with the evidence behind it
  BUILD-LOG.md          gated build checklist with results
```

`docs/DESIGN.md` §3 is the interesting part: every deviation from the original plan, each with the
measurement that forced it.

---

## Known limitations

- Discord notification sounds trigger ducking (inherent; matches Windows).
- The threshold needs re-calibrating if you substantially change your Discord volume or output
  device chain.
- `easyeffects.service` hooks `graphical-session.target`, which KDE Plasma activates (verified).
  Most desktop sessions do. If yours does not, the service simply will not autostart. Check with
  `systemctl --user is-active graphical-session.target` and fall back to EasyEffects' own
  "start service at login" toggle.
- Discord screen-share-with-audio is unaffected by the routing change (verified): the capture taps
  application output nodes directly, upstream of the effects sink.
- Bluetooth devices that connect while an app is already recording may negotiate as a headset and
  offer no A2DP profile at all. `discord-ducking bt-mic status` detects this; only a reconnect
  fixes it.

---

## Issues and contributions

Bug reports and PRs welcome. If something does not work on your setup, open an issue with the
output of `discord-ducking verify`.

---

## License

MIT, see [LICENSE](LICENSE).
