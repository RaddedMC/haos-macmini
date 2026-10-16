#!/bin/bash
# Installer for Home Assistant OS on a Mac mini 4,1 (2010, NVIDIA MCP89).
#   - Powers the machine on automatically after a power loss
#   - Runs a quiet, temperature-driven fan curve through the applesmc driver
#
# HAOS has a read-only root filesystem, so this installs a small LOCAL ADD-ON
# (privileged, starts on boot) that the Supervisor keeps running for you.
#
# Run as root on the HAOS HOST (developer SSH, port 22222), not inside an add-on.
# Replace URL with the raw GitHub URL of this file:
#   curl -fsSL URL | bash                       # install / update
#   curl -fsSL URL | bash -s -- status          # show add-on state + recent log
#   curl -fsSL URL | bash -s -- uninstall       # remove and hand fans back to the SMC
# (Also works as a local file: bash install-macmini-tuning.sh [status|uninstall])
set -eu

# Everything lives inside main() and main runs on the LAST line, so a download
# that gets cut off partway never executes a half-finished script.
main() {
SLUG=macmini_tuning
ADDON=local_$SLUG

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
command -v ha >/dev/null 2>&1 || { echo "The 'ha' command was not found. Run this on the HAOS host (SSH port 22222), not in an add-on or another machine."; exit 1; }

# Home Assistant renamed "add-ons" to "apps". Newer installs use .../apps and
# 'ha apps'; older ones use .../addons and 'ha addons'. Detect which this is.
SUPERVISOR=${SUPERVISOR_DIR:-/mnt/data/supervisor}
BASE=""
for cand in apps addons; do
  if [ -d "$SUPERVISOR/$cand" ]; then BASE=$SUPERVISOR/$cand; break; fi
done
if [ -z "$BASE" ]; then
  echo "Could not find an 'apps' or 'addons' folder in $SUPERVISOR - this does not look like the HAOS host."
  echo "Contents of $SUPERVISOR:"; ls -1 "$SUPERVISOR" 2>&1 | sed 's/^/  /'
  exit 1
fi

# On the HAOS host, 'ha' opens an interactive session inside the CLI container
# and needs a real terminal on stdin. When this script is piped in
# (curl ... | bash), stdin is the script itself, so hand 'ha' the controlling
# terminal explicitly (this also stops 'ha' from swallowing the script text).
ha_run() {
  if [ -t 0 ]; then
    ha "$@"
  elif { : </dev/tty; } 2>/dev/null; then
    ha "$@" </dev/tty
  else
    # No terminal at all: talk to the CLI container without attaching stdin
    docker exec hassio_cli ha "$@" </dev/null
  fi
}

CLI=addons
if ha_run apps --help >/dev/null 2>&1; then CLI=apps; fi
happ() { ha_run "$CLI" "$@"; }
DIR=$BASE/local/macmini-tuning
echo "Detected: folder $BASE, command 'ha $CLI'"

case "${1:-install}" in
  status)
    happ info "$ADDON" || true
    echo "---- recent log ----"
    happ logs "$ADDON" 2>&1 | tail -n 25 || true
    exit 0 ;;
  uninstall)
    happ stop "$ADDON" 2>/dev/null || true
    happ uninstall "$ADDON" 2>/dev/null || true
    rm -rf "$DIR"
    happ reload 2>/dev/null || true
    echo "Removed. Fans are back under SMC control."; exit 0 ;;
esac

# Clean up leftovers from the earlier systemd-based attempt, if any
rm -rf /mnt/data/macmini-tuning

mkdir -p "$DIR"

# ---------------------------------------------------------------------------
cat > "$DIR/config.yaml" <<'CONFIG_EOF'
name: Mac mini Tuning
version: "1.0.0"
slug: macmini_tuning
description: Power on after power loss and a quiet fan curve for the Mac mini 4,1
arch:
  - amd64
startup: system
boot: auto
full_access: true
kernel_modules: true
CONFIG_EOF

# ---------------------------------------------------------------------------
cat > "$DIR/Dockerfile" <<'DOCKER_EOF'
FROM alpine:3.20
RUN apk add --no-cache bash kmod
COPY run.sh /run.sh
RUN chmod 755 /run.sh
CMD ["/run.sh"]
DOCKER_EOF

# ---------------------------------------------------------------------------
cat > "$DIR/run.sh" <<'RUN_EOF'
#!/bin/bash
# macmini-tuning: auto power-on after power loss + fan curve (Mac mini 4,1)
set -u
log() { echo "macmini-tuning: $*"; }

############################ TUNABLES ########################################
# Fan curve: temperature (C) -> RPM. First point uses the fan's minimum RPM,
# last point uses its maximum RPM. Adjust the middle values to taste.
CURVE_TEMPS=(45   55   65   75   85)
CURVE_RPMS=(MIN 2200 3000 4200  MAX)
POLL=5            # seconds between readings
RAMP_DOWN=100     # max RPM the fan may drop per poll (prevents hunting)
MIN_STEP=50       # ignore target changes smaller than this
###############################################################################

PCI=/sys/bus/pci/devices/0000:00:03.0   # NVIDIA MCP89 LPC bridge
PM_REG=123                              # 0x7b
PM_VAL=25                               # 0x19 = power on after AC loss (stock value is 0x60)

power_on_after_loss() {
  [ -r "$PCI/vendor" ] || { log "PCI 00:03.0 not found - skipping power-loss setting"; return 1; }
  local vendor class cur
  vendor=$(cat "$PCI/vendor"); class=$(cat "$PCI/class")
  if [ "$vendor" != "0x10de" ] || [ "${class:0:6}" != "0x0601" ]; then
    log "00:03.0 is not the NVIDIA LPC bridge ($vendor/$class) - refusing to write"; return 1
  fi
  cur=$(od -An -tu1 -j "$PM_REG" -N1 "$PCI/config" | tr -d ' ')
  [ "$cur" = "$PM_VAL" ] && return 0
  printf '\031' | dd of="$PCI/config" bs=1 seek="$PM_REG" count=1 conv=notrunc 2>/dev/null
  cur=$(od -An -tu1 -j "$PM_REG" -N1 "$PCI/config" | tr -d ' ')
  if [ "$cur" = "$PM_VAL" ]; then log "power-on-after-loss enabled (reg 0x7b = 0x19)"
  else log "WARNING: write did not stick (reg 0x7b = $cur)"; return 1; fi
}

# ---------- fan control ----------
SMC=""; TEMP_FILES=()
FAN_MIN=0; FAN_MAX=0; LAST_SET=0

find_sensors() {
  local d h n f
  for d in /sys/devices/platform/applesmc.*; do [ -e "$d/fan1_output" ] && SMC=$d && break; done
  TEMP_FILES=()
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name")
    if [ "$n" = "coretemp" ]; then for f in "$h"/temp*_input; do [ -r "$f" ] && TEMP_FILES+=("$f"); done; fi
  done
  # Fallback: SMC CPU sensors (labels starting with TC)
  if [ ${#TEMP_FILES[@]} -eq 0 ] && [ -n "$SMC" ]; then
    for f in "$SMC"/temp*_label; do
      [ -r "$f" ] || continue
      case "$(cat "$f")" in TC*) TEMP_FILES+=("${f%_label}_input");; esac
    done
  fi
}

max_temp_mc() {   # prints hottest reading in millidegrees C, or fails
  local f v best=-1
  for f in "${TEMP_FILES[@]}"; do
    v=$(cat "$f" 2>/dev/null) || continue
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt "$best" ] && best=$v
  done
  [ "$best" -gt 0 ] || return 1
  echo "$best"
}

curve_rpm() {     # $1 = temp in millidegrees C -> target RPM (linear interpolation)
  local t=$1 n=${#CURVE_TEMPS[@]} i t0 t1 r0 r1
  local -a R
  for ((i=0;i<n;i++)); do
    case "${CURVE_RPMS[i]}" in MIN) R[i]=$FAN_MIN;; MAX) R[i]=$FAN_MAX;; *) R[i]=${CURVE_RPMS[i]};; esac
  done
  [ "$t" -le $((CURVE_TEMPS[0]*1000)) ] && { echo "${R[0]}"; return; }
  [ "$t" -ge $((CURVE_TEMPS[n-1]*1000)) ] && { echo "${R[n-1]}"; return; }
  for ((i=0;i<n-1;i++)); do
    t0=$((CURVE_TEMPS[i]*1000)); t1=$((CURVE_TEMPS[i+1]*1000))
    if [ "$t" -ge "$t0" ] && [ "$t" -lt "$t1" ]; then
      r0=${R[i]}; r1=${R[i+1]}
      echo $(( r0 + (r1 - r0) * (t - t0) / (t1 - t0) )); return
    fi
  done
  echo "$FAN_MAX"
}

clamp() { local v=$1; [ "$v" -lt "$FAN_MIN" ] && v=$FAN_MIN; [ "$v" -gt "$FAN_MAX" ] && v=$FAN_MAX; echo "$v"; }

set_fan() {
  echo "$1" > "$SMC/fan1_output" 2>/dev/null && LAST_SET=$1
}

release_fan() { [ -n "$SMC" ] && echo 0 > "$SMC/fan1_manual" 2>/dev/null; log "fan returned to SMC auto control"; }

fan_loop() {
  local t target new d fails=0
  log "fan curve active: ${#TEMP_FILES[@]} sensor(s), fan ${FAN_MIN}-${FAN_MAX} RPM"
  echo 1 > "$SMC/fan1_manual" || { log "cannot enable manual fan control"; return 1; }
  while true; do
    if t=$(max_temp_mc); then
      fails=0
      target=$(clamp "$(curve_rpm "$t")")
      new=$target
      # ramp up immediately, ramp down gradually
      if [ "$target" -lt "$LAST_SET" ]; then new=$(( LAST_SET - RAMP_DOWN )); [ "$new" -lt "$target" ] && new=$target; fi
      d=$(( new - LAST_SET )); [ "$d" -lt 0 ] && d=$(( -d ))
      if [ "$d" -ge "$MIN_STEP" ] || [ "$LAST_SET" -eq 0 ]; then set_fan "$new"; fi
    else
      fails=$((fails+1))
      if [ "$fails" -ge 3 ]; then set_fan "$FAN_MAX"; log "sensor read failing - fan forced to max"; fi
    fi
    power_on_after_loss >/dev/null 2>&1   # cheap re-assert in case it gets reset
    sleep "$POLL" & wait $!
  done
}

# ---------- main ----------
if [ "${1:-}" != "--source-only" ]; then
  modprobe applesmc 2>/dev/null || true
  modprobe coretemp 2>/dev/null || true

  power_on_after_loss || true

  for _ in $(seq 1 30); do find_sensors; [ -n "$SMC" ] && [ ${#TEMP_FILES[@]} -gt 0 ] && break; sleep 1; done
  if [ -z "$SMC" ] || [ ${#TEMP_FILES[@]} -eq 0 ]; then
    log "applesmc/temperature sensors not available (kernel lacks the driver?) - fan control skipped"
    # Keep the add-on alive so the power-loss setting stays asserted.
    while true; do sleep 60 & wait $!; power_on_after_loss >/dev/null 2>&1 || true; done
  fi

  FAN_MIN=$(cat "$SMC/fan1_min"); FAN_MAX=$(cat "$SMC/fan1_max")
  trap 'release_fan; exit 0' TERM INT
  fan_loop
fi
RUN_EOF
chmod 755 "$DIR/run.sh"

# ---------------------------------------------------------------------------
echo "Files written to $DIR"
echo "Registering with the Supervisor (the first install builds a small image and needs internet)..."
happ reload
for _ in 1 2 3 4 5 6 7 8 9 10; do
  happ info "$ADDON" >/dev/null 2>&1 && break
  sleep 3
done

if happ install "$ADDON"; then
  echo "Installed."
else
  echo "Already installed (or install failed) - rebuilding with the latest files..."
  happ rebuild "$ADDON" || true
fi
happ start "$ADDON" || happ restart "$ADDON" || true

sleep 6
echo
echo "---- log ----"
happ logs "$ADDON" 2>&1 | tail -n 15 || true
echo
echo "It is set to start on boot. To check later, re-run this installer with the argument: status"
echo "  e.g.  curl -fsSL <URL> | bash -s -- status"
echo "If the install step failed, open Settings > Add-ons (or Apps) > Store, use the menu (three dots) > Check for updates,"
echo "then install 'Mac mini Tuning' from the Local section and make sure 'Start on boot' is on."
}

main "$@"