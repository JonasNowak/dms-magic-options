#!/usr/bin/env bash
# dms_magic_options backend.
#
#   mouse-config.sh status            -> one JSON line describing the mouse
#   mouse-config.sh battery           -> battery percent, or "unknown"
#   mouse-config.sh apply             -> apply settings from MAGIC_* env vars
#
# Target: Apple Magic Mouse 1 (Bluetooth, USB product 0x030D).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/dms-magic-options-bridge.pid"

# --- Device discovery -------------------------------------------------------

find_hidraw() {
    local d name
    for d in /sys/class/hidraw/hidraw*; do
        [ -d "$d" ] || continue
        name="$(sed -n 's/^HID_NAME=//p' "$d/device/uevent" 2>/dev/null)"
        case "$name" in *"Magic Mouse"*) basename "$d"; return 0;; esac
    done
    return 1
}

find_evdev() {
    local e n dev
    for e in /sys/class/input/event*/device/name; do
        [ -e "$e" ] || continue
        case "$(readlink -f "$(dirname "$e")" 2>/dev/null)" in
            */virtual/input/*) continue;;
        esac
        n="$(cat "$e" 2>/dev/null)"
        case "$n" in
            *"(dms)"*) continue;;
            *"Magic Mouse"*)
                dev="$(dirname "$(dirname "$e")")"
                echo "/dev/input/${dev##*/}"
                return 0;;
        esac
    done
    return 1
}

find_battery() {
    local p m
    for p in /sys/class/power_supply/hid-*-battery-*; do
        [ -d "$p" ] || continue
        m="$(sed -n 's/^POWER_SUPPLY_MODEL_NAME=//p' "$p/uevent" 2>/dev/null)"
        case "$m" in *"Magic Mouse"*) echo "$p"; return 0;; esac
    done
    return 1
}

battery_percent() {
    local p
    if p="$(find_battery)"; then
        cat "$p/capacity" 2>/dev/null && return 0
    fi
    return 1
}

# --- HID feature reports ----------------------------------------------------
# Magic Mouse 1 accepts HID feature reports; the first byte is the report ID.
# The payloads below follow the publicly documented Magic Mouse report layout.
# If the device rejects a report it ignores it, so a wrong entry is harmless;
# adjust the table if your firmware expects different bytes.
REPORT_RIGHT_CLICK_TWO_FINGER="01 02 01"   # two-finger click reported as right button
REPORT_RIGHT_CLICK_OFF="01 02 00"

hid_feature() {
    # $1 = hidraw node name (e.g. hidraw2), $2 = hex bytes, report ID first
    local dev="/dev/$1" hex="$2" bytes
    bytes="$(echo "$hex" | sed 's/\([0-9a-fA-F]\{2\}\)/\\x\1/g')"
    if [ -w "$dev" ]; then
        printf "$bytes" > "$dev" 2>/dev/null && return 0
        return 1
    fi
    # Node is root-owned: retry through pkexec. No timeout here - the polkit
    # auth dialog must stay open until the user enters the password or cancels.
    printf "$bytes" | pkexec "$(command -v dd)" of="$dev" bs=1 conv=notrunc 2>/dev/null
}

# --- Gesture bridge ---------------------------------------------------------

bridge_running() {
    [ -f "$BRIDGE_PIDFILE" ] && kill -0 "$(cat "$BRIDGE_PIDFILE")" 2>/dev/null
}

bridge_stop() {
    if bridge_running; then
        local pid i
        pid="$(cat "$BRIDGE_PIDFILE")"
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.05
        done
    fi
    rm -f "$BRIDGE_PIDFILE"
}

bridge_wanted() {
    # The input bridge is needed for right-click remapping, tap-to-click,
    # custom scroll speed, and swipe gestures; without any of them the raw
    # device is left alone.
    [ "${MAGIC_RIGHT_CLICK:-twoFinger}" != "off" ] && return 0
    [ "${MAGIC_TAP_TO_CLICK:-0}" = "1" ] && return 0
    [ "${MAGIC_SCROLL_SPEED:-100}" != "100" ] && return 0
    [ "${MAGIC_TWO_FINGER_SWIPE:-backForward}" = "backForward" ] && return 0
    if [ "${MAGIC_GESTURES:-1}" = "1" ]; then
        [ "${MAGIC_THREE_FINGER:-off}" != "off" ] && return 0
        [ "${MAGIC_FOUR_FINGER:-off}" != "off" ] && return 0
    fi
    return 1
}

bridge_start() {
    local evdev
    evdev="$(find_evdev)" || return 1
    bridge_stop
    MAGIC_EVDEV="$evdev" \
    MAGIC_RIGHT_CLICK="${MAGIC_RIGHT_CLICK:-twoFinger}" \
    MAGIC_TAP_TO_CLICK="${MAGIC_TAP_TO_CLICK:-0}" \
    MAGIC_SCROLL_SPEED="${MAGIC_SCROLL_SPEED:-100}" \
    MAGIC_TWO_FINGER_SWIPE="${MAGIC_TWO_FINGER_SWIPE:-backForward}" \
    MAGIC_THREE_FINGER="${MAGIC_THREE_FINGER:-off}" \
    MAGIC_FOUR_FINGER="${MAGIC_FOUR_FINGER:-off}" \
        nohup python3 "$SCRIPT_DIR/input-bridge.py" >/dev/null 2>&1 &
    echo $! > "$BRIDGE_PIDFILE"
}

# --- Commands ---------------------------------------------------------------

cmd_status() {
    local hr ev bat writable=false connected=false
    local j_hr="null" j_ev="null" j_bat="null"
    hr="$(find_hidraw)" || hr=""
    ev="$(find_evdev)" || ev=""
    bat="$(battery_percent)" || bat=""
    [ -n "$hr" ] && connected=true
    [ -n "$hr" ] && [ -w "/dev/$hr" ] && writable=true
    [ -n "$hr" ] && j_hr="\"/dev/$hr\""
    [ -n "$ev" ] && j_ev="\"$ev\""
    [ -n "$bat" ] && j_bat="$bat"
    printf '{"connected":%s,"hidraw":%s,"evdev":%s,"battery":%s,"hidrawWritable":%s}\n' \
        "$connected" "$j_hr" "$j_ev" "$j_bat" "$writable"
}

cmd_apply() {
    local hr
    # Debug trail: every apply records the effective settings.
    { echo "$(date +%T) apply right=${MAGIC_RIGHT_CLICK:-twoFinger} tap=${MAGIC_TAP_TO_CLICK:-0} speed=${MAGIC_SCROLL_SPEED:-100} 2swipe=${MAGIC_TWO_FINGER_SWIPE:-backForward} three=${MAGIC_THREE_FINGER:-off} four=${MAGIC_FOUR_FINGER:-off} gestures=${MAGIC_GESTURES:-1}"; } \
        >> "${XDG_RUNTIME_DIR:-/tmp}/dms-magic-options-apply.log"
    hr="$(find_hidraw)" || hr=""
    if [ -n "$hr" ]; then
        case "${MAGIC_RIGHT_CLICK:-twoFinger}" in
            twoFinger|twoFingerTap) hid_feature "$hr" "$REPORT_RIGHT_CLICK_TWO_FINGER" ;;
            off)                    hid_feature "$hr" "$REPORT_RIGHT_CLICK_OFF" ;;
        esac
    fi
    if bridge_wanted; then
        bridge_start || true
    else
        bridge_stop
    fi
}

case "${1:-}" in
    status)  cmd_status ;;
    battery) battery_percent || echo unknown ;;
    apply)   cmd_apply ;;
    *) echo "usage: $0 {status|battery|apply}" >&2; exit 2 ;;
esac
