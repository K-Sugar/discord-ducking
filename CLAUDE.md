# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Reproduces Discord's Windows-only "Attenuation (when others speak)" on PipeWire. There is **nothing
to compile** — the project is SPA-JSON/INI config templates plus Bash and stdlib-Python tooling,
packaged for Arch.

It modifies the user's **live audio system**. A malformed PipeWire drop-in can leave the machine
with no audio at all, so `scripts/uninstall.sh` is the safety net and must keep working.

## Commands

```bash
bash -n scripts/*.sh bin/discord-ducking   # syntax check — the closest thing to a lint
./scripts/verify.sh                        # health check; exit 0 = all good. THE regression test.
./scripts/test-ducking.sh [trigger_dbfs]   # functional proof: injects two tones, measures the duck
./scripts/measure-sidechain.sh [seconds]   # calibration; run while someone is talking in a call
./scripts/install.sh                       # deploy to ~/.config (restarts the audio stack)
./scripts/uninstall.sh                     # full teardown
makepkg -f --noconfirm                     # build the package from the working tree
```

`verify.sh` is the test suite — nine checks, each naming its likely cause. There is no per-check
runner; to isolate one, run its underlying command (`pw-link -l`, `pactl list sink-inputs`, or grep
the EasyEffects config directly). After changing anything that touches the graph, run it.

Verify from a *packaged* tree without installing:
`tar -xf discord-ducking-*.pkg.tar.zst -C /tmp/x && /tmp/x/usr/bin/discord-ducking verify`

## Architecture

```
Discord ──(in-app output select)──► [ DiscordSink ] (null sink)
                                          ├─► loopback ─────────────► default sink   (never ducked)
                                          └─► monitor ──► sidechain ┐
Everything else ──► [ easyeffects_sink ] ──► compressor ───────────► default sink   (ducked)
```

Two properties carry the design, and changes must preserve both:

- **Discord bypasses the compressor entirely**, so it cannot duck itself. Structural, not a tuning
  choice — there is no signal path from Discord into its own attenuator.
- **No device name is hardcoded anywhere.** Both output legs are ordinary streams that follow the
  current default sink. This is why `20-discord-loopback.conf` deliberately omits `target.object`
  *and* `node.dont-reconnect`, and why `useDefaultOutputDevice=true` is mandatory on the
  EasyEffects side. Removing any of those silently breaks device switching.

Three config surfaces, deployed by `install.sh`: PipeWire drop-ins (`~/.config/pipewire/pipewire.conf.d/`),
EasyEffects KConfig INI (`~/.config/easyeffects/db/`), and a systemd **user** unit.

Packaging: pacman must not write to `$HOME`, so the package installs templates + scripts to
`/usr/share/discord-ducking` with a `discord-ducking` dispatcher in `/usr/bin`; per-user deployment
is the separate `discord-ducking install` step. `bin/discord-ducking` resolves its scripts
prefix-relatively so it works from a checkout, a real install, or a staged tree.

## Traps that have already cost real debugging time

`docs/DESIGN.md` §3 records every deviation from the original plan with the evidence that forced
it. Read it before changing behaviour. The ones that bite hardest:

- **EasyEffects' blocklist matches `node.name`, NOT `application.name`** (§3.7). The loopback must
  be listed as `discord_direct_playback`. Renaming `node.name` in the loopback config without
  updating the blocklist silently reintroduces self-ducking. This hides because pulse clients
  usually have identical `node.name` and `application.name`; only native PipeWire nodes differ.
- **Stop the EasyEffects service before editing `~/.config/easyeffects/db/*rc`.** A running
  instance holds settings in memory and overwrites the file on exit.
- **`easyeffects --quit` does not exit when nothing is running** — it launches a new instance, shows
  its window, and blocks forever. Use the `stop_easyeffects` helper in `install.sh`/`uninstall.sh`
  (checks `pgrep -x` first, `timeout`-capped, falls back to `pkill -x`).
- **Capturing a sink monitor requires `-P 'stream.capture.sink=true'`.** `pw-record --target
  <sink>.monitor` silently records the *default source* (the microphone) and yields plausible but
  entirely wrong numbers (§3.10). Always confirm a capture contains the injected test tone.
- **Never combine `set -o pipefail` with `cmd | grep -q`.** grep exits at the first match, the
  producer takes SIGPIPE (141), and pipefail reports a successful match as a failure. `verify.sh`
  captures link tables into variables instead.
- **Never `pkill -f` with a pattern that appears in the calling script** — it matches and kills the
  script itself.
- **Port names follow the channel layout**: `output_FL`/`output_FR` when stereo, `output_MONO` when
  the sink is mono (a Bluetooth device in HFP). Never assume stereo when inspecting the graph.
- **WirePlumber's `stream.rules` is not a routing mechanism** (§3.3) — it feeds a local property
  copy used for state-key forming only. Route via Discord's in-app selector, or `pulse.rules` on
  the PipeWire side.
- **Discord emits two playback nodes** (§3.11): `WEBRTC VoiceEngine` (voice, routed to DiscordSink)
  and a transient `Chromium` node (notification/UI sounds, intentionally left on the ducked layer).
  Any routing rule must be constrained by `application.name`, or pings start triggering ducking.

## Calibration is machine-specific

The compressor threshold cannot be shipped as a constant. On the reference system real speech peaked
at −34.8 dBFS, so the widely suggested −30 dB threshold never triggered once — everything looked
correctly wired and nothing ducked (§3.9). `measure-sidechain.sh` derives it from the actual signal.

Consequently `measure-sidechain.sh` is **deliberately stdlib-only**: `python-numpy` is 49 MiB plus
`cblas`/`lapack` for a 50 KB package, and pacman does not auto-install `optdepends`, so a numpy
dependency would make the one mandatory step fail on a fresh install. Keep it that way. Only
`test-ducking.sh` may use numpy.

`DiscordSink` is a **null sink**, so with no Discord audio its monitor is *exact digital silence*
(−240 dBFS). Those windows must be excluded from any noise-floor calculation or the recommendation
becomes nonsense.
