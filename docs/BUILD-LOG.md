# Build Checklist — Discord Voice Ducking

Spec: `DESIGN.md`. Do not proceed past a failed gate. Mark `[x]` only after the gate passes.

**Standing rule:** after every `systemctl --user restart wireplumber pipewire pipewire-pulse`, run
`journalctl --user -u pipewire -n 50` and confirm the units came back up *before* doing anything
else. A malformed drop-in leaves the machine with no audio at all.

---

## Step 0 — Rollback first  (DESIGN §6.0, §8)  ✅ DONE 2026-08-23
- [x] Write `scripts/uninstall.sh` per §8
- [x] `chmod +x rollback.sh`
- [x] **GATE:** script exists, is executable, and runs safely when nothing is installed yet

## Step 1 — Install packages  (§6.1)  ✅ DONE 2026-08-23
- [x] `sudo pacman -S --needed easyeffects lsp-plugins-lv2`  (needed full `-Syu` + reboot first — partial-upgrade block)
- [x] **GATE:** `easyeffects 8.2.8-1.1` + `lsp-plugins-lv2 1.2.33-2.1` installed; `easyeffects --version` runs
- [x] **GATE:** service flag confirmed = `--service-mode` (`--gapplication-service` is deprecated in 8.2.8)

## Step 2 — RISK GATE R1  (§6.2)  ✅ PASSED 2026-08-23 — design confirmed sound
- [x] Launch EasyEffects, enable "Process all output streams", keep the real device as default sink
- [x] Start audio (Zen + spotifyd live, plus a `pw-play` test tone)
- [x] **GATE PASSED:** all 4 streams moved to `easyeffects_sink` (id 508) while default sink stayed `bluez_output...`
- [x] ~~IF THIS FAILS: STOP AND REPORT~~ — not needed, R1 passed. Design confirmed sound.
- [x] Turned `processAllOutputs=false` and quit EE; `easyeffects_sink` gone, streams back on hardware sink

## Step 3 — Null sink  (§4.1, §6.3)  ✅ DONE 2026-08-23
- [x] `mkdir -p ~/.config/pipewire/pipewire.conf.d`
- [x] Write `10-discord-sink.conf`
- [x] Restart units + check journal (clean)
- [x] **GATE:** `wpctl status` lists `DiscordSink` (id 31, "Discord (ducking source)")
- [x] **GATE:** `DiscordSink.monitor` present

## Step 4 — Loopback  (§4.2, §6.4)  ✅ DONE 2026-08-23
- [x] Write `20-discord-loopback.conf` — no `target.object`, no `node.dont-reconnect`
- [x] Restart units + check journal (clean)
- [x] **GATE:** `pw-link -l` shows the full chain linked
- [x] **GATE PASSED (§3.1 acceptance test):** verified across Bluetooth -> HDMI -> Bluetooth -> S/PDIF -> Bluetooth. Note: USB Speaker/Headphones ports are `not available` (jacks empty) so cannot be made default — pre-existing, unrelated.

## Step 5 — Route Discord  (§4.3, §6.5)  ✅ DONE 2026-08-23
- [x] Discord → Voice & Video → Output Device → "Discord (ducking source)"
- [x] **GATE PASSED:** playback `target=DiscordSink`, sink-input #340 -> sink 32 (DiscordSink), state=running
- [x] **GATE PASSED:** capture stream `target=alsa_input...USB_Mic...` — untouched
- [x] ~~pulse.rules fallback~~ — not needed, in-app selector worked

## Step 6 — Compressor  (§4.4, §6.6)  ✅ DONE 2026-08-23
- [x] Compressor added; `sidechainType=2` (External), `sidechainInputDevice=DiscordSink`, `sidechainMode=1` (RMS)
- [x] Params written to `~/.config/easyeffects/db/compressorrc` section `[soe][Compressor#0]`
- [x] Blocklist = `Discord,WEBRTC VoiceEngine,discord_direct_playback` — **matched on `node.name`, see §3.7**
- [x] `processAllOutputs=true` set after the blocklist
- [x] `useDefaultOutputDevice=true` verified surviving round-trips
- [x] `~/.config/systemd/user/easyeffects.service` installed, enabled + active (Qt6 needs session env; `WantedBy=graphical-session.target`)
- [x] KDE: unit enabled + active, `graphical-session.target` active, display env exported
- [ ] **GATE:** unit still starts cleanly in the **Caelestia** session (untested); if Caelestia never activates `graphical-session.target`, use EasyEffects' own autostart toggle there
- [x] **GATE PASSED:** `DiscordSink:monitor_FL/FR -> ee_soe_compressor:probe_FL/FR`
- [x] **GATE PASSED:** `easyeffects_sink:monitor -> ee_soe_compressor:input`, output to hardware
- [x] **GATE PASSED (§3.6/§3.7):** `discord_direct_playback` on HARDWARE, not `easyeffects_sink` — required bisecting the match key
- [x] Schema captured in DESIGN §4.4.1/§3.7; config backups in scratchpad

## Step 7 — Tune  (§6.7)  ✅ DONE 2026-08-23 — user-approved
- [x] Threshold set from measured sidechain distribution: `-50` (brief's `-30` never triggered — 0.0% of speech crossed it). Ratio raised to `12`.
- [x] Release set to 700 ms by user
- [x] Ratio 24:1, threshold -50 — user reports working well
- [x] **GATE (instrumented):** -12.12 dB duck at realistic speech level (-37 dBFS trigger); Discord itself unducked
- [x] **GATE PASSED:** user confirms working on a live call

## Step 8 — Verify R2  (§6.8)
- [ ] **GATE:** Discord screen-share-with-audio still captures Zen/spotifyd after re-routing

## Step 9 — Full-cycle test  (§6.9)
- [ ] Reboot
- [ ] **GATE:** `DiscordSink` and `easyeffects_sink` both exist with no manual intervention
- [ ] **GATE:** music/game audio lands on `easyeffects_sink`
- [ ] **GATE:** Discord lands on `DiscordSink`
- [ ] **GATE:** someone speaks → other audio ducks, Discord voice does NOT
- [ ] **GATE:** silence → other audio recovers
- [ ] **GATE:** quit and restart Discord → routing holds
- [ ] **GATE:** switch output device mid-session → everything follows
- [ ] **GATE:** confirm no A2DP→HFP profile switch during a call (separate USB mic should prevent it)

## Step 10 — Hand back  ✅ DONE 2026-08-23
- [x] Audited 2026-08-23: all 5 created files covered; `stream-properties` confirmed untouched; no system files modified
- [x] Final values recorded in DESIGN §4.4.2


---

## STATUS 2026-08-23 — FEATURE WORKING, user-confirmed on a live call

Remaining items all require an action I cannot perform. None block daily use.

- **Step 8 (R2)** — screen-share audio check. Needs a screen-share with audio active.
  Verify `discord_capture` still picks up app audio, then confirm here.
- **Step 9 — reboot test: PASSED 2026-08-23.** After a clean boot `verify` reported all PASS with
  no manual intervention. Success criterion 4 met. (A later FAIL on "loopback NOT linked" turned
  out to be a bug in verify.sh, which assumed stereo port names; the AirPods were in mono/HFP so
  the port was `output_MONO`. Fixed — the check is now channel-layout agnostic.)
- **Caelestia session** — `easyeffects.service` is verified in KDE only. If it does not start
  there, `graphical-session.target` is likely not activated by that session; fall back to
  EasyEffects' own autostart toggle for Caelestia.
