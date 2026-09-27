#!/usr/bin/env bash
# frame-linux-fix
# Fixes for the Steam Frame on desktop Linux:
#   1. Wireless adapter driver (morrownr/rtw89 via DKMS, newer firmware,
#      Wi-Fi region for 6 GHz, USB power saving off)
#   2. VR helper: starts SteamVR when a VR game is launched from the headset
#      without it, and closes the game and SteamVR together
#
# Usage: ./frame-linux-fix.sh [install|repair|uninstall|status]
# Run as your normal user. It asks for your password when it needs root.

set -u

NAME="frame-linux-fix"
VERSION="1.5"
DONGLE_USB="28de:2432"
REPO_URL="https://github.com/morrownr/rtw89"
STEAMVR_ID=250820

STATE_DIR="/var/lib/$NAME"
STATE_FILE="$STATE_DIR/state"
DRIVER_SRC="$STATE_DIR/rtw89"
FW_DIR="/lib/firmware/rtw89"
FW_BACKUP="$STATE_DIR/firmware-backup"
MODPROBE_DRIVER="/etc/modprobe.d/rtw89.conf"
MODPROBE_REGION="/etc/modprobe.d/$NAME-region.conf"
UDEV_RULE="/etc/udev/rules.d/50-steam-frame-dongle.rules"

HELPER="$HOME/.local/bin/frame-vr-helper.sh"
AUTOSTART="$HOME/.config/autostart/frame-vr-helper.desktop"
HELPER_LOG="$HOME/.local/state/frame-vr-helper.log"
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"

REBOOT_NEEDED=0

# ---------- output ----------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
say()  { echo; echo "${B}==> $*${N}"; }
ok()   { echo "  ${G}ok${N}    $*"; }
warn() { echo "  ${Y}warn${N}  $*"; }
bad()  { echo "  ${R}fail${N}  $*"; }
info() { echo "        $*"; }
die()  { echo "${R}error:${N} $*" >&2; exit 1; }
ask()  { local a; read -rp "  $1 [y/N] " a; [[ $a =~ ^[Yy] ]]; }

# ---------- state ----------
state_get() { grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
state_set() {
  sudo mkdir -p "$STATE_DIR"
  sudo touch "$STATE_FILE"
  sudo sed -i "/^$1=/d" "$STATE_FILE"
  echo "$1=$2" | sudo tee -a "$STATE_FILE" >/dev/null
}

# ---------- detection ----------
find_steam_root() {
  local d best="" bt=0 t
  for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -d "$d/steamapps" ] || continue
    d=$(readlink -f "$d")
    t=$(stat -c %Y "$d/logs/console-linux.txt" 2>/dev/null || echo 1)
    if [ "$t" -gt "$bt" ]; then best=$d; bt=$t; fi
  done
  echo "$best"
}

steam_libraries() {
  local root=$1
  { echo "$root/steamapps"
    grep -oP '"path"\s+"\K[^"]+' "$root/steamapps/libraryfolders.vdf" 2>/dev/null | sed 's|$|/steamapps|'
  } | while read -r d; do [ -d "$d" ] && readlink -f "$d"; done | sort -u
}

app_name() {
  local lib f
  while read -r lib; do
    f="$lib/appmanifest_$2.acf"
    if [ -f "$f" ]; then grep -oP '"name"\s+"\K[^"]+' "$f" | head -1; return; fi
  done < <(steam_libraries "$1")
}

app_installed() { [ -n "$(app_name "$1" "$2")" ]; }

vr_games() {
  grep -oP 'steam\.app\.\K[0-9]+' "$1/config/steamapps.vrmanifest" 2>/dev/null \
    | sort -un | grep -vx "$STEAMVR_ID"
}

kernel_at_least() {
  local k; k=$(uname -r | cut -d- -f1)
  [ "$(printf '%s\n%s\n' "$1" "$k" | sort -V | head -1)" = "$1" ]
}

secure_boot() {
  command -v mokutil >/dev/null || { echo unknown; return; }
  if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then echo enabled; else echo disabled; fi
}

dkms_versions() {
  command -v dkms >/dev/null || return
  dkms status rtw89 2>/dev/null | grep -oP '^rtw89/\K[^,:]+' | sort -u
}

dongle_present() { lsusb -d "$DONGLE_USB" >/dev/null 2>&1; }
dongle_speed()   { lsusb -t 2>/dev/null | grep -m1 'Driver=rtw89_8852cu' | grep -oE '[0-9]+M$'; }

driver_in_use() {
  if lsmod | grep -q '^rtw89_8852cu_git'; then echo "out-of-tree (morrownr)"
  elif lsmod | grep -q '^rtw89_8852cu '; then echo "in-kernel"
  else echo "not loaded"; fi
}

firmware_loaded() {
  journalctl -k -b 2>/dev/null | grep -oP 'rtw89_8852cu.*Firmware version \K[0-9.]+' | tail -1
}

current_region() { iw reg get 2>/dev/null | awk '/^global/{getline; sub(":","",$2); print $2; exit}'; }

helper_running() { pgrep -f "$HELPER" >/dev/null; }

# ---------- driver ----------
install_deps() {
  say "Build tools"
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq git build-essential dkms "linux-headers-$(uname -r)" iw usbutils mokutil \
      || die "package install failed"
  else
    local m="" c
    for c in git make gcc dkms; do command -v "$c" >/dev/null || m="$m $c"; done
    [ -d "/lib/modules/$(uname -r)/build" ] || m="$m kernel-headers-for-$(uname -r)"
    [ -n "$m" ] && die "missing:$m
This script only installs packages on apt-based distros (Mint, Ubuntu, Debian, Pop!_OS).
Install those with your package manager, then run it again."
  fi
  ok "ready"
}

handle_secure_boot() {
  [ "$(secure_boot)" = enabled ] || return
  local key=""
  for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
    [ -f "$k" ] && { key=$k; break; }
  done
  if [ -z "$key" ]; then
    warn "Secure Boot is on but no DKMS signing key was found. The driver will not load."
    info "Turn Secure Boot off in your BIOS, or set up DKMS module signing for your distro."
    return
  fi
  if mokutil --test-key "$key" 2>/dev/null | grep -q "already enrolled"; then
    ok "Secure Boot signing key already enrolled"
    return
  fi
  say "Secure Boot key enrollment"
  info "Secure Boot is on, so the driver's signing key has to be enrolled."
  info "Pick a short one-time password now. On the next reboot a blue"
  info "'MOK management' screen appears: Enroll MOK > Continue > Yes,"
  info "type the same password, then Reboot."
  sudo mokutil --import "$key" || warn "key import failed, the driver will not load with Secure Boot on"
}

install_driver() {
  say "Wireless adapter driver"
  if kernel_at_least 7.2; then
    warn "kernel $(uname -r) may already include Valve's adapter fixes"
    ask "Install the out-of-tree driver anyway?" || { ok "skipped"; return; }
  fi
  install_deps

  say "Downloading driver source"
  sudo mkdir -p "$STATE_DIR"
  if [ -d "$DRIVER_SRC/.git" ]; then
    sudo git -C "$DRIVER_SRC" pull -q --ff-only || warn "could not update source, using the copy already here"
  else
    sudo rm -rf "$DRIVER_SRC"
    sudo git clone -q --depth 1 "$REPO_URL" "$DRIVER_SRC" || die "could not download $REPO_URL"
  fi
  local v old
  v=$(grep -oP 'PACKAGE_VERSION="?\K[^"]+' "$DRIVER_SRC/dkms.conf")
  [ -n "$v" ] || die "could not read driver version from dkms.conf"
  ok "rtw89 $v"

  # Back up firmware once, before anything touches it
  if [ -z "$(state_get fw_backup)" ] && [ -d "$FW_DIR" ]; then
    sudo rm -rf "$FW_BACKUP"
    sudo cp -a "$FW_DIR" "$FW_BACKUP"
    if [ -z "$(dkms_versions)" ]; then
      state_set fw_backup clean
    else
      state_set fw_backup dirty
      warn "an rtw89 DKMS driver was already installed before this script"
      info "uninstall will reinstall firmware from your distro packages instead of this backup"
    fi
  fi

  for old in $(dkms_versions); do
    sudo dkms remove "rtw89/$old" --all >/dev/null 2>&1
    sudo rm -rf "/usr/src/rtw89-$old"
  done

  say "Building driver (a few minutes)"
  sudo dkms install "$DRIVER_SRC" >/dev/null \
    || die "driver build failed, see /var/lib/dkms/rtw89/$v/build/make.log"
  dkms status "rtw89/$v" 2>/dev/null | grep -q "$(uname -r).*installed" \
    || die "driver did not install for kernel $(uname -r)"
  ok "built and installed for $(uname -r), rebuilds automatically on kernel updates"

  sudo make -s -C "$DRIVER_SRC" install_fw >/dev/null || die "firmware install failed"
  ok "firmware updated"
  sudo cp "$DRIVER_SRC/rtw89.conf" "$MODPROBE_DRIVER"
  ok "in-kernel rtw89 drivers blacklisted ($MODPROBE_DRIVER)"
  state_set driver "$v"

  handle_secure_boot
  REBOOT_NEEDED=1
}

install_region() {
  say "Wi-Fi region (6 GHz is blocked without one)"
  local f cur guess code
  f=$(grep -rls 'ieee80211_regdom' /etc/modprobe.d 2>/dev/null | grep -v "$MODPROBE_REGION" | head -1)
  if [ -n "$f" ]; then
    ok "already set in $f, leaving it"
    return
  fi
  if [ -f "$MODPROBE_REGION" ]; then
    guess=$(grep -oP 'regdom=\K[A-Z]{2}' "$MODPROBE_REGION")
  else
    cur=$(current_region)
    guess=$cur
    if [ -z "$guess" ] || [ "$guess" = "00" ]; then
      guess=$(echo "${LC_ALL:-${LANG:-}}" | grep -oP '^[a-z]+_\K[A-Z]{2}')
    fi
  fi
  guess=${guess:-US}
  while :; do
    read -rp "  Two-letter country code [$guess]: " code
    code=${code:-$guess}; code=${code^^}
    [[ $code =~ ^[A-Z]{2}$ ]] && break
    info "two letters, like US, GB, DE, CA"
  done
  echo "options cfg80211 ieee80211_regdom=$code" | sudo tee "$MODPROBE_REGION" >/dev/null
  sudo iw reg set "$code" 2>/dev/null
  ok "region $code ($MODPROBE_REGION)"
}

install_udev() {
  say "USB power saving off for the adapter"
  echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="28de", ATTR{idProduct}=="2432", ATTR{power/control}="on"' \
    | sudo tee "$UDEV_RULE" >/dev/null
  sudo udevadm control --reload
  sudo udevadm trigger --action=add --attr-match=idVendor=28de --attr-match=idProduct=2432 2>/dev/null
  ok "$UDEV_RULE"
}

restore_firmware() {
  if [ "$(state_get fw_backup)" = clean ] && [ -d "$FW_BACKUP" ]; then
    sudo rm -rf "$FW_DIR"
    sudo cp -a "$FW_BACKUP" "$FW_DIR"
    ok "firmware restored from backup"
    return
  fi
  if ! command -v dpkg >/dev/null; then
    warn "could not restore firmware automatically, reinstall your linux-firmware package"
    return
  fi
  local pkgs f
  pkgs=$(dpkg -S "$FW_DIR" 2>/dev/null | cut -d: -f1 | tr ',' '\n' | tr -d ' ' | sort -u)
  if [ -z "$pkgs" ]; then
    warn "no package owns $FW_DIR, leaving firmware as is"
    return
  fi
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq --reinstall $pkgs >/dev/null && ok "firmware reinstalled from: $(echo $pkgs)"
  for f in "$FW_DIR"/*; do
    dpkg -S "$f" >/dev/null 2>&1 || sudo rm -f "$f"
  done
}

# ---------- helper ----------
write_helper() {
  mkdir -p "$(dirname "$HELPER")"
  cat > "$HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
# frame-vr-helper (installed by frame-linux-fix)
# When a VR game starts while the Steam Frame is connected and SteamVR is not
# running: close the game and start SteamVR. Launch the game again from the headset.
# When the game exits, quit SteamVR. When SteamVR exits, close the game.
# Log: ~/.local/state/frame-vr-helper.log

STEAMVR_ID=250820
GRACE_ADAPTER=10   # seconds the headset stream can be gone before closing, wireless adapter
GRACE_WIFI=20      # same, streaming over home Wi-Fi
LOG="$HOME/.local/state/frame-vr-helper.log"
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"

# Own process group so everything can be stopped together
if [ "$(ps -o pgid= $$ | tr -d ' ')" != "$$" ]; then exec setsid bash "$(readlink -f "$0")" "$@"; fi
exec 9>"$RUNDIR/frame-vr-helper.lock"
flock -n 9 || exit 0
echo $$ > "$RUNDIR/frame-vr-helper.pid"

mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1000000 ]; then mv "$LOG" "$LOG.old"; fi
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

find_steam_root() {
  local d best="" bt=0 t
  for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -d "$d/steamapps" ] || continue
    d=$(readlink -f "$d")
    t=$(stat -c %Y "$d/logs/console-linux.txt" 2>/dev/null || echo 1)
    if [ "$t" -gt "$bt" ]; then best=$d; bt=$t; fi
  done
  echo "$best"
}

STEAM=$(find_steam_root)
if [ -z "$STEAM" ]; then log "Steam folder not found, exiting"; exit 1; fi
CON="$STEAM/logs/console-linux.txt"
RC="$STEAM/logs/remote_connections.txt"
VRLOG="$STEAM/logs/vrserver.txt"
VRMAN="$STEAM/config/steamapps.vrmanifest"
VRSET="$STEAM/config/steamvr.vrsettings"

steam_url() {
  if command -v steam >/dev/null; then
    steam "$1"
  elif command -v flatpak >/dev/null && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    flatpak run com.valvesoftware.Steam "$1"
  else
    xdg-open "$1"
  fi >/dev/null 2>&1 &
}

is_vr_game() {
  [ "$1" != "$STEAMVR_ID" ] && grep -qE "steam\.app\.$1\"" "$VRMAN" 2>/dev/null
}

headset_connected() {
  local id pat
  id=$(grep -oP '"RemoteClientID"\s*:\s*"\K[0-9]+' "$VRSET" 2>/dev/null)
  pat='Client [0-9]+ \(.*\) (connected|disconnected)'
  [ -n "$id" ] && pat="Client $id \(.*\) (connected|disconnected)"
  grep -E "$pat" "$RC" 2>/dev/null | tail -1 | grep -q 'connected via'
}

steamvr_running() { pgrep -x vrserver >/dev/null; }

# Steam names the adapter's connection "Steam Frame Wireless Adapter"
adapter_in_use() {
  nmcli -t -f STATE,CONNECTION device 2>/dev/null | grep -q '^connected:Steam Frame Wireless Adapter$'
}

reaper_pid() { pgrep -f "SteamLaunch AppId=$1( |$)" | head -1; }

descendants() {
  local c
  for c in $(pgrep -P "$1"); do descendants "$c"; echo "$c"; done
}

kill_game() {
  local r
  r=$(reaper_pid "$1")
  [ -z "$r" ] && return
  log "closing game $1"
  kill -TERM $(descendants "$r") "$r" 2>/dev/null
  for _ in {1..10}; do kill -0 "$r" 2>/dev/null || return; sleep 1; done
  kill -KILL $(descendants "$r") "$r" 2>/dev/null
}

quit_steamvr() {
  local p
  steamvr_running || return
  log "quitting SteamVR"
  pkill -TERM -x vrmonitor
  for _ in {1..15}; do steamvr_running || return; sleep 1; done
  log "SteamVR did not quit, force closing"
  for p in vrserver vrcompositor vrmonitor vrdashboard vrwebhelper; do pkill -KILL -x "$p"; done
}

start_steamvr() {
  log "starting SteamVR, launch the game again from the headset"
  steam_url "steam://rungameid/$STEAMVR_ID"
}

close_both() {
  log "$2"
  kill_game "$1"
  quit_steamvr
}

watch_game() {
  local id=$1 r offset size new inactive_at=0 GRACE
  for _ in {1..60}; do r=$(reaper_pid "$id"); [ -n "$r" ] && break; sleep 1; done
  if [ -z "$r" ]; then log "game $id never started"; return; fi
  if adapter_in_use; then GRACE=$GRACE_ADAPTER; else GRACE=$GRACE_WIFI; fi
  # only read vrserver.txt lines written after this point
  offset=$(stat -c %s "$VRLOG" 2>/dev/null || echo 0)
  log "watching game $id (closes ${GRACE}s after the headset stream stops)"
  while :; do
    if ! kill -0 "$r" 2>/dev/null; then
      log "game $id closed, closing SteamVR"
      sleep 3
      quit_steamvr
      return
    fi
    if ! steamvr_running; then
      log "SteamVR closed, closing game $id"
      kill_game "$id"
      return
    fi

    size=$(stat -c %s "$VRLOG" 2>/dev/null || echo 0)
    [ "$size" -lt "$offset" ] && offset=0
    new=$(tail -c +$((offset + 1)) "$VRLOG" 2>/dev/null | head -c $((size - offset)))
    offset=$size

    if grep -q "NoMoreSceneAppTransition because steam.app.$id exited" <<<"$new"; then
      close_both "$id" "game $id left VR, closing game and SteamVR"
      return
    fi

    # Stop from the headset only ends the headset's stream. The game and
    # SteamVR keep running. Wait a bit in case it is just a Wi-Fi drop.
    if [ "$inactive_at" = 0 ]; then
      if grep -q 'vrlink: Connection inactive' <<<"$new"; then
        inactive_at=$(date +%s)
        log "headset stream stopped, closing in ${GRACE}s unless it comes back"
      fi
    elif grep -qE 'vrlink: Connection (active|established|resumed)|vrlink: .*[Rr]econnect' <<<"$new"; then
      inactive_at=0
      log "headset stream came back, keeping game open"
    elif [ $(( $(date +%s) - inactive_at )) -ge "$GRACE" ]; then
      close_both "$id" "headset gone for ${GRACE}s, closing game and SteamVR"
      return
    fi
    sleep 2
  done
}

log "started (Steam: $STEAM)"
WATCH_PID=""
IGNORE_ID=""
IGNORE_UNTIL=0
tail -n0 -F "$CON" 2>/dev/null | while read -r line; do
  [[ $line =~ Adding\ process\ [0-9]+\ for\ gameID\ ([0-9]+) ]] || continue
  id=${BASH_REMATCH[1]}
  is_vr_game "$id" || continue
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then continue; fi

  if ! steamvr_running; then
    # skip leftover log lines from a launch we just closed
    if [ "$id" = "$IGNORE_ID" ] && [ "$(date +%s)" -lt "$IGNORE_UNTIL" ]; then continue; fi
    if ! headset_connected; then
      log "VR game $id started without the headset connected, leaving it alone"
      continue
    fi
    log "VR game $id started before SteamVR, closing it"
    kill_game "$id"
    IGNORE_ID=$id
    IGNORE_UNTIL=$(( $(date +%s) + 20 ))
    start_steamvr
    continue
  fi

  watch_game "$id" &
  WATCH_PID=$!
done
HELPER_EOF
  chmod +x "$HELPER"
}

stop_helper() {
  local p
  p=$(cat "$RUNDIR/frame-vr-helper.pid" 2>/dev/null)
  [ -n "$p" ] && kill -- -"$p" 2>/dev/null
  pkill -f "$HELPER" 2>/dev/null
  rm -f "$RUNDIR/frame-vr-helper.pid"
  sleep 1
}

install_helper() {
  say "VR helper (starts SteamVR when needed, closes game and SteamVR together)"
  local root; root=$(find_steam_root)
  if [ -z "$root" ]; then
    warn "Steam folder not found. The helper is installed but does nothing until Steam is set up."
  else
    app_installed "$root" "$STEAMVR_ID" || warn "SteamVR is not installed in Steam yet"
  fi
  stop_helper
  write_helper
  mkdir -p "$(dirname "$AUTOSTART")"
  cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Frame VR Helper
Comment=Installed by $NAME
Exec=$HELPER
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  setsid -f "$HELPER" >/dev/null 2>&1
  sleep 1
  if helper_running; then ok "installed and running, starts on login"
  else bad "installed but did not start, check $HELPER_LOG"; fi
}

# ---------- actions ----------
preflight() {
  say "Checking system"
  . /etc/os-release 2>/dev/null
  ok "${PRETTY_NAME:-unknown distro}, kernel $(uname -r)"
  ok "Secure Boot: $(secure_boot)"
  if dongle_present; then
    ok "wireless adapter found"
  else
    warn "wireless adapter not plugged in. That's fine, the driver still installs."
  fi
  local root; root=$(find_steam_root)
  [ -n "$root" ] && ok "Steam: $root" || warn "Steam folder not found"
  sudo -v || die "need sudo"
}

finish() {
  say "Done"
  if [ "$REBOOT_NEEDED" = 1 ]; then
    info "Reboot to load the new driver."
    info "Plug the adapter into a USB 3 port on the back of the PC, directly on the motherboard."
  fi
  info "Check everything any time with: $0 status"
}

do_install() {
  preflight
  install_driver
  install_region
  install_udev
  install_helper
  finish
}

do_uninstall() {
  say "Uninstall"
  info "Removes the adapter driver, its firmware changes, the region setting,"
  info "the USB rule and the VR helper. Build tools (git, dkms, headers) stay."
  ask "Continue?" || exit 0
  sudo -v || die "need sudo"

  say "VR helper"
  stop_helper
  rm -f "$HELPER" "$AUTOSTART" "$HELPER_LOG" "$HELPER_LOG.old" "$RUNDIR/frame-vr-helper.lock"
  ok "removed"

  say "Adapter driver"
  local v
  for v in $(dkms_versions); do
    sudo dkms remove "rtw89/$v" --all >/dev/null 2>&1
    sudo rm -rf "/usr/src/rtw89-$v"
    ok "removed rtw89/$v"
  done
  sudo rm -f "$MODPROBE_DRIVER"
  restore_firmware
  sudo rm -f "$MODPROBE_REGION" "$UDEV_RULE"
  sudo udevadm control --reload
  sudo rm -rf "$STATE_DIR"
  sudo depmod -a
  ok "removed, your kernel's own driver is back in use after reboot"

  if [ -n "$(grep -rls 'ieee80211_regdom' /etc/modprobe.d 2>/dev/null)" ]; then
    info "A Wi-Fi region setting not made by this script is still in:"
    grep -rls 'ieee80211_regdom' /etc/modprobe.d | sed 's/^/          /'
  fi
  REBOOT_NEEDED=1
  say "Done"
  info "Reboot to finish."
}

do_status() {
  local root v sp fw id
  . /etc/os-release 2>/dev/null
  say "System"
  info "${PRETTY_NAME:-unknown}, kernel $(uname -r)"
  info "Secure Boot: $(secure_boot)"
  kernel_at_least 7.2 && info "Kernel is 7.2 or newer, it may include the adapter fix. Try uninstalling the driver part."

  say "Wireless adapter"
  if dongle_present; then
    ok "plugged in"
    sp=$(dongle_speed)
    case "$sp" in
      5000M|10000M|20000M) ok "USB speed $sp" ;;
      "") warn "no driver bound to it" ;;
      *) warn "USB speed $sp, use a USB 3 port on the back of the PC" ;;
    esac
    info "driver: $(driver_in_use)"
    fw=$(firmware_loaded); [ -n "$fw" ] && info "firmware: $fw"
  else
    warn "not plugged in"
  fi
  v=$(dkms_versions | tr '\n' ' ')
  [ -n "$v" ] && ok "DKMS rtw89: $v" || info "DKMS rtw89: not installed"
  info "region: $(current_region)"
  [ -f "$UDEV_RULE" ] && ok "USB power rule present" || info "USB power rule not present"

  say "Steam"
  root=$(find_steam_root)
  if [ -z "$root" ]; then
    warn "Steam folder not found"
  else
    info "$root"
    app_installed "$root" "$STEAMVR_ID" && ok "SteamVR installed" || warn "SteamVR not installed"
    id=$(grep -oP '"RemoteClientID"\s*:\s*"\K[0-9]+' "$root/config/steamvr.vrsettings" 2>/dev/null)
    [ -n "$id" ] && ok "headset known to SteamVR ($id)" || info "headset not seen by SteamVR yet"
    say "VR games the helper will handle"
    local g n=0
    for g in $(vr_games "$root"); do
      info "$g  $(app_name "$root" "$g")"; n=$((n + 1))
    done
    [ "$n" = 0 ] && info "none found yet, they show up once installed"
  fi

  say "VR helper"
  if [ -x "$HELPER" ]; then
    helper_running && ok "installed and running" || warn "installed but not running (run repair)"
    if [ -f "$HELPER_LOG" ]; then info "last log lines:"; tail -5 "$HELPER_LOG" | sed 's/^/          /'; fi
  else
    info "not installed"
  fi
}

usage() {
  cat <<EOF
$NAME $VERSION

  $0 install     install everything
  $0 repair      update the driver and reinstall everything
  $0 uninstall   remove everything this script added
  $0 status      show what is detected and installed
EOF
}

menu() {
  usage
  echo
  local c
  read -rp "Choose [install/repair/uninstall/status]: " c
  main "$c"
}

main() {
  case "${1:-}" in
    install)   do_install ;;
    repair)    do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    ""|menu)   menu ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

[ "$EUID" -eq 0 ] && die "run this as your normal user, not with sudo. It asks for your password when needed."
main "${1:-}"
