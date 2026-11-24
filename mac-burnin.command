#!/bin/bash
# =============================================================================
#  mac-burnin.command   version 1.0
#
#  Hardware check and burn-in test for used Intel MacBooks:
#  MacBook Pro 2016-2020, MacBook Air 2017-2020, MacBook 12-inch 2017.
#
#  WHAT IT DOES
#    1. Automatic checks: Activation Lock, MDM and Apple Business Manager,
#       firmware password, battery health, SSD health, memory, GPUs, display,
#       camera, audio devices, Wi-Fi, Bluetooth, old kernel panics.
#    2. Hands-on tests with prompts: screen, keyboard, trackpad, speakers,
#       camera, microphone, each charging port, USB data, Touch Bar,
#       Touch ID, brightness, keyboard light, hinge, swollen battery.
#    3. SSD test: writes random data, reads it back and compares it.
#    4. Burn-in: full load on all CPU threads plus GPU load (Safari WebGL).
#       Every 30 seconds it records CPU temperature, fan speed, throttling,
#       battery and charger state. It reads the full SSD one time. Every
#       30 minutes it reads the test data again and compares it. It looks
#       for kernel panics, GPU restarts and graphics crashes.
#    5. Report: report.html and report.txt with PASS, WARN and FAIL.
#
#  HOW TO START
#    1. Copy this file to a USB stick.
#    2. On the Mac, open Terminal (Applications > Utilities > Terminal).
#    3. Type  bash  and a space. Drag this file into the Terminal window.
#       Push Return.
#    4. Type the admin password when the script asks for it.
#
#  OPTIONS
#    --hours N              Burn-in time in hours (default 4)
#    --minutes N            Burn-in time in minutes
#    --auto                 Ask no questions: automatic checks, SSD test, burn-in
#    --skip-burnin          Do the checks and the hands-on tests only
#    --ssd-gb N             Size of the SSD test in GB (default 8)
#    --battery-rundown [P]  After the burn-in, run on battery down to P% (default 30),
#                           light load (2 CPU threads)
#    --battery-stress [P]   Same, but at full CPU and GPU load (finds weak batteries
#                           that shut down early under heavy current)
#
#  OUTPUT
#    ~/Desktop/MacBurnIn/<serial>_<date>/  report.html, report.txt,
#    samples.csv, log.txt. If the script runs from a USB stick, it also puts
#    a copy in MacBurnIn-reports on the stick.
#
#  If the Mac restarts or shuts down during a test, run the script again.
#  It finds the test that did not finish and adds a FAIL to that report.
# =============================================================================

VERSION="1.0"

# --- Relocate ----------------------------------------------------------------
# If the script runs from a USB stick, run a copy from the internal disk.
# Then the tester can remove the stick during the port test.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "${BURNIN_RELOCATED:-}" ]; then
  case "$SELF_DIR" in
    /Volumes/*)
      _tmp="$(mktemp -d "${TMPDIR:-/tmp}/mac-burnin.XXXXXX")" || exit 1
      cp "$0" "$_tmp/mac-burnin.command" || exit 1
      BURNIN_RELOCATED=1 BURNIN_ORIGIN_DIR="$SELF_DIR" exec /bin/bash "$_tmp/mac-burnin.command" "$@"
      ;;
  esac
fi
ORIGIN_DIR="${BURNIN_ORIGIN_DIR:-$SELF_DIR}"

# --- Settings ----------------------------------------------------------------
BURN_MIN=240
AUTO=0
SKIP_BURNIN=0
SSD_GB=8
RUNDOWN=0
RUNDOWN_PCT=30
RUNDOWN_FULL=0
SAMPLE_SEC=30
VERIFY_EVERY_SEC=1800

# --- State -------------------------------------------------------------------
HAVE_SUDO=0
HAVE_PM=0
IN_BURNIN=0
STOP_REQUESTED=0
CLEANED=0
FINALIZED=0
WORKER_PIDS=""
KEEPALIVE_PID=""
CAFF_PID=""
FULLREAD_PID=""
VOL_SAVED=""
MUTE_SAVED=""
PHASE="start"
RUN_DIR=""
RESULTS=""
LOG="/dev/null"
CSV=""
WORK=""
SSD_FILE=""
SSD_CHUNKS=0
RUN_START=""
BURN_DONE=0
S_TEMP=""; S_FAN=""; S_SPEED=""; S_PROCHOT=""; S_BATT=""; S_AC=""; S_BTEMP=""
MODEL_ID=""; MODEL_NAME=""; MODEL_LONG=""; SERIAL=""; CPU=""; NCPU=4; MEM_GB=""
OS_VER=""; OS_BUILD=""; FIRMWARE=""; SSD_DESC=""; BATT_DESC=""; GPU_DESC=""
START_HUMAN=""; BURN_PLAN=""
CHARGE_PORTS=0; DATA_PORTS=0; HAS_TBAR=0; HAS_TID=0; HAS_DGPU=0; FANS=-1
KBD="unknown"; THIN=0; ERA=""; PORT_LABELS=""; DATA_LABELS=""; HAS_T2=0

is_int() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

usage() {
  cat <<'EOF'
Usage: bash mac-burnin.command [options]

  --hours N              Burn-in time in hours (default: 4)
  --minutes N            Burn-in time in minutes (for short runs)
  --auto                 Ask no questions. Do the automatic checks,
                         the SSD test and the burn-in only.
  --skip-burnin          Do the checks and the hands-on tests only.
  --ssd-gb N             Size of the SSD test in GB (default: 8)
  --battery-rundown [P]  After the burn-in, run on battery down to P percent
                         (default: 30) with a light load (2 CPU threads)
  --battery-stress [P]   Same, but with full CPU and GPU load. This finds weak
                         batteries that shut down early under heavy current.
  --help                 Show this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours)
      is_int "${2:-}" || { echo "--hours needs a whole number. For less than 1 hour, use --minutes."; exit 2; }
      BURN_MIN=$(( $2 * 60 )); shift 2;;
    --minutes)
      is_int "${2:-}" || { echo "--minutes needs a whole number."; exit 2; }
      BURN_MIN=$2; shift 2;;
    --auto) AUTO=1; shift;;
    --skip-burnin) SKIP_BURNIN=1; shift;;
    --ssd-gb)
      is_int "${2:-}" || { echo "--ssd-gb needs a whole number."; exit 2; }
      SSD_GB=$2; shift 2;;
    --battery-rundown|--battery-stress)
      RUNDOWN=1
      [ "$1" = "--battery-stress" ] && RUNDOWN_FULL=1
      if is_int "${2:-}"; then RUNDOWN_PCT=$2; shift; fi
      shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 2;;
  esac
done
[ "$BURN_MIN" -ge 1 ] || BURN_MIN=1

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  CYN=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'; CLR=$'\033[K'
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; DIM=""; RST=""; CLR=""
fi

# --- Small helpers -----------------------------------------------------------
logmsg() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
msg()    { printf '%s\n' "$*"; logmsg "$*"; }
step()   { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RST"; logmsg "== $*"; }
note()   { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
warnmsg(){ printf '%s%s%s\n' "$YEL" "$*" "$RST"; logmsg "WARNING: $*"; }
sudo_maybe() { if [ "$HAVE_SUDO" = 1 ]; then sudo -n "$@"; else "$@"; fi; }

# Value after "Key:" in system_profiler / diskutil style text.
field() {
  printf '%s\n' "$1" | awk -v k="$2" '{
    l = $0; sub(/^[ \t]+/, "", l)
    if (index(l, k ":") == 1) { v = substr(l, length(k) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }
  }'
}

# Top-level value from: ioreg -rn AppleSmartBattery
ioreg_val() {
  printf '%s\n' "$IOREG_BATT" | awk -v k="\"$1\" = " '{
    l = $0; sub(/^[ \t|]+/, "", l)
    if (index(l, k) == 1) { print substr(l, length(k) + 1); exit }
  }'
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s; }

fmt_dur() {
  awk -v s="$1" 'BEGIN { s = int(s); h = int(s / 3600); m = int((s % 3600) / 60); x = s % 60
    if (h > 0) printf "%dh %02dm", h, m; else if (m > 0) printf "%dm %02ds", m, x; else printf "%ds", x }'
}

epoch_fmt() {
  perl -MPOSIX -e 'print strftime("%Y-%m-%d %H:%M:%S", localtime($ARGV[0]))' "$1" 2>/dev/null \
    || date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"
}

mbps() { awk -v mb="$1" -v a="$2" -v b="$3" 'BEGIN { d = b - a; if (d <= 0) d = 0.001; printf "%d", mb / d }'; }

# run_timeout SECONDS command... (macOS has no "timeout" command)
run_timeout() {
  local secs="$1" pid w rc
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$w" 2>/dev/null
  return $rc
}

# record STATUS SECTION TEST DETAIL   (STATUS: PASS FAIL WARN INFO SKIP)
record() {
  local st="$1" sec="$2" name="$3" det col
  det="$(printf '%s' "${4:-}" | tr '\t\n' '  ')"
  [ -n "$RESULTS" ] && printf '%s\t%s\t%s\t%s\n' "$st" "$sec" "$name" "$det" >> "$RESULTS"
  case "$st" in
    PASS) col="$GRN";; FAIL) col="$RED";; WARN) col="$YEL";; INFO) col="$CYN";; *) col="$DIM";;
  esac
  printf '  %s%-4s%s  %s%s%s\n' "$col" "$st" "$RST" "$name" "${det:+: }" "$det"
  logmsg "RESULT $st | $sec | $name | $det"
}

# ask_pf SECTION TEST QUESTION [repeat]  ->  0 answered, 2 tester wants a repeat
ask_pf() {
  local sec="$1" name="$2" q="$3" rep="${4:-0}" a nt
  while :; do
    printf '\n%s%s%s\n' "$BOLD" "$q" "$RST"
    if [ "$rep" = 1 ]; then
      printf '  p = pass   f = fail   s = skip   r = repeat  > '
    else
      printf '  p = pass   f = fail   s = skip  > '
    fi
    read -r a || a="s"
    a="$(printf '%s' "$a" | tr 'A-Z' 'a-z')"
    case "$a" in
      p|pass|y|yes) record PASS "$sec" "$name" "Checked by the tester"; return 0;;
      f|fail|n|no)
        printf '  Write what is wrong (or push Return) > '
        read -r nt || nt=""
        record FAIL "$sec" "$name" "${nt:-The tester found a fault}"; return 0;;
      s|skip) record SKIP "$sec" "$name" "Not tested"; return 0;;
      r|repeat) [ "$rep" = 1 ] && return 2;;
    esac
    printf '  Type p, f or s.\n'
  done
}

ask_yn() {
  local q="$1" def="${2:-n}" a
  while :; do
    if [ "$def" = y ]; then printf '%s [Y/n] > ' "$q"; else printf '%s [y/N] > ' "$q"; fi
    read -r a || a=""
    a="$(printf '%s' "$a" | tr 'A-Z' 'a-z')"
    [ -z "$a" ] && a="$def"
    case "$a" in y|yes) return 0;; n|no) return 1;; esac
  done
}

ask_text() { local a; printf '%s > ' "$1" >&2; read -r a || a=""; printf '%s' "$a"; }

ask_int() {
  local a
  while :; do
    printf '%s (%s-%s) > ' "$1" "$2" "$3" >&2
    read -r a || { printf '%s' "$2"; return; }
    if is_int "$a" && [ "$a" -ge "$2" ] && [ "$a" -le "$3" ]; then printf '%s' "$a"; return; fi
  done
}

pause_enter() { printf '%s%s%s' "$DIM" "${1:-Push Return to continue.}" "$RST"; read -r _ || true; printf '\n'; }

on_ac() { pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; }

# wait_power WANT(1=charger, 0=battery) SECONDS -> 0 ok, 1 timeout, 2 skipped
wait_power() {
  local want="$1" limit="$2" waited=0 line rc
  while [ "$waited" -lt "$limit" ]; do
    if [ "$want" = 1 ] && on_ac; then return 0; fi
    if [ "$want" = 0 ] && ! on_ac; then return 0; fi
    read -t 1 -r line; rc=$?
    if [ $rc -eq 0 ]; then
      case "$line" in s|S) return 2;; esac
    elif [ $rc -le 128 ]; then
      sleep 1
    fi
    waited=$((waited + 1))
  done
  return 1
}

usb_count() { ioreg -p IOUSB -w0 2>/dev/null | grep -c '+-o'; }

set_state() {
  PHASE="$1"
  [ -n "$STATE_FILE" ] || return 0
  {
    printf 'ST_RUN_DIR=%q\n' "$RUN_DIR"
    printf 'ST_PHASE=%q\n' "$1"
    printf 'ST_START=%q\n' "$RUN_START"
    printf 'ST_LAST=%q\n' "$(date +%s)"
    printf 'ST_BATT=%q\n' "${S_BATT:-}"
    printf 'ST_AC=%q\n' "${S_AC:-}"
  } > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
}

save_device() {
  [ -n "$RUN_DIR" ] || return 0
  local v
  {
    for v in MODEL_NAME MODEL_ID MODEL_LONG SERIAL CPU NCPU MEM_GB OS_VER OS_BUILD FIRMWARE \
             SSD_DESC BATT_DESC GPU_DESC START_HUMAN BURN_PLAN; do
      printf 'R_%s=%q\n' "$v" "${!v}"
    done
    printf 'R_VERSION=%q\n' "$VERSION"
  } > "$RUN_DIR/device.env"
}

# --- Model table ---------------------------------------------------------------
model_table() {
  local L4="left side, port nearest you|left side, port farther from you|right side, port nearest you|right side, port farther from you"
  local L2="left side, port nearest you|left side, port farther from you"
  case "$MODEL_ID" in
    MacBook10,1)    MODEL_LONG="MacBook (Retina, 12-inch, 2017)"; CHARGE_PORTS=1; FANS=0; KBD=butterfly; THIN=1; PORT_LABELS="left side"; ERA=2017;;
    MacBookAir7,2)  MODEL_LONG="MacBook Air (13-inch, 2017 or Early 2015)"; CHARGE_PORTS=1; DATA_PORTS=2; FANS=1; KBD=scissor; THIN=1
                    PORT_LABELS="MagSafe 2 port, left side"; DATA_LABELS="USB-A port, left side|USB-A port, right side"; ERA=2017;;
    MacBookAir8,1)  MODEL_LONG="MacBook Air (Retina, 13-inch, 2018)"; CHARGE_PORTS=2; HAS_TID=1; FANS=1; KBD=butterfly; THIN=1; PORT_LABELS="$L2"; ERA=2018;;
    MacBookAir8,2)  MODEL_LONG="MacBook Air (Retina, 13-inch, 2019)"; CHARGE_PORTS=2; HAS_TID=1; FANS=1; KBD=butterfly; THIN=1; PORT_LABELS="$L2"; ERA=2019;;
    MacBookAir9,1)  MODEL_LONG="MacBook Air (Retina, 13-inch, 2020)"; CHARGE_PORTS=2; HAS_TID=1; FANS=1; KBD=scissor; THIN=1; PORT_LABELS="$L2"; ERA=2020;;
    MacBookPro13,1) MODEL_LONG="MacBook Pro (13-inch, 2016, Two Thunderbolt 3 ports)"; CHARGE_PORTS=2; FANS=1; KBD=butterfly; PORT_LABELS="$L2"; ERA=2016;;
    MacBookPro13,2) MODEL_LONG="MacBook Pro (13-inch, 2016, Four Thunderbolt 3 ports)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2016;;
    MacBookPro13,3) MODEL_LONG="MacBook Pro (15-inch, 2016)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2016;;
    MacBookPro14,1) MODEL_LONG="MacBook Pro (13-inch, 2017, Two Thunderbolt 3 ports)"; CHARGE_PORTS=2; FANS=1; KBD=butterfly; PORT_LABELS="$L2"; ERA=2017;;
    MacBookPro14,2) MODEL_LONG="MacBook Pro (13-inch, 2017, Four Thunderbolt 3 ports)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2017;;
    MacBookPro14,3) MODEL_LONG="MacBook Pro (15-inch, 2017)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2017;;
    MacBookPro15,1) MODEL_LONG="MacBook Pro (15-inch, 2018 or 2019)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2018;;
    MacBookPro15,2) MODEL_LONG="MacBook Pro (13-inch, 2018 or 2019, Four Thunderbolt 3 ports)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2018;;
    MacBookPro15,3) MODEL_LONG="MacBook Pro (15-inch, 2018 or 2019, Radeon Pro Vega)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=butterfly; PORT_LABELS="$L4"; ERA=2018;;
    MacBookPro15,4) MODEL_LONG="MacBook Pro (13-inch, 2019, Two Thunderbolt 3 ports)"; CHARGE_PORTS=2; HAS_TBAR=1; HAS_TID=1; FANS=1; KBD=butterfly; PORT_LABELS="$L2"; ERA=2019;;
    MacBookPro16,1) MODEL_LONG="MacBook Pro (16-inch, 2019)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=scissor; PORT_LABELS="$L4"; ERA=2019;;
    MacBookPro16,4) MODEL_LONG="MacBook Pro (16-inch, 2019, Radeon Pro 5600M)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; HAS_DGPU=1; FANS=2; KBD=scissor; PORT_LABELS="$L4"; ERA=2019;;
    MacBookPro16,2) MODEL_LONG="MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports)"; CHARGE_PORTS=4; HAS_TBAR=1; HAS_TID=1; FANS=2; KBD=scissor; PORT_LABELS="$L4"; ERA=2020;;
    MacBookPro16,3) MODEL_LONG="MacBook Pro (13-inch, 2020, Two Thunderbolt 3 ports)"; CHARGE_PORTS=2; HAS_TBAR=1; HAS_TID=1; FANS=1; KBD=scissor; PORT_LABELS="$L2"; ERA=2020;;
    *) MODEL_LONG="${MODEL_NAME:-Mac} ($MODEL_ID)";;
  esac
  [ "$DATA_PORTS" -gt 0 ] || DATA_PORTS=$CHARGE_PORTS
  [ -n "$DATA_LABELS" ] || DATA_LABELS="$PORT_LABELS"
}

known_issues() {
  KNOWN=""
  ki() { KNOWN="${KNOWN}  - $1
"; }
  if [ "$KBD" = butterfly ]; then
    ki "Butterfly keyboard: keys can stick, fail, or type twice. Test every key. The test page marks a double-typed key orange."
  fi
  case "$MODEL_ID" in MacBookPro13,*|MacBookPro14,*)
    ki "Display cable ('flexgate'): on the white screen, close the lid slowly to about 45 degrees, then open it fully. Uneven light at the bottom edge, or a dark screen at a wide angle, is a fault."
    ki "Screen coating wear ('staingate'): look for patches on the white and the black screen.";;
  esac
  case "$MODEL_ID" in MacBookPro13,1|MacBookPro14,1)
    ki "13-inch two-port 2016-2017: check for a swollen battery. Apple had a battery program for this model.";;
  esac
  case "$MODEL_ID" in MacBookPro15,*|MacBookAir8,*)
    ki "T2 chip (2018-2019): the report shows kernel panics. A panic that names 'bridgeOS' or the T2 is a known fault type.";;
  esac
  [ "$HAS_DGPU" = 1 ] && ki "Discrete AMD GPU: the burn-in loads it with a Safari page. Look for lines, blocks or flicker on that page."
  case "$MODEL_ID" in MacBookPro16,1|MacBookPro16,4)
    ki "16-inch 2019: listen for pops or crackle in the speaker sweep.";;
  esac
  [ "$THIN" = 1 ] && ki "Thin design: CPU throttling under full load is normal on this model. The script does not mark it as a fault."
  ki "All models: check for a swollen battery. The Mac must not rock on a flat table, and the trackpad must click normally."
}

# --- Device information --------------------------------------------------------
gather_device() {
  SP_HW="$(system_profiler SPHardwareDataType 2>/dev/null)"
  MODEL_ID="$(sysctl -n hw.model 2>/dev/null)"
  [ -n "$MODEL_ID" ] || MODEL_ID="$(field "$SP_HW" "Model Identifier")"
  MODEL_NAME="$(field "$SP_HW" "Model Name")"
  CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  [ -n "$CPU" ] || CPU="$(field "$SP_HW" "Processor Name")"
  NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null)"
  is_int "$NCPU" || NCPU=4
  local memb
  memb="$(sysctl -n hw.memsize 2>/dev/null)"
  if is_int "$memb"; then MEM_GB=$(( memb / 1073741824 )); else MEM_GB="$(field "$SP_HW" "Memory" | tr -dc '0-9')"; fi
  SERIAL="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ { print $4; exit }')"
  [ -n "$SERIAL" ] || SERIAL="$(field "$SP_HW" "Serial Number (system)")"
  [ -n "$SERIAL" ] || SERIAL="UNKNOWN"
  OS_VER="$(sw_vers -productVersion 2>/dev/null)"
  OS_BUILD="$(sw_vers -buildVersion 2>/dev/null)"
  FIRMWARE="$(field "$SP_HW" "System Firmware Version")"
  [ -n "$FIRMWARE" ] || FIRMWARE="$(field "$SP_HW" "Boot ROM Version")"
  if system_profiler SPiBridgeDataType 2>/dev/null | grep -q "T2"; then HAS_T2=1; fi
  model_table
  known_issues
}

# --- 1. Automatic checks -------------------------------------------------------
check_locks() {
  local al enr dep mdm out org fw
  al="$(field "$SP_HW" "Activation Lock Status")"
  case "$al" in
    Disabled) record PASS "Locks" "Activation Lock" "Off";;
    Enabled)  record FAIL "Locks" "Activation Lock" "ON. The owner must remove this Mac from their Apple ID (Find My). Do not sell it until then.";;
    "")
      if [ "$HAS_T2" = 1 ]; then
        record WARN "Locks" "Activation Lock" "macOS did not report it. Check System Settings > General > About."
      else
        record INFO "Locks" "Activation Lock" "This model has no T2 chip, so Mac Activation Lock does not apply."
      fi;;
    *) record WARN "Locks" "Activation Lock" "$al";;
  esac

  enr="$(sudo_maybe profiles status -type enrollment 2>&1)"
  dep="$(field "$enr" "Enrolled via DEP")"
  mdm="$(field "$enr" "MDM enrollment")"
  if [ "$dep" = "Yes" ] || printf '%s' "$mdm" | grep -q '^Yes'; then
    record FAIL "Locks" "MDM enrollment" "Enrolled (DEP: $dep, MDM: $mdm). An organization manages this Mac."
  elif [ -n "$dep$mdm" ]; then
    record PASS "Locks" "MDM enrollment" "Not enrolled"
  else
    record WARN "Locks" "MDM enrollment" "Could not read the enrollment status"
  fi

  if [ "$HAVE_SUDO" = 1 ]; then
    out="$(run_timeout 45 sudo -n profiles show -type enrollment 2>&1)"
    if printf '%s' "$out" | grep -qi "not DEP enabled"; then
      record PASS "Locks" "Apple Business Manager" "Not assigned to an organization"
    elif printf '%s' "$out" | grep -Eq "ConfigurationURL|OrganizationName|IsMDMUnremovable"; then
      org="$(printf '%s\n' "$out" | awk -F'= ' '/OrganizationName/ { print $2; exit }' | tr -d '";')"
      record FAIL "Locks" "Apple Business Manager" "Assigned to an organization${org:+ ($org)}. After an erase, setup will force their remote management. The organization must release the Mac first."
    else
      record WARN "Locks" "Apple Business Manager" "Could not check. This check needs internet, and Apple limits how often a Mac can ask. Reply: $(printf '%s' "$out" | head -2 | tr '\n' ' ' | cut -c1-160)"
    fi
  else
    record SKIP "Locks" "Apple Business Manager" "Needs the admin password"
  fi

  if [ "$HAVE_SUDO" = 1 ] && command -v firmwarepasswd >/dev/null 2>&1; then
    fw="$(sudo -n firmwarepasswd -check 2>&1)"
    case "$fw" in
      *"Enabled: Yes"*) record FAIL "Locks" "Firmware password" "ON. The buyer cannot start from Recovery or USB. Remove it before sale.";;
      *"Enabled: No"*)  record PASS "Locks" "Firmware password" "Off";;
      *) record WARN "Locks" "Firmware password" "Could not read: $(printf '%s' "$fw" | head -1)";;
    esac
  else
    record SKIP "Locks" "Firmware password" "Needs the admin password"
  fi

  if defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q "AccountID"; then
    record WARN "Locks" "Apple ID on this user" "An Apple ID is signed in on this macOS user. Sign it out before you erase the Mac."
  fi

  case "$(csrutil status 2>/dev/null)" in
    *enabled.*)  record PASS "Locks" "System Integrity Protection" "On";;
    *disabled*)  record WARN "Locks" "System Integrity Protection" "Off. Turn it on in Recovery (Terminal: csrutil enable) before sale.";;
    *)           record INFO "Locks" "System Integrity Protection" "Could not read";;
  esac
  record INFO "Locks" "FileVault" "$(fdesetup status 2>/dev/null | head -1)"
}

check_battery() {
  local cycles design rawmax cond maxsp health pf btemp chg watt lpm
  SP_PWR="$(system_profiler SPPowerDataType 2>/dev/null)"
  IOREG_BATT="$(ioreg -rn AppleSmartBattery 2>/dev/null)"
  if [ -z "$IOREG_BATT" ] && ! printf '%s' "$SP_PWR" | grep -q "Cycle Count"; then
    record FAIL "Battery" "Battery" "No battery found"
    BATT_DESC="No battery found"
    return
  fi
  cycles="$(ioreg_val CycleCount)"; is_int "$cycles" || cycles="$(field "$SP_PWR" "Cycle Count")"
  design="$(ioreg_val DesignCapacity)"
  rawmax="$(ioreg_val AppleRawMaxCapacity)"; is_int "$rawmax" || rawmax="$(ioreg_val MaxCapacity)"
  cond="$(field "$SP_PWR" "Condition")"
  maxsp="$(field "$SP_PWR" "Maximum Capacity" | tr -dc '0-9')"
  health=""
  if is_int "$design" && is_int "$rawmax" && [ "$design" -gt 0 ] && [ "$rawmax" -gt 100 ]; then
    health=$(( rawmax * 100 / design ))
  elif is_int "$maxsp"; then
    health="$maxsp"
  fi

  if is_int "$cycles"; then
    if [ "$cycles" -ge 1000 ]; then
      record FAIL "Battery" "Cycle count" "$cycles. This is at or over the 1000-cycle design limit."
    elif [ "$cycles" -ge 800 ]; then
      record WARN "Battery" "Cycle count" "$cycles (design limit 1000)"
    else
      record PASS "Battery" "Cycle count" "$cycles (design limit 1000)"
    fi
  else
    record WARN "Battery" "Cycle count" "Could not read"
  fi

  if is_int "$health"; then
    local hd="$health% of design capacity"
    is_int "$rawmax" && is_int "$design" && [ "$rawmax" -gt 100 ] && hd="$hd ($rawmax of $design mAh)"
    if [ "$health" -lt 80 ]; then
      record FAIL "Battery" "Health" "$hd. Replace the battery, or tell the buyer."
    elif [ "$health" -lt 85 ]; then
      record WARN "Battery" "Health" "$hd"
    else
      record PASS "Battery" "Health" "$hd"
    fi
  else
    record WARN "Battery" "Health" "Could not read the capacity"
  fi

  case "$cond" in
    Normal) record PASS "Battery" "Condition" "Normal";;
    "")     record INFO "Battery" "Condition" "Not reported";;
    *)      record FAIL "Battery" "Condition" "$cond";;
  esac

  pf="$(ioreg_val PermanentFailureStatus)"
  if is_int "$pf" && [ "$pf" -ne 0 ]; then
    record FAIL "Battery" "Permanent failure flag" "The battery reports a permanent failure (code $pf)"
  fi

  btemp="$(ioreg_val Temperature)"
  is_int "$btemp" && record INFO "Battery" "Temperature" "$(awk -v t="$btemp" 'BEGIN { printf "%.1f", t / 100 }') °C"

  chg="$(printf '%s\n' "$SP_PWR" | awk '/AC Charger Information/ { f = 1 } f && /Connected:/ { sub(/.*Connected:[ \t]*/, ""); print; exit }')"
  watt="$(printf '%s\n' "$SP_PWR" | awk -F': ' '/Wattage \(W\)/ { print $2; exit }')"
  if [ "$chg" = "Yes" ] || on_ac; then
    record INFO "Battery" "Charger" "Connected${watt:+, $watt W}"
  else
    record WARN "Battery" "Charger" "Not connected. Connect the charger before the burn-in."
  fi

  lpm="$(pmset -g 2>/dev/null | awk '/lowpowermode/ { print $2; exit }')"
  [ "$lpm" = 1 ] && record WARN "Battery" "Low Power Mode" "On. It limits CPU speed. Turn it off for a valid burn-in (System Settings > Battery)."

  BATT_DESC="${cycles:-?} cycles, ${health:-?}% health${cond:+, $cond}"
}

check_storage() {
  local info smart size_line sm pu spare merr dw pu_n merr_n
  DISK="$(diskutil list internal physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ { print $1; exit }')"
  [ -n "$DISK" ] || DISK="/dev/disk0"
  info="$(diskutil info "$DISK" 2>/dev/null)"
  SSD_NAME="$(field "$info" "Device / Media Name")"
  size_line="$(field "$info" "Disk Size")"
  [ -n "$size_line" ] || size_line="$(field "$info" "Total Size")"
  DISK_BYTES="$(printf '%s' "$size_line" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p')"
  DISK_HUMAN="${size_line%% (*}"
  smart="$(field "$info" "SMART Status")"
  SSD_DESC="${SSD_NAME:-SSD}${DISK_HUMAN:+, $DISK_HUMAN}"
  record INFO "Storage" "Internal SSD" "${SSD_NAME:-unknown} ${DISK_HUMAN:+($DISK_HUMAN)} at $DISK"
  case "$smart" in
    Verified) record PASS "Storage" "SMART status" "Verified";;
    Failing)  record FAIL "Storage" "SMART status" "FAILING. Replace the SSD (on most of these models the SSD is on the logic board).";;
    "")       record INFO "Storage" "SMART status" "Not reported";;
    *)        record INFO "Storage" "SMART status" "$smart";;
  esac

  if command -v smartctl >/dev/null 2>&1; then
    sm="$(sudo_maybe smartctl -a "$DISK" 2>/dev/null)"
    pu="$(field "$sm" "Percentage Used")"
    spare="$(field "$sm" "Available Spare")"
    merr="$(field "$sm" "Media and Data Integrity Errors")"
    dw="$(field "$sm" "Data Units Written")"
    if [ -n "$pu" ]; then
      pu_n="$(printf '%s' "$pu" | tr -dc '0-9')"
      merr_n="$(printf '%s' "$merr" | tr -dc '0-9')"
      local d="Wear $pu, spare ${spare:-?}, media errors ${merr:-?}, written ${dw:-?}"
      if is_int "$merr_n" && [ "$merr_n" -gt 0 ]; then record FAIL "Storage" "SSD wear (smartctl)" "$d"
      elif is_int "$pu_n" && [ "$pu_n" -ge 90 ]; then record FAIL "Storage" "SSD wear (smartctl)" "$d"
      elif is_int "$pu_n" && [ "$pu_n" -ge 70 ]; then record WARN "Storage" "SSD wear (smartctl)" "$d"
      else record PASS "Storage" "SSD wear (smartctl)" "$d"; fi
      SSD_DESC="$SSD_DESC, wear $pu"
    else
      record INFO "Storage" "SSD wear" "smartctl did not read this SSD"
    fi
  else
    record INFO "Storage" "SSD wear" "Not read. Optional: install smartmontools (Homebrew) to see SSD wear."
  fi
}

check_hardware() {
  local mem st_all st_bad disp gpus res cam aud bt st chip ph
  mem="$(system_profiler SPMemoryDataType 2>/dev/null)"
  st_all="$(printf '%s\n' "$mem" | grep -c 'Status:')"
  st_bad="$(printf '%s\n' "$mem" | grep 'Status:' | grep -vc 'OK')"
  if [ "$st_all" -gt 0 ] && [ "$st_bad" -eq 0 ]; then
    record PASS "Hardware" "Memory" "$MEM_GB GB, all banks report OK"
  elif [ "$st_bad" -gt 0 ]; then
    record FAIL "Hardware" "Memory" "$st_bad memory bank(s) do not report OK"
  else
    record INFO "Hardware" "Memory" "$MEM_GB GB (bank status not reported)"
  fi

  disp="$(system_profiler SPDisplaysDataType 2>/dev/null)"
  gpus="$(printf '%s\n' "$disp" | awk -F': ' '/Chipset Model:/ { printf "%s%s", (n++ ? ", " : ""), $2 }')"
  GPU_DESC="$gpus"
  if [ -n "$gpus" ]; then record PASS "Hardware" "Graphics" "$gpus"; else record WARN "Hardware" "Graphics" "No GPU reported"; fi
  if [ "$HAS_DGPU" = 1 ] && ! printf '%s' "$gpus" | grep -Eqi 'radeon|amd'; then
    record FAIL "Hardware" "Discrete GPU" "This model has an AMD GPU, but macOS does not see it. This is a logic board fault."
  fi
  if printf '%s' "$disp" | grep -Eqi 'Built-?in|Connection Type: Internal|Color LCD'; then
    res="$(field "$disp" "Resolution")"
    record PASS "Hardware" "Internal display" "Found${res:+, $res}"
  else
    record FAIL "Hardware" "Internal display" "macOS does not see the internal display"
  fi

  cam="$(system_profiler SPCameraDataType 2>/dev/null)"
  if printf '%s' "$cam" | grep -q "Model ID"; then
    record PASS "Hardware" "Camera" "$(printf '%s\n' "$cam" | awk '/:$/ && !/^Camera:/ { sub(/^[ \t]+/, ""); sub(/:$/, ""); print; exit }')"
  else
    record FAIL "Hardware" "Camera" "No camera found. Possible fault in the camera or the display cable."
  fi

  aud="$(system_profiler SPAudioDataType 2>/dev/null)"
  if printf '%s' "$aud" | grep -Eqi 'Speakers|Internal Speakers|Built-in Output'; then
    record PASS "Hardware" "Speakers (device)" "Found"
  else
    record FAIL "Hardware" "Speakers (device)" "macOS does not see the internal speakers"
  fi
  if printf '%s' "$aud" | grep -Eqi 'Microphone'; then
    record PASS "Hardware" "Microphone (device)" "Found"
  else
    record FAIL "Hardware" "Microphone (device)" "macOS does not see the internal microphone"
  fi

  bt="$(system_profiler SPBluetoothDataType 2>/dev/null)"
  if printf '%s' "$bt" | grep -q "Address:"; then
    st="$(field "$bt" "State")"; [ -n "$st" ] || st="$(field "$bt" "Bluetooth Power")"
    chip="$(field "$bt" "Chipset")"
    if [ "$st" = "On" ]; then
      record PASS "Wireless" "Bluetooth" "Controller found and on${chip:+ ($chip)}"
    else
      record WARN "Wireless" "Bluetooth" "Controller found, state: ${st:-unknown}. Turn Bluetooth on to use it."
    fi
  else
    record FAIL "Wireless" "Bluetooth" "No Bluetooth controller found"
  fi

  [ "$HAS_T2" = 1 ] && record INFO "Hardware" "Security chip" "Apple T2"

  ph="$(sudo_maybe find /Library/Logs/DiagnosticReports -name '*.panic' -mtime -60 2>/dev/null | wc -l | tr -d ' ')"
  if is_int "$ph" && [ "$ph" -gt 0 ]; then
    record WARN "Hardware" "Old kernel panics" "$ph panic report(s) in the last 60 days. Look in /Library/Logs/DiagnosticReports."
  else
    record PASS "Hardware" "Old kernel panics" "None in the last 60 days"
  fi
}

check_wireless() {
  local wifi status sig nets code nq dl ul
  wifi="$(system_profiler SPAirPortDataType 2>/dev/null)"
  if printf '%s' "$wifi" | grep -q "Card Type"; then
    status="$(field "$wifi" "Status")"
    sig="$(field "$wifi" "Signal / Noise")"
    nets="$(printf '%s\n' "$wifi" | awk '/Other Local Wi-Fi Networks:/ { f = 1; next } f && /PHY Mode:/ { c++ } END { print c + 0 }')"
    if [ "$status" = "Connected" ]; then
      record PASS "Wireless" "Wi-Fi" "Connected. Signal / noise: ${sig:-n/a}. Other networks seen: $nets"
    else
      record WARN "Wireless" "Wi-Fi" "Card found, not connected (${status:-unknown}). Other networks seen: $nets. Connect to Wi-Fi to test it."
    fi
  else
    record FAIL "Wireless" "Wi-Fi" "No Wi-Fi card found"
  fi

  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.apple.com/library/test/success.html 2>/dev/null)"
  if [ "$code" = "200" ]; then
    record PASS "Wireless" "Internet" "Connected"
    if command -v networkQuality >/dev/null 2>&1; then
      note "  Wi-Fi speed test (about 20 seconds)..."
      nq="$(run_timeout 60 networkQuality 2>/dev/null)"
      dl="$(printf '%s\n' "$nq" | awk -F': ' '/Downlink capacity/ { print $2; exit }')"
      ul="$(printf '%s\n' "$nq" | awk -F': ' '/Uplink capacity/ { print $2; exit }')"
      if [ -n "$dl" ]; then
        record INFO "Wireless" "Wi-Fi speed" "Down $dl, up ${ul:-?}. This depends on your network and the distance to the router."
      fi
    fi
  else
    record WARN "Wireless" "Internet" "No internet. The Apple Business Manager check and the speed test need it."
  fi
}

# --- 2. Hands-on tests ---------------------------------------------------------
open_page() { open -a Safari "$WORK/$1.html" >/dev/null 2>&1 || open "$WORK/$1.html" >/dev/null 2>&1; }

# Tell a GPU page to stop. The page checks for this file every 5 seconds.
gpu_stop() { [ -n "$WORK" ] && [ -d "$WORK" ] && printf 'window.__burninStop = true;\n' > "$WORK/stop-$1.js" 2>/dev/null; }

screen_test() {
  step "Screen"
  msg "Safari opens a screen test page."
  msg "  1. Click the page one time to go full screen."
  msg "  2. Push Space for the next color. Look at the whole screen for each color."
  msg "  3. Push Esc to leave full screen. Push Cmd+Tab to come back here."
  [ -n "$KNOWN" ] && { printf '%sFor this model, also check:%s\n%s' "$BOLD" "$RST" "$KNOWN"; }
  pause_enter "Push Return to open the page."
  open_page screen
  ask_pf "Hands-on" "Screen" "No dead or stuck pixels, no bright spots, no stains, no lines, even light, and the picture stays stable when you move the lid?"
}

keyboard_test() {
  step "Keyboard and trackpad"
  msg "Safari opens a keyboard and trackpad test page. Click the page one time first."
  msg "  1. Push every key. A key turns green when it works. Orange = it typed twice."
  msg "  2. Hold fn and push F1 to F12 (on Touch Bar models, hold fn to show F1 to F12)."
  msg "  3. Click a key on the page to mark it by hand if macOS uses it (for example some F keys)."
  msg "  4. Do the typing test and each trackpad action in the box."
  msg "  5. Push Cmd+Tab to come back here."
  pause_enter "Push Return to open the page."
  open_page keys
  ask_pf "Hands-on" "Keyboard" "All keys green (or blue), no orange key, and the typing test OK?"
  ask_pf "Hands-on" "Trackpad" "All trackpad actions green, and a push at each corner and the center clicks the same?"
}

make_wav() {
  perl - "$1" "$2" <<'PERL' >/dev/null 2>&1
use strict; use warnings;
my ($file, $mode) = @ARGV;
my $sr = 44100;
my $dur = ($mode eq 'sweep') ? 8 : 1.2;
my $n = int($sr * $dur);
my $fade = int(0.02 * $sr);
my $pi = 3.14159265358979;
my ($phase, $data) = (0, '');
for my $i (0 .. $n - 1) {
  my $t = $i / $sr;
  my $f = ($mode eq 'sweep') ? 100 * (12000 / 100) ** ($t / $dur) : 523.25;
  $phase += 2 * $pi * $f / $sr;
  my $env = 1;
  $env = $i / $fade if $i < $fade;
  $env = ($n - 1 - $i) / $fade if ($n - 1 - $i) < $fade;
  my $s = int(0.5 * 32767 * $env * sin($phase));
  my ($l, $r) = ($mode eq 'left') ? ($s, 0) : ($mode eq 'right') ? (0, $s) : ($s, $s);
  $data .= pack('s<s<', $l, $r);
}
open(my $fh, '>:raw', $file) or die "cannot write $file";
print $fh 'RIFF', pack('V', 36 + length($data)), 'WAVE',
  'fmt ', pack('VvvVVvv', 16, 1, 2, $sr, $sr * 4, 4, 16),
  'data', pack('V', length($data)), $data;
close($fh);
PERL
}

save_volume() {
  VOL_SAVED="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
  MUTE_SAVED="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)"
  is_int "$VOL_SAVED" || VOL_SAVED=""
}

restore_volume() {
  [ -n "$VOL_SAVED" ] || return 0
  osascript -e "set volume output volume $VOL_SAVED" >/dev/null 2>&1
  [ "$MUTE_SAVED" = "true" ] && osascript -e 'set volume with output muted' >/dev/null 2>&1
  VOL_SAVED=""
}

play_lr() {
  if [ -f "$WORK/left.wav" ]; then
    say "Left speaker" 2>/dev/null; afplay "$WORK/left.wav" 2>/dev/null
    say "Right speaker" 2>/dev/null; afplay "$WORK/right.wav" 2>/dev/null
  else
    say "Speaker test. One, two, three." 2>/dev/null
  fi
}

speaker_test() {
  local rc
  step "Speakers"
  make_wav "$WORK/left.wav" left
  make_wav "$WORK/right.wav" right
  make_wav "$WORK/sweep.wav" sweep
  save_volume
  osascript -e 'set volume without output muted' -e 'set volume output volume 70' >/dev/null 2>&1
  msg "The Mac plays a tone on the left speaker, then on the right speaker,"
  msg "then a sweep from low to high. Listen for buzz, rattle, crackle or a dead side."
  pause_enter "Push Return to play."
  while :; do
    play_lr
    say "Sweep" 2>/dev/null
    [ -f "$WORK/sweep.wav" ] && afplay "$WORK/sweep.wav" 2>/dev/null
    ask_pf "Hands-on" "Speakers" "Left tone on the left, right tone on the right, and a clean sweep with no buzz, rattle or crackle?" 1
    rc=$?
    [ $rc -eq 2 ] || break
  done
  restore_volume
}

camera_mic_test() {
  step "Camera and microphone"
  msg "Photo Booth opens. If macOS asks for camera or microphone access, click OK."
  pause_enter "Push Return to open Photo Booth."
  open -a "Photo Booth" >/dev/null 2>&1
  ask_pf "Hands-on" "Camera" "Does Photo Booth show a clear live image, and does the green light next to the camera come on?"
  msg "In Photo Booth, select the video mode (the buttons at the bottom left)."
  msg "Click the red button, speak for 5 seconds, click stop, then play the clip."
  ask_pf "Hands-on" "Microphone" "Is your voice clear in the clip, with no hiss, crackle or very low level?"
  killall "Photo Booth" >/dev/null 2>&1
}

port_test() {
  local n="$CHARGE_PORTS" i label rc base cnt waited line
  step "Ports"
  if [ "$n" -le 0 ]; then
    n="$(ask_int "How many ports can charge this Mac?" 1 4)"
    printf '\n'
  fi
  msg "This test checks that each port charges the Mac. Type s and push Return to skip."
  msg "Disconnect the charger from the Mac now."
  wait_power 0 120; rc=$?
  if [ $rc -eq 2 ]; then record SKIP "Ports" "Charging ports" "Skipped by the tester"; return; fi
  if [ $rc -eq 1 ]; then record WARN "Ports" "Charging ports" "The charger stayed connected, so the test did not run"; return; fi
  i=1
  while [ "$i" -le "$n" ]; do
    label="$(printf '%s' "$PORT_LABELS" | cut -d'|' -f"$i")"
    msg "Connect the charger to port $i of $n${label:+ ($label)}. Waiting..."
    wait_power 1 90; rc=$?
    case $rc in
      0) record PASS "Ports" "Charging port $i${label:+ ($label)}" "The Mac detected the charger";;
      1) record FAIL "Ports" "Charging port $i${label:+ ($label)}" "No charger detected in 90 seconds";;
      2) record SKIP "Ports" "Charging port $i${label:+ ($label)}" "Skipped by the tester";;
    esac
    if [ "$i" -lt "$n" ] && [ $rc -eq 0 ]; then
      msg "Disconnect the charger."
      wait_power 0 90
    fi
    i=$((i + 1))
  done
  msg "Connect the charger again and keep it connected for the rest of the test."
  wait_power 1 120

  printf '\n'
  if ! ask_yn "Do you have a USB device (USB stick, mouse or hub) to test the data function of each port?" n; then
    record SKIP "Ports" "USB data" "No USB device for the test"
    return
  fi
  i=1
  while [ "$i" -le "$DATA_PORTS" ]; do
    label="$(printf '%s' "$DATA_LABELS" | cut -d'|' -f"$i")"
    base="$(usb_count)"
    msg "Connect the USB device to port $i of $DATA_PORTS${label:+ ($label)}. If the charger is in that port, move the charger. Waiting..."
    waited=0; rc=1
    while [ "$waited" -lt 60 ]; do
      cnt="$(usb_count)"
      if [ "$cnt" -gt "$base" ]; then rc=0; break; fi
      if read -t 1 -r line; then case "$line" in s|S) rc=2; break;; esac; fi
      waited=$((waited + 1))
    done
    case $rc in
      0) record PASS "Ports" "USB data, port $i${label:+ ($label)}" "The Mac detected the USB device";;
      1) record FAIL "Ports" "USB data, port $i${label:+ ($label)}" "No USB device detected in 60 seconds";;
      2) record SKIP "Ports" "USB data, port $i${label:+ ($label)}" "Skipped by the tester";;
    esac
    if [ $rc -eq 0 ]; then
      msg "Disconnect the USB device."
      waited=0
      while [ "$waited" -lt 60 ] && [ "$(usb_count)" -gt "$base" ]; do sleep 1; waited=$((waited + 1)); done
    fi
    i=$((i + 1))
  done
  msg "Make sure that the charger is connected."
}

manual_checks() {
  local rc code grade
  step "More hands-on checks"
  ask_pf "Hands-on" "Brightness keys" "Push the brightness keys (or slide brightness on the Touch Bar). Does the screen get darker and brighter?"
  ask_pf "Hands-on" "Keyboard light" "Push the keyboard light keys (or use Control Center). Do all keys light evenly?"
  [ "$HAS_TBAR" = 1 ] && ask_pf "Hands-on" "Touch Bar" "Touch all areas of the Touch Bar. Does it show and respond everywhere, with no dead area or flicker?"
  [ "$HAS_TID" = 1 ] && ask_pf "Hands-on" "Touch ID" "In System Settings > Touch ID & Password, add a fingerprint, then delete it. Does it work?"
  while :; do
    ask_pf "Hands-on" "Headphone jack" "Connect headphones. Type r to play the left and right tones. Do both sides play clearly?" 1
    rc=$?
    [ $rc -eq 2 ] || break
    play_lr
  done
  ask_pf "Hands-on" "Hinge" "Open and close the lid. Does the screen stay at each angle with no noise and no loose feel?"
  ask_pf "Hands-on" "Battery swelling" "Put the Mac on a flat table. It must not rock. Is the bottom case flat, and does the trackpad click normally?"
  printf '\n'
  code="$(ask_text "Apple Diagnostics: restart, hold D. Type the reference code (ADP000 = no issue found), or push Return if you did not run it")"
  code="$(printf '%s' "$code" | tr 'a-z' 'A-Z' | tr -d ' ')"
  printf '\n'
  case "$code" in
    "")     record SKIP "Hands-on" "Apple Diagnostics" "Not run. Restart and hold D to run it (about 3 minutes).";;
    ADP000) record PASS "Hands-on" "Apple Diagnostics" "ADP000 (no issue found)";;
    *)      record FAIL "Hands-on" "Apple Diagnostics" "Reference code $code. Look up this code on Apple's 'Apple Diagnostics reference codes' page.";;
  esac
  grade="$(ask_text "Cosmetic grade and notes (for example: A, small dent on the lid), or push Return to skip")"
  printf '\n'
  [ -n "$grade" ] && record INFO "Hands-on" "Cosmetic grade" "$grade"
}

# --- 3. SSD test ---------------------------------------------------------------
drop_cache() { [ "$HAVE_SUDO" = 1 ] && sudo -n purge >/dev/null 2>&1; }

ssd_verify() {
  local i=0 bad=0
  while [ "$i" -lt "$SSD_CHUNKS" ]; do
    dd if="$SSD_FILE" bs=1048576 skip=$((i * 256)) count=256 2>/dev/null | cmp -s "$WORK/chunk.bin" - || bad=$((bad + 1))
    i=$((i + 1))
  done
  printf '%s' "$bad"
}

ssd_test() {
  local gb="$SSD_GB" free_kb t0 t1 wrc rrc mb w_mbs r_mbs bad i
  step "SSD write and read test"
  free_kb="$(df -k "$WORK" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if is_int "$free_kb" && [ "$free_kb" -lt $(( (gb + 5) * 1048576 )) ]; then
    gb=$(( free_kb / 1048576 - 5 ))
    if [ "$gb" -lt 1 ]; then record SKIP "Storage" "SSD write and read test" "Not enough free space"; return; fi
    warnmsg "Low free space: the test uses $gb GB."
  fi
  SSD_CHUNKS=$(( gb * 4 ))
  SSD_FILE="$WORK/ssd-test.bin"
  mb=$(( SSD_CHUNKS * 256 ))
  msg "Writes $gb GB of random data, reads it back and compares it (about 1 to 3 minutes)."
  if ! dd if=/dev/urandom of="$WORK/chunk.bin" bs=1048576 count=256 2>/dev/null; then
    record FAIL "Storage" "SSD write and read test" "Could not make the test data"; return
  fi
  t0="$(now)"
  i=0
  while [ "$i" -lt "$SSD_CHUNKS" ]; do cat "$WORK/chunk.bin"; i=$((i + 1)); done > "$SSD_FILE" 2>"$WORK/ssd-write.err"
  wrc=$?
  sync
  t1="$(now)"
  if [ $wrc -ne 0 ]; then
    record FAIL "Storage" "SSD write" "Write error: $(head -c 200 "$WORK/ssd-write.err")"
    rm -f "$SSD_FILE"; SSD_FILE=""; return
  fi
  w_mbs="$(mbps "$mb" "$t0" "$t1")"
  drop_cache
  t0="$(now)"
  dd if="$SSD_FILE" of=/dev/null bs=4194304 2>"$WORK/ssd-read.err"
  rrc=$?
  t1="$(now)"
  r_mbs="$(mbps "$mb" "$t0" "$t1")"
  if [ $rrc -ne 0 ]; then
    record FAIL "Storage" "SSD read" "Read error: $(head -c 200 "$WORK/ssd-read.err")"
  fi
  drop_cache
  bad="$(ssd_verify)"
  if [ "$bad" -eq 0 ]; then
    record PASS "Storage" "SSD data check" "$gb GB written and read back with no errors"
  else
    record FAIL "Storage" "SSD data check" "$bad of $SSD_CHUNKS blocks of 256 MB came back different. The SSD corrupts data."
  fi
  local sp="Write about $w_mbs MB/s, read about $r_mbs MB/s"
  [ "$HAVE_SUDO" = 1 ] || sp="$sp (cache not cleared: read speed can be too high)"
  if [ "$w_mbs" -lt 200 ] || [ "$r_mbs" -lt 300 ]; then
    record WARN "Storage" "SSD speed" "$sp. This is much slower than normal for these Macs."
  else
    record PASS "Storage" "SSD speed" "$sp"
  fi
  SSD_DESC="$SSD_DESC, write $w_mbs MB/s, read $r_mbs MB/s"
}

start_fullread() {
  if [ "$HAVE_SUDO" != 1 ]; then
    record SKIP "Storage" "Full SSD read" "Needs the admin password"
    return
  fi
  local rdisk="/dev/r${DISK#/dev/}"
  rm -f "$WORK/fullread.done"
  (
    a="$(now)"
    sudo -n dd if="$rdisk" of=/dev/null bs=4194304 2>"$WORK/fullread.err"
    rc=$?
    b="$(now)"
    echo "$rc $a $b" > "$WORK/fullread.done"
  ) &
  FULLREAD_PID=$!
  logmsg "Full SSD read started on $rdisk"
}

finish_fullread() {
  [ -n "$FULLREAD_PID" ] || return 0
  if [ ! -f "$WORK/fullread.done" ]; then
    msg "Waiting for the full SSD read to finish..."
    wait "$FULLREAD_PID" 2>/dev/null
  fi
  FULLREAD_PID=""
  local rc a b err mb
  read -r rc a b < "$WORK/fullread.done" 2>/dev/null
  err="$(head -c 300 "$WORK/fullread.err" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" = 0 ]; then
    if is_int "$DISK_BYTES"; then
      mb=$(( DISK_BYTES / 1048576 ))
      record PASS "Storage" "Full SSD read" "Read all ${DISK_HUMAN:-of the SSD} with no errors in $(fmt_dur "$(awk -v a="$a" -v b="$b" 'BEGIN { print b - a }')") (about $(mbps "$mb" "$a" "$b") MB/s)"
    else
      record PASS "Storage" "Full SSD read" "Read the whole SSD with no errors"
    fi
  elif printf '%s' "$err" | grep -Eqi 'not permitted|permission denied|resource busy'; then
    record SKIP "Storage" "Full SSD read" "macOS did not allow a raw read. To allow it, give Terminal Full Disk Access (System Settings > Privacy & Security). Reply: $err"
  else
    record FAIL "Storage" "Full SSD read" "Read error: ${err:-exit code $rc}"
  fi
}

# --- 4. Burn-in ----------------------------------------------------------------
start_load() {
  local n="$1" i=0
  while [ "$i" -lt "$n" ]; do
    yes >/dev/null 2>&1 &
    WORKER_PIDS="$WORKER_PIDS $!"
    i=$((i + 1))
  done
}
stop_load() { local p; for p in $WORKER_PIDS; do kill "$p" 2>/dev/null; done; WORKER_PIDS=""; }
alive_workers() { local p c=0; for p in $WORKER_PIDS; do kill -0 "$p" 2>/dev/null && c=$((c + 1)); done; printf '%s' "$c"; }

sample() {
  local pm b
  S_TEMP=""; S_FAN=""; S_PROCHOT=""
  if [ "$HAVE_PM" = 1 ]; then
    pm="$(sudo -n powermetrics --samplers smc -i 1000 -n 1 2>/dev/null)"
    S_TEMP="$(printf '%s\n' "$pm" | awk -F': ' '/CPU die temperature/ { gsub(/[^0-9.]/, "", $2); print $2; exit }')"
    S_FAN="$(printf '%s\n' "$pm" | awk -F': ' '/^Fan/ { gsub(/[^0-9.]/, "", $2); if ($2 + 0 > m) m = $2 + 0; f = 1 } END { if (f) printf "%d", m }')"
    S_PROCHOT="$(printf '%s\n' "$pm" | awk -F': ' '/Number of prochots/ { print $2 + 0; exit }')"
  fi
  S_SPEED="$(pmset -g therm 2>/dev/null | awk -F'=' '/CPU_Speed_Limit/ { gsub(/[^0-9]/, "", $2); print $2; exit }')"
  b="$(pmset -g batt 2>/dev/null)"
  S_BATT="$(printf '%s\n' "$b" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"
  if printf '%s\n' "$b" | head -1 | grep -q "AC Power"; then S_AC=1; else S_AC=0; fi
  IOREG_BATT="$(ioreg -rn AppleSmartBattery 2>/dev/null)"
  S_BTEMP="$(ioreg_val Temperature)"
  if is_int "$S_BTEMP"; then S_BTEMP="$(awk -v t="$S_BTEMP" 'BEGIN { printf "%.1f", t / 100 }')"; else S_BTEMP=""; fi
}

write_sample() { # phase elapsed
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" "$1" \
    "$S_TEMP" "$S_FAN" "$S_SPEED" "$S_PROCHOT" "$S_BATT" "$S_AC" "$S_BTEMP" "$(alive_workers)" >> "$CSV"
}

new_reports() { sudo_maybe find /Library/Logs/DiagnosticReports -newer "$RUN_DIR/.start" -name "$1" 2>/dev/null; }

phase_stats() { # phase -> shell assignments
  awk -F, -v ph="$1" '
    NR > 1 && $3 == ph {
      n++
      if ($4 != "") { tn++; ts += $4; if ($4 > tmax) tmax = $4 }
      if ($5 != "") { fn++; if ($5 > fmax) fmax = $5; if ($2 >= 300 && $5 > fmax2) fmax2 = $5 }
      if ($6 != "") { sn++; ss += $6; if (smin == "" || $6 < smin) smin = $6 }
      if ($7 != "") { if (p0 == "") p0 = $7; p1 = $7 }
      if ($8 != "") { if (b0 == "") b0 = $8; b1 = $8; if (bmin == "" || $8 < bmin) bmin = $8
                      if (pb != "" && pb - $8 > bdrop) bdrop = pb - $8; pb = $8 }
      if ($9 != "") { if (a0 == "") a0 = $9; if (pa == 1 && $9 == 0) drops++; if ($9 == 0) off++; if ($9 == 1) on++; pa = $9 }
      if ($10 != "" && $10 > btmax) btmax = $10
      e1 = $2; if (e0 == "") e0 = $2
    }
    END {
      printf "ST_N=%d\n", n
      printf "ST_TMAX=%s\nST_TAVG=%s\n", (tn ? sprintf("%.0f", tmax) : ""), (tn ? sprintf("%.0f", ts / tn) : "")
      printf "ST_FMAX=%s\nST_FMAX_LOAD=%s\n", (fn ? sprintf("%d", fmax) : ""), (fmax2 != "" ? sprintf("%d", fmax2) : "")
      printf "ST_SMIN=%s\nST_SAVG=%s\n", smin, (sn ? sprintf("%.0f", ss / sn) : "")
      printf "ST_PROCHOT=%s\n", ((p0 != "" && p1 != "") ? p1 - p0 : "")
      printf "ST_B0=%s\nST_B1=%s\nST_BMIN=%s\nST_BDROP=%d\n", b0, b1, bmin, bdrop
      printf "ST_AC0=%s\nST_ACDROPS=%d\nST_OFFAC=%d\nST_ONAC=%d\n", a0, drops, off, on
      printf "ST_BTMAX=%s\n", (btmax != "" ? sprintf("%.0f", btmax) : "")
      printf "ST_E0=%s\nST_E1=%s\n", e0, e1
    }' "$CSV"
}

burnin() {
  local total=$(( BURN_MIN * 60 )) t0 el=0 next_verify="$VERIFY_EVERY_SEC" verify_runs=0 verify_bad=0 bad line rc
  local last_log=0 n_panic n_gpu n_ws alive
  step "Burn-in ($(fmt_dur "$total"))"
  if ! on_ac; then
    warnmsg "The charger is not connected. Connect it now."
    if [ "$AUTO" = 0 ]; then
      msg "Waiting for the charger (type s and push Return to start on battery)..."
      wait_power 1 300
    fi
  fi
  set_state burnin
  IN_BURNIN=1
  STOP_REQUESTED=0
  start_load "$NCPU"
  open_page gpu
  start_fullread
  msg "Full load on $NCPU CPU threads. Safari shows the GPU load page."
  msg "Keep the lid open and the charger connected. You can leave the Mac now."
  msg "To stop early, come back to this window, type q and push Return (or push Ctrl+C)."
  t0="$(date +%s)"
  while [ "$el" -lt "$total" ] && [ "$STOP_REQUESTED" = 0 ]; do
    sample
    el=$(( $(date +%s) - t0 ))
    write_sample burnin "$el"
    set_state burnin
    printf '\r  %s / %s   CPU %s°C   fan %s rpm   speed limit %s%%   battery %s%% %s%s' \
      "$(fmt_dur "$el")" "$(fmt_dur "$total")" "${S_TEMP:-?}" "${S_FAN:-?}" "${S_SPEED:-?}" "${S_BATT:-?}" \
      "$([ "$S_AC" = 1 ] && echo '(charger)' || echo '(BATTERY)')" "$CLR"
    if [ $(( el - last_log )) -ge 600 ]; then
      logmsg "burn-in $(fmt_dur "$el"): cpu ${S_TEMP}C fan ${S_FAN} speed ${S_SPEED}% batt ${S_BATT}% ac ${S_AC}"
      last_log=$el
    fi
    if [ -n "$FULLREAD_PID" ] && [ -f "$WORK/fullread.done" ]; then
      printf '\n'
      finish_fullread
    fi
    if [ "$el" -ge "$next_verify" ] && [ -n "$SSD_FILE" ] && [ -f "$SSD_FILE" ]; then
      printf '\n'
      note "  Reading the SSD test data again..."
      drop_cache
      bad="$(ssd_verify)"
      verify_runs=$((verify_runs + 1))
      verify_bad=$((verify_bad + bad))
      logmsg "SSD re-check $verify_runs: $bad bad blocks"
      next_verify=$((next_verify + VERIFY_EVERY_SEC))
    fi
    [ $(( total - el )) -le 0 ] && break
    if [ -t 0 ]; then
      read -t "$SAMPLE_SEC" -r line; rc=$?
      if [ $rc -eq 0 ]; then case "$line" in q|Q) STOP_REQUESTED=1;; esac; fi
    else
      sleep "$SAMPLE_SEC"
    fi
    el=$(( $(date +%s) - t0 ))
  done
  alive="$(alive_workers)"
  stop_load
  gpu_stop gpu
  IN_BURNIN=0
  BURN_DONE=1
  printf '\n'

  # Results
  eval "$(phase_stats burnin)"
  if [ "$STOP_REQUESTED" = 1 ]; then
    record WARN "Burn-in" "Duration" "Stopped early by the tester after $(fmt_dur "$el") of $(fmt_dur "$total")"
    note "The Safari GPU page stops by itself in a few seconds. If it still runs after 1 minute, close it."
  else
    record PASS "Burn-in" "Duration" "$(fmt_dur "$el") of full load on $NCPU CPU threads, plus GPU load"
  fi
  [ "$alive" -lt "$NCPU" ] && record WARN "Burn-in" "Load workers" "Only $alive of $NCPU load workers ran to the end"

  if [ -n "$ST_TMAX" ]; then
    if [ "$ST_TMAX" -ge 105 ]; then
      record WARN "Burn-in" "CPU temperature" "Max $ST_TMAX °C, average $ST_TAVG °C. This is above the normal limit."
    else
      record INFO "Burn-in" "CPU temperature" "Max $ST_TMAX °C, average $ST_TAVG °C"
    fi
  else
    record INFO "Burn-in" "CPU temperature" "Not available on this Mac or macOS"
  fi

  local fan="$ST_FMAX_LOAD"
  [ -n "$fan" ] || fan="$ST_FMAX"
  if [ "$FANS" = 0 ]; then
    record INFO "Burn-in" "Fan" "This model has no fan"
  elif [ -n "$fan" ]; then
    if [ "$fan" -lt 1000 ]; then
      record FAIL "Burn-in" "Fan" "The fan did not speed up under load (max $fan rpm). Check the fan and its cable."
    elif [ "$fan" -lt 2500 ] && [ -n "$ST_TMAX" ] && [ "$ST_TMAX" -ge 90 ]; then
      record WARN "Burn-in" "Fan" "The fan stayed slow (max $fan rpm) while the CPU was hot ($ST_TMAX °C). Check the fan for dust or damage."
    else
      record PASS "Burn-in" "Fan" "Max $fan rpm under load"
    fi
  else
    record INFO "Burn-in" "Fan" "Not available on this Mac or macOS"
  fi

  if [ -n "$ST_SAVG" ]; then
    local sd="Average CPU speed limit $ST_SAVG%, lowest $ST_SMIN%"
    if [ "$THIN" = 1 ]; then
      record INFO "Burn-in" "Throttling" "$sd. Throttling is normal for this model."
    elif [ "$ST_SAVG" -lt 60 ]; then
      record WARN "Burn-in" "Throttling" "$sd. Heavy throttling. Possible causes: dust, dry thermal paste, fan fault, weak charger, battery fault."
    elif [ "$ST_SMIN" -lt 40 ]; then
      record WARN "Burn-in" "Throttling" "$sd. The CPU slowed down a lot at times."
    else
      record PASS "Burn-in" "Throttling" "$sd"
    fi
  fi
  if is_int "$ST_PROCHOT" && [ "$ST_PROCHOT" -gt 0 ]; then
    record INFO "Burn-in" "PROCHOT events" "$ST_PROCHOT (the CPU was forced to slow down)"
  fi

  if [ "$ST_AC0" = 0 ]; then
    record WARN "Burn-in" "Power" "The burn-in started on battery, not on the charger"
  elif [ "$ST_ACDROPS" -gt 0 ]; then
    record WARN "Burn-in" "Power" "The charger disconnected $ST_ACDROPS time(s) during the burn-in. Check the port, the cable and the charger."
  else
    record PASS "Burn-in" "Power" "The charger stayed connected"
  fi
  if [ "$ST_AC0" = 1 ] && [ "$ST_OFFAC" = 0 ] && is_int "$ST_B0" && is_int "$ST_B1"; then
    if [ "$ST_B1" -lt $(( ST_B0 - 10 )) ]; then
      record WARN "Burn-in" "Charging" "Battery went from $ST_B0% down to $ST_B1% on the charger. The charger is too weak for full load, or the Mac does not charge correctly."
    elif [ "$ST_B0" -lt 90 ] && [ "$ST_B1" -gt "$ST_B0" ]; then
      record PASS "Burn-in" "Charging" "Battery charged from $ST_B0% to $ST_B1% under full load"
    else
      record INFO "Burn-in" "Charging" "Battery $ST_B0% at start, $ST_B1% at end"
    fi
  fi
  [ -n "$ST_BTMAX" ] && record INFO "Burn-in" "Battery temperature" "Max $ST_BTMAX °C"

  n_panic="$(new_reports '*.panic' | wc -l | tr -d ' ')"
  n_gpu="$(new_reports '*.gpuRestart' | wc -l | tr -d ' ')"
  n_ws="$(new_reports 'WindowServer*' | wc -l | tr -d ' ')"
  [ "${n_panic:-0}" -gt 0 ] && record FAIL "Burn-in" "Kernel panic" "$n_panic panic report(s) since the test started"
  [ "${n_gpu:-0}" -gt 0 ] && record FAIL "Burn-in" "GPU restart" "macOS restarted the GPU $n_gpu time(s). This is a GPU fault."
  [ "${n_ws:-0}" -gt 0 ] && record WARN "Burn-in" "Graphics crash" "WindowServer crashed $n_ws time(s)"
  if [ "${n_panic:-0}" = 0 ] && [ "${n_gpu:-0}" = 0 ] && [ "${n_ws:-0}" = 0 ]; then
    record PASS "Burn-in" "Crash reports" "No kernel panic, GPU restart or graphics crash"
  fi

  if [ "$verify_runs" -gt 0 ]; then
    if [ "$verify_bad" -eq 0 ]; then
      record PASS "Burn-in" "SSD data under heat" "Read the test data again $verify_runs time(s) with no errors"
    else
      record FAIL "Burn-in" "SSD data under heat" "$verify_bad bad block(s) in $verify_runs re-read(s). The SSD corrupts data when hot."
    fi
  fi
  finish_fullread
}

battery_rundown() {
  local t0 el=0 line rc why="" tname="Run-down test" load_desc="2 CPU threads busy"
  if [ "$RUNDOWN_FULL" = 1 ]; then
    tname="Run-down test (full load)"
    load_desc="full CPU and GPU load"
    step "Battery stress run-down at full load (down to $RUNDOWN_PCT%)"
    msg "Disconnect the charger now. The Mac runs full CPU and GPU load on battery."
    msg "A weak battery can make the Mac shut down suddenly. If that happens, run the script again: it marks the battery FAIL."
  else
    step "Battery run-down (down to $RUNDOWN_PCT%)"
    msg "Disconnect the charger now. The Mac runs a light load on battery."
  fi
  msg "Type s and push Return to skip this test."
  wait_power 0 300; rc=$?
  if [ $rc -ne 0 ]; then record SKIP "Battery" "$tname" "The charger stayed connected"; return; fi
  set_state battery
  IN_BURNIN=1; STOP_REQUESTED=0
  if [ "$RUNDOWN_FULL" = 1 ]; then
    start_load "$NCPU"
    open_page gpu-rundown
  else
    start_load 2
  fi
  t0="$(date +%s)"
  while [ "$STOP_REQUESTED" = 0 ]; do
    sample
    el=$(( $(date +%s) - t0 ))
    write_sample battery "$el"
    set_state battery
    printf '\r  %s on battery   battery %s%%   CPU %s°C%s' "$(fmt_dur "$el")" "${S_BATT:-?}" "${S_TEMP:-?}" "$CLR"
    if [ "$S_AC" = 1 ]; then why="charger"; break; fi
    if is_int "$S_BATT" && [ "$S_BATT" -le "$RUNDOWN_PCT" ]; then break; fi
    if [ -t 0 ]; then
      read -t 60 -r line; rc=$?
      if [ $rc -eq 0 ]; then case "$line" in q|Q) STOP_REQUESTED=1;; esac; fi
    else
      sleep 60
    fi
  done
  stop_load
  [ "$RUNDOWN_FULL" = 1 ] && gpu_stop gpu-rundown
  IN_BURNIN=0
  printf '\n'
  eval "$(phase_stats battery)"
  local used=$(( ${ST_B0:-0} - ${ST_B1:-0} ))
  local d="$ST_B0% to $ST_B1% in $(fmt_dur "$el")"
  local rate full_h
  if [ "$ST_BDROP" -ge 8 ]; then
    record FAIL "Battery" "$tname" "$d. The charge fell $ST_BDROP% in one minute. The battery reports its charge wrong and can shut down early."
  elif [ "$why" = "charger" ] || [ "$STOP_REQUESTED" = 1 ]; then
    record WARN "Battery" "$tname" "$d. Stopped before $RUNDOWN_PCT% (charger connected or tester stopped it)."
  elif [ "$used" -gt 0 ] && [ "$el" -gt 0 ]; then
    rate="$(awk -v u="$used" -v s="$el" 'BEGIN { printf "%.1f", u / (s / 3600) }')"
    full_h="$(awk -v u="$used" -v s="$el" 'BEGIN { printf "%.1f", 100 / (u / (s / 3600)) }')"
    record PASS "Battery" "$tname" "$d: about $rate% per hour with $load_desc, screen on. A full charge lasts about $full_h hours at this load."
  else
    record INFO "Battery" "$tname" "$d"
  fi
  msg "Connect the charger again."
}

# --- Recovery from a run that did not finish -----------------------------------
cause_text() {
  case "$1" in
    5) echo "normal shutdown";;
    3) echo "hard shutdown, power button held";;
    0) echo "power lost";;
    -3) echo "temperature sensors over limit";;
    -74) echo "battery temperature over limit";;
    -95) echo "CPU temperature over limit";;
    -100) echo "power supply temperature over limit";;
    -103) echo "battery cell voltage too low";;
    -128) echo "unknown, often power or memory";;
    *) echo "see Apple shutdown cause codes";;
  esac
}

check_previous_run() {
  [ -f "$STATE_FILE" ] || return 0
  ST_RUN_DIR=""; ST_PHASE=""; ST_START=""; ST_LAST=""; ST_BATT=""; ST_AC=""
  # shellcheck disable=SC1090
  . "$STATE_FILE" 2>/dev/null
  case "$ST_PHASE" in done|aborted|"") rm -f "$STATE_FILE"; return 0;; esac
  if [ ! -d "$ST_RUN_DIR" ] || ! is_int "$ST_LAST"; then rm -f "$STATE_FILE"; return 0; fi

  step "A test on this Mac did not finish"
  local boot last_h code panics pf pl detail src
  boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ *sec = \([0-9][0-9]*\).*/\1/p')"
  last_h="$(epoch_fmt "$ST_LAST")"
  src="battery"; [ "$ST_AC" = 1 ] && src="the charger"
  RESULTS="$ST_RUN_DIR/results.tsv"
  LOG="$ST_RUN_DIR/log.txt"
  RUN_DIR="$ST_RUN_DIR"
  if is_int "$boot" && [ "$boot" -gt "$ST_LAST" ]; then
    note "  Reading the shutdown cause from the system log (this can take a minute)..."
    code="$(run_timeout 120 sudo_maybe log show --style syslog --start "$last_h" --predicate 'eventMessage contains "Previous shutdown cause"' 2>/dev/null \
            | grep -o 'Previous shutdown cause: -\{0,1\}[0-9]*' | tail -1 | awk '{ print $NF }')"
    detail="The Mac restarted or shut down during the $ST_PHASE phase. Last sign of life: $last_h, battery ${ST_BATT:-?}% on $src."
    [ -n "$code" ] && detail="$detail Shutdown cause $code ($(cause_text "$code"))."
    panics="$(sudo_maybe find /Library/Logs/DiagnosticReports -newer "$ST_RUN_DIR/.start" -name '*.panic' 2>/dev/null | head -3)"
    if [ -n "$panics" ]; then
      pf="$(printf '%s\n' "$panics" | head -1)"
      pl="$(sudo_maybe grep -o 'panic(cpu [0-9]* caller [^"\\]*' "$pf" 2>/dev/null | head -1 | cut -c1-160)"
      detail="$detail Kernel panic report: $(basename "$pf")${pl:+ ($pl)}."
    fi
    record FAIL "Run" "Unexpected restart or shutdown" "$detail"
    if [ "$ST_PHASE" = battery ] && is_int "$ST_BATT" && [ "$ST_BATT" -gt 10 ]; then
      record FAIL "Battery" "Run-down test" "The Mac shut down on battery at about ${ST_BATT}%. The battery cannot hold its charge."
    fi
  else
    record WARN "Run" "Test did not finish" "The test stopped during the $ST_PHASE phase (Terminal closed or script stopped). This is not a hardware fault. Run the test again."
  fi
  render_report "$ST_RUN_DIR"
  copy_to_usb "$ST_RUN_DIR"
  rm -f "$STATE_FILE"
  msg "The report for that test is updated: $ST_RUN_DIR/report.html"
  RESULTS=""; LOG="/dev/null"; RUN_DIR=""
  if [ "$AUTO" = 0 ] && ! ask_yn "Start a new test now?" y; then exit 0; fi
}

# --- 5. Report -----------------------------------------------------------------
render_report() {
  local dir="$1"
  [ -f "$dir/results.tsv" ] || return 0
  (
    set -a
    # shellcheck disable=SC1090
    . "$dir/device.env" 2>/dev/null
    R_FAILS="$(awk -F'\t' '$1 == "FAIL"' "$dir/results.tsv" | wc -l | tr -d ' ')"
    R_WARNS="$(awk -F'\t' '$1 == "WARN"' "$dir/results.tsv" | wc -l | tr -d ' ')"
    if [ "$R_FAILS" -gt 0 ]; then R_VERDICT="FAIL"
    elif [ "$R_WARNS" -gt 0 ]; then R_VERDICT="PASS WITH WARNINGS"
    else R_VERDICT="PASS"; fi
    R_GENERATED="$(date '+%Y-%m-%d %H:%M')"
    set +a

    awk -F'\t' '
      { n++; st[n] = $1; sec[n] = $2; nm[n] = $3; dt[n] = $4; if (!($2 in seen)) { seen[$2] = 1; order[++ns] = $2 } }
      END {
        E["a"] = ""
        print "MAC HARDWARE TEST REPORT"
        print "========================"
        printf "Result:      %s (%d fail, %d warning)\n", ENVIRON["R_VERDICT"], ENVIRON["R_FAILS"], ENVIRON["R_WARNS"]
        printf "Model:       %s\n", ENVIRON["R_MODEL_LONG"]
        printf "Model ID:    %s\n", ENVIRON["R_MODEL_ID"]
        printf "Serial:      %s\n", ENVIRON["R_SERIAL"]
        printf "CPU:         %s (%s threads)\n", ENVIRON["R_CPU"], ENVIRON["R_NCPU"]
        printf "Memory:      %s GB\n", ENVIRON["R_MEM_GB"]
        printf "Storage:     %s\n", ENVIRON["R_SSD_DESC"]
        printf "Graphics:    %s\n", ENVIRON["R_GPU_DESC"]
        printf "Battery:     %s\n", ENVIRON["R_BATT_DESC"]
        printf "macOS:       %s (%s)\n", ENVIRON["R_OS_VER"], ENVIRON["R_OS_BUILD"]
        printf "Firmware:    %s\n", ENVIRON["R_FIRMWARE"]
        printf "Test start:  %s\n", ENVIRON["R_START_HUMAN"]
        printf "Plan:        %s\n", ENVIRON["R_BURN_PLAN"]
        printf "Report made: %s by mac-burnin %s\n", ENVIRON["R_GENERATED"], ENVIRON["R_VERSION"]
        for (i = 1; i <= ns; i++) {
          print ""
          print toupper(order[i])
          for (j = 1; j <= n; j++) if (sec[j] == order[i]) printf "  %-5s %s%s\n", st[j], nm[j], (dt[j] != "" ? ": " dt[j] : "")
        }
      }' "$dir/results.tsv" > "$dir/report.txt"

    awk -F'\t' '
      function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
      function row(k, v) { if (v != "") printf "<tr><th>%s</th><td>%s</td></tr>\n", k, esc(v) }
      { n++; st[n] = $1; sec[n] = $2; nm[n] = $3; dt[n] = $4; if (!($2 in seen)) { seen[$2] = 1; order[++ns] = $2 } }
      END {
        v = ENVIRON["R_VERDICT"]; vc = (v == "FAIL") ? "fail" : ((v == "PASS") ? "pass" : "warn")
        print "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        print "<title>Hardware Test Report " esc(ENVIRON["R_SERIAL"]) "</title><style>"
        print "body{margin:0;background:#f5f5f7;color:#1d1d1f;font:14px/1.45 -apple-system,BlinkMacSystemFont,\"Helvetica Neue\",Arial,sans-serif}"
        print "main{max-width:880px;margin:0 auto;padding:24px 16px 48px}h1{font-size:24px;margin:0 0 2px}"
        print "h2{font-size:13px;margin:26px 0 8px;text-transform:uppercase;letter-spacing:.05em;color:#6e6e73}"
        print ".sub{color:#6e6e73}.card{background:#fff;border-radius:12px;padding:6px 14px;box-shadow:0 1px 2px rgba(0,0,0,.07)}"
        print ".verdict{display:flex;flex-wrap:wrap;align-items:center;gap:12px;margin:18px 0 6px}"
        print ".v{font-size:19px;font-weight:700;padding:8px 14px;border-radius:10px;color:#fff}.v.pass{background:#1f8a4c}.v.warn{background:#b7791f}.v.fail{background:#c53030}"
        print "table{width:100%;border-collapse:collapse}td,th{padding:8px 6px;border-top:1px solid #eee;vertical-align:top;text-align:left}"
        print "tr:first-child td,tr:first-child th{border-top:0}th{width:30%;color:#6e6e73;font-weight:500}"
        print ".b{display:inline-block;min-width:44px;text-align:center;font-size:11px;font-weight:700;padding:2px 6px;border-radius:6px;color:#fff}"
        print ".b.pass{background:#1f8a4c}.b.fail{background:#c53030}.b.warn{background:#b7791f}.b.info{background:#4a6fa5}.b.skip{background:#8e8e93}"
        print "td.st{width:58px}td.nm{width:30%;font-weight:600}.foot{color:#6e6e73;font-size:12px;margin-top:24px}"
        print "@media print{body{background:#fff}.card{box-shadow:none;border:1px solid #ddd}}@media (max-width:600px){td.nm{width:auto}th{width:38%}}"
        print "</style></head><body><main>"
        print "<h1>Hardware Test Report</h1><div class=\"sub\">" esc(ENVIRON["R_MODEL_LONG"]) " &middot; Serial " esc(ENVIRON["R_SERIAL"]) "</div>"
        printf "<div class=\"verdict\"><span class=\"v %s\">%s</span><span class=\"sub\">%d fail, %d warning</span></div>\n", vc, esc(v), ENVIRON["R_FAILS"], ENVIRON["R_WARNS"]
        print "<h2>Device</h2><div class=\"card\"><table>"
        row("Model", ENVIRON["R_MODEL_LONG"]); row("Model identifier", ENVIRON["R_MODEL_ID"]); row("Serial number", ENVIRON["R_SERIAL"])
        row("Processor", ENVIRON["R_CPU"] " (" ENVIRON["R_NCPU"] " threads)"); row("Memory", ENVIRON["R_MEM_GB"] " GB")
        row("Storage", ENVIRON["R_SSD_DESC"]); row("Graphics", ENVIRON["R_GPU_DESC"]); row("Battery", ENVIRON["R_BATT_DESC"])
        row("macOS", ENVIRON["R_OS_VER"] " (" ENVIRON["R_OS_BUILD"] ")"); row("Firmware", ENVIRON["R_FIRMWARE"])
        row("Test started", ENVIRON["R_START_HUMAN"]); row("Test plan", ENVIRON["R_BURN_PLAN"])
        print "</table></div>"
        for (i = 1; i <= ns; i++) {
          print "<h2>" esc(order[i]) "</h2><div class=\"card\"><table>"
          for (j = 1; j <= n; j++) if (sec[j] == order[i])
            printf "<tr><td class=\"st\"><span class=\"b %s\">%s</span></td><td class=\"nm\">%s</td><td>%s</td></tr>\n", tolower(st[j]), esc(st[j]), esc(nm[j]), esc(dt[j])
          print "</table></div>"
        }
        print "<p class=\"foot\">Report made " esc(ENVIRON["R_GENERATED"]) " by mac-burnin " esc(ENVIRON["R_VERSION"]) ". A software test cannot find every fault. Intermittent faults can show later.</p>"
        print "</main></body></html>"
      }' "$dir/results.tsv" > "$dir/report.html"
  )
}

copy_to_usb() {
  local dir="$1" dest
  case "$ORIGIN_DIR" in
    /Volumes/*)
      if [ -d "$ORIGIN_DIR" ] && [ -w "$ORIGIN_DIR" ]; then
        dest="$ORIGIN_DIR/MacBurnIn-reports"
        mkdir -p "$dest" 2>/dev/null && cp -R "$dir" "$dest/" 2>/dev/null \
          && msg "Copy of the report saved on the USB stick: $dest/$(basename "$dir")" \
          || warnmsg "Could not copy the report to the USB stick."
      else
        warnmsg "The USB stick is not connected. The report is only on this Mac: $dir"
      fi;;
  esac
}

finalize() {
  local final_state="${1:-done}" f w
  [ "$FINALIZED" = 1 ] && return 0
  FINALIZED=1
  set_state "$final_state"
  save_device
  render_report "$RUN_DIR"
  step "Result"
  f="$(awk -F'\t' '$1 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
  w="$(awk -F'\t' '$1 == "WARN"' "$RESULTS" | wc -l | tr -d ' ')"
  if [ "$f" -gt 0 ]; then printf '%s%sFAIL%s  (%s fail, %s warning)\n' "$BOLD" "$RED" "$RST" "$f" "$w"
  elif [ "$w" -gt 0 ]; then printf '%s%sPASS WITH WARNINGS%s  (%s warning)\n' "$BOLD" "$YEL" "$RST" "$w"
  else printf '%s%sPASS%s\n' "$BOLD" "$GRN" "$RST"; fi
  awk -F'\t' '$1 == "FAIL" || $1 == "WARN" { printf "  %-4s  %s: %s\n", $1, $3, $4 }' "$RESULTS"
  printf '\n'
  msg "Report: $RUN_DIR/report.html"
  copy_to_usb "$RUN_DIR"
  [ "$final_state" = "done" ] && rm -f "$STATE_FILE"
}

# --- Traps -------------------------------------------------------------------
cleanup() {
  [ "$CLEANED" = 1 ] && return
  CLEANED=1
  stop_load
  if [ -n "$FULLREAD_PID" ]; then
    kill "$FULLREAD_PID" 2>/dev/null
    [ "$HAVE_SUDO" = 1 ] && sudo -n pkill -f "of=/dev/null bs=4194304" >/dev/null 2>&1
  fi
  restore_volume
  [ -n "$WORK" ] && rm -f "$WORK/ssd-test.bin" "$WORK/chunk.bin" "$WORK"/*.wav 2>/dev/null
  [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  gpu_stop gpu
  gpu_stop gpu-rundown
}

on_int() {
  if [ "$IN_BURNIN" = 1 ]; then
    STOP_REQUESTED=1
    printf '\n%sStopping...%s\n' "$YEL" "$RST"
    return
  fi
  printf '\n%sStopped by the tester.%s\n' "$YEL" "$RST"
  if [ -n "$RESULTS" ] && [ -n "$RUN_DIR" ] && [ "$FINALIZED" = 0 ]; then
    record WARN "Run" "Test stopped" "The tester stopped the test before the end (phase: $PHASE)"
    finalize aborted
  fi
  exit 130
}

trap cleanup EXIT
trap on_int INT TERM HUP

# --- The test page (screen, keyboard, trackpad, GPU) ----------------------------
write_pages() {
  cat > "$WORK/page.tpl" <<'HTML_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mac Burn-In Test</title>
<style>
:root { --bg:#141414; --panel:#1f1f1f; --fg:#f2f2f2; --muted:#a0a0a0; --ok:#1f9d55; --manual:#2f6fdb; --warn:#e0a106; --bad:#d93025; }
* { box-sizing:border-box; }
html, body { margin:0; min-height:100%; background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
.hide { display:none !important; }
.muted { color:var(--muted); }
h1 { font-size:22px; margin:0 0 6px; }
h2 { font-size:16px; margin:0 0 10px; }
#menu { max-width:640px; margin:48px auto; padding:0 16px; }
#menu a { display:block; padding:14px 16px; margin:10px 0; background:var(--panel); color:var(--fg); border-radius:8px; text-decoration:none; }
#screen { position:fixed; top:0; left:0; right:0; bottom:0; cursor:none; }
#screenLabel { position:absolute; left:50%; top:50%; transform:translate(-50%,-50%); background:rgba(0,0,0,.8); color:#fff; padding:18px 22px; border-radius:12px; width:min(600px, 90vw); text-align:center; cursor:default; }
#keys { max-width:1060px; margin:0 auto; padding:18px 16px 40px; }
.bar { display:flex; flex-wrap:wrap; gap:8px 18px; align-items:baseline; margin:6px 0 10px; }
.big { font-size:20px; font-weight:600; }
.kb { background:#0b0b0b; padding:10px; border-radius:12px; -webkit-user-select:none; user-select:none; }
.row { display:flex; gap:6px; margin-bottom:6px; }
.k { flex:1 1 0; min-width:0; height:44px; border-radius:6px; background:#2b2b2b; border:1px solid #3a3a3a; display:flex; align-items:center; justify-content:center; font-size:12px; color:#ddd; cursor:pointer; text-align:center; line-height:1.1; padding:0 2px; overflow:hidden; }
.row.fn .k { height:30px; }
.k.ok { background:var(--ok); border-color:var(--ok); color:#fff; }
.k.manual { background:var(--manual); border-color:var(--manual); color:#fff; }
.k.chatter { background:var(--warn); border-color:var(--warn); color:#111; }
.k.na { opacity:.35; cursor:default; }
.k.opt { border-style:dashed; color:#888; }
.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px; }
@media (max-width:820px) { .grid2 { grid-template-columns:1fr; } }
.panel { background:var(--panel); border-radius:12px; padding:14px 16px; }
#pad { -webkit-user-select:none; user-select:none; height:170px; border:2px dashed #555; border-radius:10px; display:flex; align-items:center; justify-content:center; text-align:center; color:var(--muted); margin-bottom:10px; padding:8px; }
.chk { list-style:none; padding:0; margin:0 0 8px; }
.chk li { padding:3px 0; }
.chk li::before { content:"\25CB  "; color:var(--muted); }
.chk li.ok { color:#7ee2a8; }
.chk li.ok::before { content:"\25CF  "; color:var(--ok); }
textarea { width:100%; height:64px; background:#111; color:var(--fg); border:1px solid #444; border-radius:8px; padding:8px; font:16px/1.4 Menlo, monospace; }
.target { font:16px/1.4 Menlo, monospace; background:#111; padding:8px; border-radius:8px; margin-bottom:8px; }
.status-ok { color:#7ee2a8; } .status-warn { color:#ffd166; } .status-bad { color:#ff8a80; }
button { background:#333; color:#fff; border:0; border-radius:8px; padding:7px 12px; font:inherit; cursor:pointer; }
#gpu { position:fixed; top:0; left:0; right:0; bottom:0; background:#000; }
#gpuCanvas { width:100%; height:100%; display:block; }
#gpuInfo { position:absolute; left:12px; top:12px; background:rgba(0,0,0,.72); padding:10px 12px; border-radius:10px; font:13px/1.45 Menlo, monospace; white-space:pre; }
#gpuResult { position:absolute; left:50%; top:50%; transform:translate(-50%,-50%); padding:24px 28px; border-radius:14px; font-size:19px; width:min(640px, 90vw); text-align:center; }
#gpuResult.ok { background:#0e6b3a; } #gpuResult.bad { background:#9b1c1c; } #gpuResult.warn { background:#8a6100; }
</style>
</head>
<body>
<div id="menu" class="hide">
  <h1>Mac Burn-In Test</h1>
  <p class="muted">Select a test.</p>
  <a href="#screen" data-mode="screen">Screen test</a>
  <a href="#keys" data-mode="keys">Keyboard and trackpad test</a>
  <a href="#gpu" data-mode="gpu">GPU stress test</a>
</div>

<div id="screen" class="hide"><div id="screenLabel"></div></div>

<div id="keys" class="hide">
  <h1>Keyboard and trackpad test</h1>
  <div class="bar">
    <span class="big" id="keyCount"></span>
    <span id="chatterInfo" class="muted"></span>
    <button id="showMissing" type="button">Show keys not tested</button>
  </div>
  <p class="muted" id="missing"></p>
  <p class="muted">Push every key one time. A key turns <b>green</b> when it works. <b>Orange</b> = the key typed twice for one push (fault).
    Hold <b>fn</b> to push F1&ndash;F12 (on Touch Bar models, hold fn to show them). The page cannot see the fn key, the power / Touch ID key, or F keys that macOS uses.
    For those, see that the key works, then click it on the page to mark it by hand (<b>blue</b>).</p>
  <div class="kb" id="kb"></div>
  <div class="grid2">
    <div class="panel">
      <h2>Typing test</h2>
      <div class="target" id="target"></div>
      <textarea id="typing" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="Click here and type the line above"></textarea>
      <div id="typingStatus" class="muted">Type the line exactly.</div>
    </div>
    <div class="panel">
      <h2>Trackpad test</h2>
      <div id="pad">Do each action in this box</div>
      <ul class="chk" id="tpList"></ul>
      <div class="muted">Clicks: <span id="clickCount">0</span>. Push the trackpad near each corner and at the center. Each push must click.</div>
    </div>
  </div>
</div>

<div id="gpu" class="hide">
  <canvas id="gpuCanvas"></canvas>
  <div id="gpuInfo"></div>
  <div id="gpuResult" class="hide"></div>
</div>

<script>
(function () {
  'use strict';
  var CFG = { mode: '__MODE__', mins: parseFloat('__MINS__'), stop: '__STOP__' };
  if (CFG.mode.indexOf('__') === 0) { CFG.mode = (location.hash || '#menu').slice(1); }
  if (!(CFG.mins >= 0)) { CFG.mins = 0; }
  if (CFG.stop.indexOf('__') === 0) { CFG.stop = ''; }

  function $(id) { return document.getElementById(id); }
  function show(id) { ['menu', 'screen', 'keys', 'gpu'].forEach(function (s) { $(s).classList.toggle('hide', s !== id); }); }
  function goFull(el) {
    var f = el.requestFullscreen || el.webkitRequestFullscreen;
    if (!f) { return; }
    try { var p = f.call(el); if (p && typeof p.catch === 'function') { p.catch(function () {}); } } catch (e) {}
  }
  function isFull() { return !!(document.fullscreenElement || document.webkitFullscreenElement); }

  /* ---------- Screen ---------- */
  function initScreen() {
    show('screen');
    document.title = 'Screen test';
    var S = [
      ['#ffffff', 'White', 'Look for dark spots, stains and yellow areas. Then close the lid slowly to about 45 degrees and open it fully. The picture must stay stable, and the bottom edge must not show uneven light.'],
      ['#000000', 'Black', 'Look for bright spots, and for light that leaks in at the edges.'],
      ['#ff0000', 'Red', 'Look for pixels that are black or a different color.'],
      ['#00ff00', 'Green', 'Look for pixels that are black or a different color.'],
      ['#0000ff', 'Blue', 'Look for pixels that are black or a different color.'],
      ['#808080', 'Gray', 'Look for areas that are brighter, darker or a different tint.'],
      ['linear-gradient(90deg, #000, #fff)', 'Gradient', 'The change from black to white must be smooth, with no bands.'],
      ['checker', 'Fine pattern', 'Look for lines, flicker, or areas where the pattern is missing.']
    ];
    var i = 0, started = false, el = $('screen'), lab = $('screenLabel'), timer = null, labelOn = true;
    function paint() {
      var s = S[i];
      el.style.background = '';
      el.style.backgroundImage = '';
      el.style.backgroundSize = '';
      if (s[0] === 'checker') {
        el.style.backgroundColor = '#fff';
        el.style.backgroundImage = 'repeating-conic-gradient(#000 0% 25%, #fff 0% 50%)';
        el.style.backgroundSize = '2px 2px';
      } else {
        el.style.background = s[0];
      }
      lab.innerHTML = '<b>' + (i + 1) + ' / ' + S.length + ': ' + s[1] + '</b><br>' + s[2] +
        '<br><span class="muted">Space or click = next. Left arrow = back. I = show or hide this text. Esc = leave full screen.</span>';
      lab.classList.toggle('hide', !labelOn);
      clearTimeout(timer);
      timer = setTimeout(function () { lab.classList.add('hide'); }, 4000);
    }
    function next(d) { i = (i + d + S.length) % S.length; paint(); }
    el.addEventListener('click', function () {
      if (!started) { started = true; goFull(document.documentElement); paint(); return; }
      next(1);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === ' ' || e.key === 'ArrowRight' || e.key === 'Enter') { e.preventDefault(); started = true; next(1); }
      else if (e.key === 'ArrowLeft' || e.key === 'Backspace') { e.preventDefault(); next(-1); }
      else if (e.key === 'i' || e.key === 'I') { labelOn = !labelOn; lab.classList.toggle('hide', !labelOn); clearTimeout(timer); }
      else if (e.key === 'f' || e.key === 'F') { goFull(document.documentElement); }
    });
    el.style.background = '#000';
    lab.innerHTML = '<b>Screen test</b><br>Click to go full screen and start.<br><span class="muted">Then push Space for each next color.</span>';
  }

  /* ---------- Keyboard and trackpad ---------- */
  function initKeys() {
    show('keys');
    document.title = 'Keyboard and trackpad test';
    var CHATTER_MS = 40;
    function letters(s) { return s.split('').map(function (c) { return ['Key' + c, c, 1]; }); }
    var fkeys = [];
    for (var f = 1; f <= 12; f++) { fkeys.push(['F' + f, 'F' + f, 1]); }
    var rows = [
      { cls: 'fn', keys: [['Escape', 'esc', 1.4]].concat(fkeys) },
      { keys: [['Backquote', '`', 1]].concat('1234567890'.split('').map(function (d) { return ['Digit' + d, d, 1]; }))
          .concat([['Minus', '-', 1], ['Equal', '=', 1], ['Backspace', 'delete', 1.5]]) },
      { keys: [['Tab', 'tab', 1.5]].concat(letters('QWERTYUIOP')).concat([['BracketLeft', '[', 1], ['BracketRight', ']', 1], ['Backslash', '\\', 1]]) },
      { keys: [['CapsLock', 'caps lock', 1.8]].concat(letters('ASDFGHJKL')).concat([['Semicolon', ';', 1], ['Quote', "'", 1], ['Enter', 'return', 1.8]]) },
      { keys: [['ShiftLeft', 'shift', 1.3], ['IntlBackslash', 'ISO only', 1, 'opt']].concat(letters('ZXCVBNM'))
          .concat([['Comma', ',', 1], ['Period', '.', 1], ['Slash', '/', 1], ['ShiftRight', 'shift', 2.3]]) },
      { keys: [['_fn', 'fn', 1, 'na'], ['ControlLeft', 'control', 1.1], ['AltLeft', 'option', 1.1], ['MetaLeft', 'command', 1.4],
               ['Space', 'space', 5], ['MetaRight', 'command', 1.4], ['AltRight', 'option', 1.1],
               ['ArrowLeft', '←', 1], ['ArrowUp', '↑', 1], ['ArrowDown', '↓', 1], ['ArrowRight', '→', 1]] }
    ];
    var keyEls = {}, required = [], state = {}, lastUp = {}, chatter = {}, missingOn = false;
    var kb = $('kb');
    rows.forEach(function (r) {
      var row = document.createElement('div');
      row.className = 'row' + (r.cls ? ' ' + r.cls : '');
      r.keys.forEach(function (k) {
        var d = document.createElement('div');
        d.className = 'k' + (k[3] ? ' ' + k[3] : '');
        d.style.flexGrow = k[2];
        d.textContent = k[1];
        d.title = k[0];
        row.appendChild(d);
        if (k[3] === 'na') { return; }
        keyEls[k[0]] = d;
        if (k[3] !== 'opt') { required.push(k[0]); }
        d.addEventListener('click', function () {
          if (!state[k[0]]) { state[k[0]] = 'manual'; d.classList.add('manual'); update(); }
        });
      });
      kb.appendChild(row);
    });
    function showMissing() {
      var m = required.filter(function (c) { return !state[c]; }).map(function (c) { return keyEls[c].textContent; });
      $('missing').textContent = m.length ? 'Not tested yet: ' + m.join('   ') : 'All keys tested.';
    }
    function update() {
      var done = required.filter(function (c) { return state[c]; }).length;
      $('keyCount').textContent = done + ' / ' + required.length + ' keys';
      $('keyCount').className = 'big' + (done === required.length ? ' status-ok' : '');
      var ch = Object.keys(chatter);
      $('chatterInfo').textContent = ch.length
        ? 'Double-typed: ' + ch.map(function (c) { return keyEls[c].textContent + ' (' + chatter[c] + ' ms)'; }).join(', ')
        : 'No double-typed keys';
      $('chatterInfo').className = ch.length ? 'status-warn' : 'muted';
      if (missingOn) { showMissing(); }
    }
    function hit(code) {
      var d = keyEls[code];
      if (!d) { return; }
      if (state[code] !== 'chatter') { state[code] = 'ok'; d.classList.remove('manual'); d.classList.add('ok'); }
      update();
    }
    function flag(code, gap) {
      var d = keyEls[code];
      if (!d) { return; }
      state[code] = 'chatter';
      chatter[code] = gap;
      d.classList.remove('ok');
      d.classList.remove('manual');
      d.classList.add('chatter');
      update();
    }
    document.addEventListener('keydown', function (e) {
      if (e.target !== $('typing')) { e.preventDefault(); }
      if (e.repeat) { return; }
      var t = performance.now();
      if (lastUp[e.code] !== undefined && t - lastUp[e.code] < CHATTER_MS) { flag(e.code, Math.round(t - lastUp[e.code])); return; }
      hit(e.code);
    }, true);
    document.addEventListener('keyup', function (e) {
      lastUp[e.code] = performance.now();
      if (e.code === 'CapsLock') { hit('CapsLock'); }
    }, true);
    $('showMissing').addEventListener('click', function (e) {
      missingOn = !missingOn;
      if (missingOn) { showMissing(); } else { $('missing').textContent = ''; }
      e.currentTarget.blur();
    });

    var TARGET = 'The quick brown fox jumps over the lazy dog 1234567890';
    $('target').textContent = TARGET;
    $('typing').addEventListener('input', function () {
      var v = this.value.replace(/\n/g, ''), st = $('typingStatus'), i = 0;
      while (i < v.length && i < TARGET.length && v.charAt(i) === TARGET.charAt(i)) { i++; }
      if (v === TARGET) { st.textContent = 'Typing test OK.'; st.className = 'status-ok'; }
      else if (i < v.length) {
        st.textContent = 'Wrong character at position ' + (i + 1) + ': expected "' + (TARGET.charAt(i) || '(end)') + '", typed "' + v.charAt(i) +
          '". A double or missing letter can be a key fault. Clear the box and try again.';
        st.className = 'status-bad';
      } else { st.textContent = i + ' / ' + TARGET.length + ' characters correct.'; st.className = 'muted'; }
    });

    var TP = [
      ['click', 'Click'],
      ['right', 'Two-finger click (right click)'],
      ['scrollV', 'Two-finger scroll up and down'],
      ['scrollH', 'Two-finger scroll left and right'],
      ['pinch', 'Pinch with two fingers (zoom)'],
      ['force', 'Force click: push harder until you feel a second click (Safari only; Force Click must be on in Trackpad settings)'],
      ['drag', 'Click, hold and drag about 3 cm']
    ];
    var tpEls = {}, list = $('tpList');
    TP.forEach(function (t) { var li = document.createElement('li'); li.textContent = t[1]; list.appendChild(li); tpEls[t[0]] = li; });
    function tp(k) { if (tpEls[k]) { tpEls[k].classList.add('ok'); } }
    var pad = $('pad'), clicks = 0, drag = null, sv = {}, sh = {};
    pad.addEventListener('mousedown', function (e) {
      if (e.button === 0) { clicks++; $('clickCount').textContent = clicks; tp('click'); drag = { x: e.clientX, y: e.clientY }; }
    });
    document.addEventListener('mousemove', function (e) {
      if (drag && (e.buttons & 1) && Math.abs(e.clientX - drag.x) + Math.abs(e.clientY - drag.y) > 100) { tp('drag'); }
    });
    document.addEventListener('mouseup', function () { drag = null; });
    pad.addEventListener('contextmenu', function (e) { e.preventDefault(); tp('right'); });
    pad.addEventListener('wheel', function (e) {
      e.preventDefault();
      if (e.ctrlKey) { tp('pinch'); return; }
      if (Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
        if (e.deltaY < 0) { sv.a = 1; } if (e.deltaY > 0) { sv.b = 1; }
        if (sv.a && sv.b) { tp('scrollV'); }
      } else {
        if (e.deltaX < 0) { sh.a = 1; } if (e.deltaX > 0) { sh.b = 1; }
        if (sh.a && sh.b) { tp('scrollH'); }
      }
    }, { passive: false });
    ['gesturestart', 'gesturechange'].forEach(function (n) {
      document.addEventListener(n, function (e) {
        e.preventDefault();
        if (pad.contains(e.target) && e.scale && Math.abs(e.scale - 1) > 0.05) { tp('pinch'); }
      });
    });
    pad.addEventListener('webkitmouseforcewillbegin', function (e) { e.preventDefault(); });
    pad.addEventListener('webkitmouseforcedown', function () { tp('force'); });
    update();
  }

  /* ---------- GPU ---------- */
  function initGpu() {
    show('gpu');
    document.title = 'GPU stress test';
    var cv = $('gpuCanvas'), info = $('gpuInfo'), out = $('gpuResult');
    var started = performance.now(), frames = 0, iters = 48, last = 0, fpsT = started, fpsN = 0, fps = 0;
    var finished = false, lost = false, maxGap = 0;
    var endMs = CFG.mins > 0 ? CFG.mins * 60000 : 0;
    function result(kind, html) { out.className = kind; out.innerHTML = html; }
    function mins(ms) { return (ms / 60000).toFixed(1) + ' min'; }
    cv.addEventListener('click', function () { goFull(document.documentElement); });
    var gl = null;
    try {
      gl = cv.getContext('webgl', { powerPreference: 'high-performance', antialias: false, depth: false, stencil: false }) ||
           cv.getContext('experimental-webgl');
    } catch (e) { gl = null; }
    if (!gl) { result('warn', 'WebGL is not available, so the GPU stress test cannot run.<br>The CPU burn-in still runs.'); return; }
    cv.addEventListener('webglcontextlost', function (e) {
      e.preventDefault();
      lost = true;
      result('bad', '<b>FAIL: the GPU stopped</b> (WebGL context lost) after ' + mins(performance.now() - started) +
        '.<br>This can be a GPU or graphics fault. Look in the report for GPU restarts and kernel panics.');
    });
    var vsrc = 'attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }';
    var fsrc = [
      'precision highp float;',
      'uniform vec2 r;',
      'uniform float t;',
      'uniform int n;',
      'void main() {',
      '  vec2 uv = (gl_FragCoord.xy - 0.5 * r) / r.y;',
      '  vec2 p = uv * 4.0;',
      '  float a = 0.0;',
      '  for (int i = 0; i < 1000; i++) {',
      '    if (i >= n) break;',
      '    float fi = float(i) * 0.013;',
      '    p += 0.12 * vec2(sin(p.y * 1.7 + t * 0.6 + fi), cos(p.x * 1.3 - t * 0.45 - fi));',
      '    a += sin(p.x * 0.9) * cos(p.y * 0.7);',
      '  }',
      '  a /= float(n);',
      '  vec3 c = 0.5 + 0.5 * cos(6.2831 * (a * 0.9 + vec3(0.0, 0.33, 0.67)) + t * 0.25);',
      '  gl_FragColor = vec4(c * (0.75 + 0.25 * sin(length(p) * 0.8)), 1.0);',
      '}'
    ].join('\n');
    function compile(type, src) {
      var s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { throw new Error(gl.getShaderInfoLog(s) || 'compile error'); }
      return s;
    }
    var prog;
    try {
      prog = gl.createProgram();
      gl.attachShader(prog, compile(gl.VERTEX_SHADER, vsrc));
      gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fsrc));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { throw new Error(gl.getProgramInfoLog(prog) || 'link error'); }
    } catch (err) {
      result('warn', 'The GPU test did not start: ' + String(err.message || err) + '<br>The CPU burn-in still runs.');
      return;
    }
    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    var loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    var uR = gl.getUniformLocation(prog, 'r'), uT = gl.getUniformLocation(prog, 't'), uN = gl.getUniformLocation(prog, 'n');
    var gpuName = '';
    try { var ext = gl.getExtension('WEBGL_debug_renderer_info'); if (ext) { gpuName = gl.getParameter(ext.UNMASKED_RENDERER_WEBGL); } } catch (e2) {}
    document.addEventListener('visibilitychange', function () { last = 0; });
    function resize() {
      var d = window.devicePixelRatio || 1;
      var w = Math.max(1, Math.floor(cv.clientWidth * d)), h = Math.max(1, Math.floor(cv.clientHeight * d));
      if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
    }
    function drawInfo(now) {
      info.textContent = 'GPU stress test\n' +
        'Time:   ' + mins(now - started) + (endMs ? ' of ' + mins(endMs) : '') + '\n' +
        'FPS:    ' + fps.toFixed(1) + '   load level: ' + iters + '\n' +
        'Frames: ' + frames + (gpuName ? '\nGPU:    ' + gpuName : '') + '\n' +
        (document.hidden ? 'PAUSED: the page is hidden\n' : '') +
        'Keep this window visible. It stops by itself.\nClick for full screen.';
    }
    function frame(now) {
      if (lost || finished) { return; }
      if (last) {
        var dt = now - last;
        if (dt > maxGap && !document.hidden) { maxGap = dt; }
        if (frames > 20) {
          if (dt < 34) { iters = Math.min(1000, Math.ceil(iters * 1.06)); }
          else if (dt > 70) { iters = Math.max(8, Math.floor(iters * 0.85)); }
        }
      }
      last = now;
      resize();
      gl.viewport(0, 0, cv.width, cv.height);
      gl.uniform2f(uR, cv.width, cv.height);
      gl.uniform1f(uT, (now - started) / 1000);
      gl.uniform1i(uN, iters);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      frames++;
      fpsN++;
      if (now - fpsT >= 1000) { fps = fpsN * 1000 / (now - fpsT); fpsN = 0; fpsT = now; drawInfo(now); }
      if (endMs && now - started >= endMs) { finish(now); return; }
      requestAnimationFrame(frame);
    }
    function finish(now) {
      if (finished || lost) { return; }
      finished = true;
      drawInfo(now);
      result('ok', '<b>GPU test complete. The GPU did not stop.</b><br>Ran ' + mins(now - started) + ', ' + frames +
        ' frames. Longest pause: ' + Math.round(maxGap) + ' ms.<br>If you saw lines, blocks or flicker during the test, mark the GPU as failed.');
    }
    // The script writes the stop file when its test phase ends. Check for it every 5 seconds.
    if (CFG.stop) {
      window.__burninStop = false;
      setInterval(function () {
        if (finished || lost) { return; }
        var s = document.createElement('script');
        s.src = CFG.stop + '?t=' + Date.now();
        s.onload = function () { s.parentNode.removeChild(s); if (window.__burninStop) { finish(performance.now()); } };
        s.onerror = function () { s.parentNode.removeChild(s); };
        document.head.appendChild(s);
      }, 5000);
    }
    drawInfo(started);
    requestAnimationFrame(frame);
  }

  if (CFG.mode === 'screen') { initScreen(); }
  else if (CFG.mode === 'keys') { initKeys(); }
  else if (CFG.mode === 'gpu') { initGpu(); }
  else {
    show('menu');
    Array.prototype.forEach.call(document.querySelectorAll('#menu a'), function (a) {
      a.addEventListener('click', function (e) { e.preventDefault(); location.hash = a.getAttribute('data-mode'); location.reload(); });
    });
  }
})();
</script>
</body>
</html>
HTML_EOF
  local m
  for m in screen keys; do
    sed -e "s/__MODE__/$m/" -e "s/__MINS__/$BURN_MIN/" -e "s/__STOP__//" "$WORK/page.tpl" > "$WORK/$m.html"
  done
  # Burn-in GPU page: own timer plus the stop file.
  sed -e "s/__MODE__/gpu/" -e "s/__MINS__/$BURN_MIN/" -e "s/__STOP__/stop-gpu.js/" "$WORK/page.tpl" > "$WORK/gpu.html"
  # Battery stress GPU page: stops on the stop file, or after 10 hours at most.
  sed -e "s/__MODE__/gpu/" -e "s/__MINS__/600/" -e "s/__STOP__/stop-gpu-rundown.js/" "$WORK/page.tpl" > "$WORK/gpu-rundown.html"
  rm -f "$WORK/page.tpl" "$WORK"/stop-*.js
}

# --- Main --------------------------------------------------------------------
main() {
  if [ "$(uname -s)" != "Darwin" ]; then echo "This script runs on macOS only."; exit 1; fi
  printf '%sMac burn-in test %s%s\n' "$BOLD" "$VERSION" "$RST"
  if [ "$(uname -m)" != "x86_64" ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    warnmsg "This script is for Intel Macs. On this Mac, some checks will not work."
  fi

  STATE_DIR="$HOME/Library/Application Support/MacBurnIn"
  mkdir -p "$STATE_DIR" 2>/dev/null
  STATE_FILE="$STATE_DIR/state.env"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/mac-burnin-work.XXXXXX")" || { echo "Cannot make a work folder."; exit 1; }

  msg "The script needs the admin password for the temperature, fan, SSD and lock checks."
  if sudo -v; then
    HAVE_SUDO=1
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
    KEEPALIVE_PID=$!
    if sudo -n powermetrics --samplers smc -i 1000 -n 1 2>/dev/null | grep -q "CPU die temperature"; then HAVE_PM=1; fi
  else
    warnmsg "No admin password. The script skips temperature, fan, cache, firmware password and full SSD read checks."
  fi
  caffeinate -dims -w $$ >/dev/null 2>&1 &
  CAFF_PID=$!

  check_previous_run

  gather_device
  RUN_START="$(date +%s)"
  START_HUMAN="$(date '+%Y-%m-%d %H:%M')"
  local base="$HOME/Desktop/MacBurnIn"
  mkdir -p "$base" 2>/dev/null || base="$HOME/MacBurnIn"
  RUN_DIR="$base/${SERIAL}_$(date '+%Y-%m-%d_%H%M')"
  if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
    base="$HOME/MacBurnIn"; RUN_DIR="$base/${SERIAL}_$(date '+%Y-%m-%d_%H%M')"; mkdir -p "$RUN_DIR" || exit 1
  fi
  RESULTS="$RUN_DIR/results.tsv"; : > "$RESULTS"
  LOG="$RUN_DIR/log.txt"
  CSV="$RUN_DIR/samples.csv"
  echo "time,elapsed_s,phase,cpu_temp_c,fan_rpm,cpu_speed_limit_pct,prochots,battery_pct,on_ac,battery_temp_c,load_workers" > "$CSV"
  touch "$RUN_DIR/.start"

  local plan=""
  [ "$AUTO" = 0 ] && plan="hands-on tests, "
  plan="${plan}SSD test"
  [ "$SKIP_BURNIN" = 0 ] && plan="$plan, $(fmt_dur $((BURN_MIN * 60))) burn-in"
  if [ "$RUNDOWN" = 1 ] && [ "$RUNDOWN_FULL" = 1 ]; then
    plan="$plan, battery stress run-down at full load to $RUNDOWN_PCT%"
  elif [ "$RUNDOWN" = 1 ]; then
    plan="$plan, battery run-down to $RUNDOWN_PCT%"
  fi
  BURN_PLAN="$plan"
  save_device
  set_state checks
  write_pages

  printf '\n%s%s%s\n' "$BOLD" "$MODEL_LONG" "$RST"
  msg "Serial $SERIAL, $CPU, $MEM_GB GB, macOS $OS_VER"
  msg "Plan: automatic checks, $plan."
  [ "$AUTO" = 0 ] && msg "Stay at the Mac for the first 15 minutes. After that, the test runs alone."
  msg "Report folder: $RUN_DIR"
  logmsg "mac-burnin $VERSION started. Options: burn=${BURN_MIN}min auto=$AUTO skip_burnin=$SKIP_BURNIN ssd=${SSD_GB}GB rundown=$RUNDOWN/$RUNDOWN_PCT/full=$RUNDOWN_FULL"

  step "1. Automatic checks"
  [ "$HAVE_PM" = 1 ] || record INFO "Run" "Temperature and fan sensors" "Not available (needs the admin password and an Intel Mac)"
  check_locks
  check_battery
  check_storage
  check_hardware
  check_wireless
  save_device

  if [ "$AUTO" = 0 ]; then
    step "2. Hands-on tests (about 10 to 15 minutes)"
    set_state interactive
    screen_test
    keyboard_test
    speaker_test
    camera_mic_test
    port_test
    manual_checks
  else
    record SKIP "Hands-on" "Hands-on tests" "Skipped (--auto)"
  fi

  set_state ssd
  ssd_test
  save_device

  if [ "$SKIP_BURNIN" = 0 ]; then
    burnin
  else
    record SKIP "Burn-in" "Burn-in" "Skipped (--skip-burnin)"
  fi

  # Ask about the GPU page before the battery test: that test opens a new GPU page.
  if [ "$BURN_DONE" = 1 ] && [ "$AUTO" = 0 ]; then
    printf '\a'
    step "GPU page"
    ask_pf "Burn-in" "GPU (visual)" "Look at the Safari GPU page. Does it show 'GPU test complete' in green, and did you see no lines, blocks or flicker?"
  elif [ "$BURN_DONE" = 1 ]; then
    record INFO "Burn-in" "GPU (visual)" "Not checked (--auto). Look at the Safari GPU page: green = OK, red = GPU fault."
  fi

  [ "$RUNDOWN" = 1 ] && battery_rundown

  rm -f "$SSD_FILE" "$WORK/chunk.bin"
  finalize "done"
  [ "$AUTO" = 0 ] && open "$RUN_DIR/report.html" >/dev/null 2>&1
  note "Before you sell the Mac: erase it (System Settings > General > Transfer or Reset > Erase All Content and Settings, or Recovery)."
}

main
