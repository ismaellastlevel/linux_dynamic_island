#!/bin/bash
# Runs the extension in a throwaway headless GNOME Shell (own D-Bus, settings and
# runtime dir, so the real session is untouched) and checks the main features.
# Usage: tests/run-headless.sh   -> prints PASS/FAIL lines, exit code = number of failures
set -u
UUID=dynamic-island@bjagetic
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")

if [ -z "${DI_TMP:-}" ]; then
    DI_TMP=$(mktemp -d)
    export DI_TMP
    mkdir -p "$DI_TMP/data/gnome-shell/extensions/unsafe@test" "$DI_TMP/config" "$DI_TMP/cache" "$DI_TMP/run"
    chmod 700 "$DI_TMP/run"
    gnome-extensions pack --force --extra-source=island.js --extra-source=sources --extra-source=icons \
        -o "$DI_TMP" "$REPO" >/dev/null || exit 1
    unzip -q "$DI_TMP/$UUID.shell-extension.zip" -d "$DI_TMP/data/gnome-shell/extensions/$UUID"
    glib-compile-schemas "$DI_TMP/data/gnome-shell/extensions/$UUID/schemas"
    # Helper extension: unsafe mode unlocks Eval/ShowOSD/Screenshot on the test bus only
    major=$(gnome-shell --version | grep -o '[0-9]\+' | head -1)
    echo "{\"uuid\":\"unsafe@test\",\"name\":\"unsafe\",\"description\":\"test\",\"shell-version\":[\"$major\"]}" \
        > "$DI_TMP/data/gnome-shell/extensions/unsafe@test/metadata.json"
    echo 'export default class { enable() { global.context.unsafe_mode = true; } disable() {} }' \
        > "$DI_TMP/data/gnome-shell/extensions/unsafe@test/extension.js"
    exec env -u WAYLAND_DISPLAY -u DISPLAY XDG_DATA_HOME="$DI_TMP/data" XDG_CONFIG_HOME="$DI_TMP/config" \
        XDG_CACHE_HOME="$DI_TMP/cache" XDG_RUNTIME_DIR="$DI_TMP/run" dbus-run-session -- "$0" 2>"$DI_TMP/bus.log"
fi

# --- inside the private session bus ---
gsettings set org.gnome.shell enabled-extensions "['unsafe@test', '$UUID']"
gnome-shell --headless --virtual-monitor 1280x720 --wayland --no-x11 --wayland-display di-test \
    >"$DI_TMP/shell.log" 2>&1 &
SHELL_PID=$!
trap 'kill $SHELL_PID $MOCK_PID 2>/dev/null' EXIT
MOCK_PID=

ev() {
    gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval "$1" 2>/dev/null | sed -E "s/^\(true, '(.*)'\)$/\1/"
}
for _ in $(seq 60); do [ "$(ev "!!Main.extensionManager.lookup('$UUID')?.stateObj")" = true ] && break; sleep 0.5; done

FAILS=0
check() { # name, js expression that must be true
    if [ "$(ev "$2")" = true ]; then echo "PASS $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}
EXT="Main.extensionManager.lookup('$UUID')"
ISLAND="$EXT?.stateObj?._island"
NO_SHELL_OSD="!Main.osdWindowManager._osdWindows.some(w => w.visible)"
screenshot() {
    gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Screenshot \
        --method org.gnome.Shell.Screenshot.Screenshot false false "$DI_TMP/$1.png" >/dev/null
}

check "extension loads" "!!$ISLAND && !$EXT.error"

# Volume: GNOME 47+ calls showAll(icon, null, level, maxLevel)
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.ShowOSD \
    "{'icon': <'audio-volume-medium-symbolic'>, 'level': <0.5>}" >/dev/null
sleep 0.5
screenshot volume
check "volume shows on the island" "$ISLAND._toastActive && $ISLAND._toastBar.visible && Math.abs($ISLAND._toastFill.width - 85) < 2"
check "volume hides the shell OSD" "$NO_SHELL_OSD"

# Brightness: gsd sends it per monitor, GNOME 47+ calls showOne(monitor, icon, label, level, maxLevel)
ev "Main.osdWindowManager.showOne(0, new Gio.ThemedIcon({name: 'display-brightness-symbolic'}), null, 0.3, 1)" >/dev/null
sleep 0.5
check "brightness shows on the island" "$ISLAND._toastIcon.gicon.get_names()[0] === 'display-brightness-symbolic' && Math.abs($ISLAND._toastFill.width - 51) < 2"
check "brightness hides the shell OSD" "$NO_SHELL_OSD"

# Music
WAYLAND_DISPLAY=di-test python3 -I -W ignore "$HERE/mock_mpris.py" 'Test Song' 'Test Artist' --window &
MOCK_PID=$!
sleep 3
screenshot music
check "music shows on the island" "$ISLAND._hasMusic && $ISLAND._title.text === 'Test Song'"
check "visualizer animates" "$ISLAND._eqTimeline.is_playing()"
# Like Chrome, the mock can't raise itself (no DesktopEntry, CanRaise false)
FOCUS="global.display.focus_window?.get_title()"
ev "Main.activateWindow(global.display.list_all_windows().find(w => w.get_title() === 'Other tab - Mock Browser'))" >/dev/null
sleep 0.5
check "another tab has the focus" "$FOCUS === 'Other tab - Mock Browser'"
ev "$ISLAND._focusPlayer()" >/dev/null; sleep 0.5
check "click focuses the window playing the track" "$FOCUS === 'Test Song - Mock Browser'"
kill $MOCK_PID; MOCK_PID=; sleep 1
check "player quit clears the island" "!$ISLAND._hasMusic && $ISLAND._player === null"

# Disable must give the OSD back to the shell; enable again must work (lock screen does this)
gnome-extensions disable "$UUID"; sleep 0.5
check "disable restores the shell OSD" "['show', 'showOne', 'showAll'].every(m => Main.osdWindowManager[m] === Object.getPrototypeOf(Main.osdWindowManager)[m])"
gnome-extensions enable "$UUID"; sleep 0.5
check "enable again works" "!!$ISLAND && !$EXT.error"

ERRORS=$(grep -c -E 'JS ERROR|clutter_timeline_start' "$DI_TMP/shell.log")
if [ "$ERRORS" = 0 ]; then echo "PASS no JS errors in the shell log"; else echo "FAIL $ERRORS JS errors in the shell log"; FAILS=$((FAILS + 1)); fi
grep -i -E "dynamic.island|$UUID" "$DI_TMP/shell.log" | grep -v -i 'cover download' | sed 's/^/LOG /'
echo "Screenshots and shell log: $DI_TMP"
exit $FAILS
