#!/usr/bin/env bash
# Health-check the ducking setup. Exit 0 = all good.
set -u
# NOTE: deliberately no 'pipefail'. 'cmd | grep -q' makes grep exit early, the
# producer takes SIGPIPE (141), and pipefail would report a successful match as
# a failure. Link tables are captured once into variables instead.
PASS=0; FAIL=0
ok()   { printf '\033[32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '\033[2m  ..  %s\033[0m\n' "$*"; }

echo "== Discord ducking verification =="

pactl list sinks short 2>/dev/null | grep -q '\bDiscordSink\b' \
  && ok "DiscordSink exists" || bad "DiscordSink missing (PipeWire drop-in not loaded?)"

pactl list sources short 2>/dev/null | grep -q 'DiscordSink.monitor' \
  && ok "DiscordSink.monitor exists" || bad "DiscordSink.monitor missing"

HW="$(pactl get-default-sink 2>/dev/null)"
info "default sink: ${HW:-unknown}"

LINKS="$(pw-link -l 2>/dev/null || true)"

# Channel-layout agnostic: ports are output_FL/output_FR on a stereo sink but
# output_MONO when the sink is mono (e.g. a Bluetooth device in HFP/headset
# profile). Match ANY discord_direct_playback port block against the default sink.
if printf '%s\n' "$LINKS" | awk -v hw="$HW" '
     /^discord_direct_playback:/ { inblk=1; next }
     /^[^[:space:]]/            { inblk=0 }
     inblk && index($0, hw)     { found=1 }
     END                        { exit !found }
   '; then
  ok "loopback follows the default sink"
else
  bad "loopback NOT linked to the default sink"
fi

if printf '%s' "$LINKS" | grep -q 'DiscordSink:monitor'; then
  ok "DiscordSink monitor is linked"
else
  bad "DiscordSink monitor not linked"
fi

if printf '%s' "$LINKS" | grep -q 'ee_soe_compressor:probe'; then
  ok "external sidechain connected (compressor probe ports)"
else
  bad "sidechain NOT connected - compressor will never trigger"
fi

EE_ID="$(pactl list sinks short 2>/dev/null | awk '$2=="easyeffects_sink"{print $1}')"
if [ -n "$EE_ID" ]; then
  ok "easyeffects_sink exists"
  # THE critical one: the loopback must bypass the compressor
  LOOP_SINK="$(pactl list sink-inputs 2>/dev/null \
    | grep -E '^[[:space:]]+Sink:|application.name =' | sed 's/^[[:space:]]*//' | paste - - \
    | grep DiscordDirectOut | grep -oE 'Sink: [0-9]+' | grep -oE '[0-9]+')"
  if [ -z "$LOOP_SINK" ]; then
    info "loopback stream not active yet (no Discord audio) - cannot check self-ducking"
  elif [ "$LOOP_SINK" = "$EE_ID" ]; then
    bad "SELF-DUCKING: discord_direct_playback is on easyeffects_sink. Blocklist must contain 'discord_direct_playback' (matched on node.name)"
  else
    ok "loopback bypasses the compressor (no self-ducking)"
  fi
else
  bad "easyeffects_sink missing - is easyeffects.service running?"
fi

BL="$(grep -E '^blocklist=' ~/.config/easyeffects/db/easyeffectsrc 2>/dev/null || true)"
case "$BL" in
  *discord_direct_playback*) ok "blocklist contains discord_direct_playback" ;;
  *) bad "blocklist missing 'discord_direct_playback' -> self-ducking" ;;
esac
grep -q '^useDefaultOutputDevice=true' ~/.config/easyeffects/db/easyeffectsrc 2>/dev/null \
  && ok "useDefaultOutputDevice=true (follows device switches)" \
  || bad "useDefaultOutputDevice not set - output switching will break the chain"

if pactl list cards 2>/dev/null | grep -q 'Active Profile: headset-head-unit'; then
  printf '\033[33m  WARN\033[0m %s\n' "a Bluetooth device is in HFP/headset profile (mono, ~24 kHz)."
  info "everything still works, but audio quality is poor while it lasts."
  info "WirePlumber switches to HFP when any app opens a capture stream, even if"
  info "that app uses a different microphone. If you always use a separate mic:"
  info "  bluetooth.autoswitch-to-headset-profile = false   in wireplumber.conf.d"
fi

TH="$(grep -E '^threshold=' ~/.config/easyeffects/db/compressorrc 2>/dev/null | cut -d= -f2)"
info "compressor threshold: ${TH:-unset} dB  (calibrate with scripts/measure-sidechain.sh)"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
