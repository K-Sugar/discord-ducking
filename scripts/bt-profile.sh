#!/usr/bin/env bash
# Switch a Bluetooth audio device between high-quality playback (A2DP) and
# headset mode (HSP/HFP, which enables its microphone but drops audio to mono
# ~24 kHz).
#
# WHY: WirePlumber's autoswitch flips to headset mode whenever an app opens a
# capture stream. If you normally use a separate mic, that silently ruins your
# playback quality during calls. Disabling autoswitch entirely would make the
# headset mic unavailable, so this gives explicit control instead.
#
# usage: bt-profile.sh [status|mic-on|mic-off] [card]
set -euo pipefail

action="${1:-status}"
card="${2:-}"

# find the bluez card if not given
if [ -z "$card" ]; then
  card="$(pactl list cards short 2>/dev/null | awk '$2 ~ /^bluez_card\./ {print $2; exit}')"
fi
[ -n "$card" ] || { echo "No Bluetooth audio device found." >&2; exit 1; }

profiles() { pactl list cards 2>/dev/null | sed -n "/Name: $card\$/,/^Card #/p"; }
active()   { profiles | grep -m1 'Active Profile:' | sed 's/.*Active Profile: *//'; }
# Available PROFILE names, best-priority first as pactl lists them.
# Profile lines carry a "(sinks: N, sources: N" suffix; port lines do not.
# Without that filter, ports such as 'headphone-input' get mistaken for profiles.
avail()    { profiles | grep -E '\(sinks: [0-9]+, sources: [0-9]+' \
                      | sed -E 's/^[[:space:]]*([^:]+):.*/\1/' ; }

pick() { # pick first available profile matching a pattern
  local pat="$1" p
  while read -r p; do case "$p" in $pat) echo "$p"; return 0;; esac; done < <(avail)
  return 1
}

case "$action" in
  status)
    echo "card:   $card"
    echo "active: $(active)"
    echo "available profiles:"; avail | sed 's/^/  /'
    case "$(active)" in
      a2dp*) echo; echo "-> high-quality playback. Bluetooth mic NOT available." ;;
      headset*) echo; echo "-> headset mode: mic available, playback is mono and low bandwidth." ;;
    esac
    if ! pick 'a2dp*' >/dev/null; then
      echo
      echo "NOTE: no A2DP profile is currently offered by this device."
      echo "      It connected in headset mode. Disconnect and reconnect it"
      echo "      (ideally with no app recording) to get A2DP back."
    fi
    ;;
  mic-off|a2dp)
    if ! p="$(pick 'a2dp*')"; then
      echo "A2DP is not available on '$card' right now." >&2
      echo "The device connected in headset mode. Reconnect it - see 'status'." >&2
      exit 1
    fi
    pactl set-card-profile "$card" "$p"
    echo "switched to $p (high-quality playback, no Bluetooth mic)"
    ;;
  mic-on|headset)
    p="$(pick 'headset*')" || { echo "No headset profile available on '$card'." >&2; exit 1; }
    pactl set-card-profile "$card" "$p"
    echo "switched to $p (Bluetooth mic available, playback mono/low bandwidth)"
    ;;
  *) echo "usage: $(basename "$0") [status|mic-on|mic-off] [card]" >&2; exit 1 ;;
esac
