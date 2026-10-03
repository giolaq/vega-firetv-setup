#!/usr/bin/env bash
#
# Guided setup for a Vega OS Fire TV Stick.
#
#   1. Checks the Vega SDK (0.24+, `vega devmode` available)
#   2. Walks you through creating / signing in to an Amazon Developer account
#      and authenticates the Vega CLI (`vega devmode login`)
#   3. Walks you through first-boot setup of the Fire TV Stick
#   4. Enables Developer Mode using the OTP code shown on the TV
#   5. Waits for the reboot and verifies the device is visible to the CLI
#
# Account creation can't be fully automated: Amazon sign-up requires CAPTCHA
# and phone/OTP verification, and automated sign-ups violate the Amazon
# Developer Services terms. The script opens the right pages and waits for you.
#
# Usage:
#   ./setup-firetv.sh [--vendor <VENDOR_ID>] [--skip-account] [--yes] [--no-anim]

set -uo pipefail

MIN_SDK_MAJOR=0
MIN_SDK_MINOR=24
DEVELOPER_PORTAL_URL="https://developer.amazon.com/"
REBOOT_TIMEOUT_SECONDS=180
TOTAL_STEPS=5

VENDOR_ID=""
SKIP_ACCOUNT=false
ASSUME_YES=false
ANIM_FLAG=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vendor) VENDOR_ID="${2:-}"; shift 2 ;;
    --skip-account) SKIP_ACCOUNT=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --no-anim) ANIM_FLAG=false; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- terminal styling ----------

IS_TTY=false
[[ -t 1 ]] && IS_TTY=true
COLOR=$IS_TTY
ANIM=$IS_TTY
[[ "${TERM:-dumb}" == "dumb" ]] && { COLOR=false; ANIM=false; }
[[ -n "${NO_COLOR:-}" ]] && COLOR=false
$ANIM_FLAG || ANIM=false

C256=false
if $COLOR && { [[ "${TERM:-}" == *256color* ]] || [[ -n "${COLORTERM:-}" ]]; }; then
  C256=true
fi

# fg/bg <256-color index> <basic SGR fallback>
fg() { $COLOR || return 0; if $C256; then printf '\033[38;5;%sm' "$1"; else printf '\033[%sm' "$2"; fi; }
bg() { $COLOR || return 0; if $C256; then printf '\033[48;5;%sm' "$1"; else printf '\033[%sm' "$2"; fi; }

RESET="" BOLD=""
if $COLOR; then RESET=$'\033[0m'; BOLD=$'\033[1m'; fi
ORANGE="$(fg 214 33)"
PURPLE="$(fg 141 35)"
CYAN="$(fg 81 36)"
GREEN="$(fg 114 32)"
RED="$(fg 203 31)"
YELLOW="$(fg 221 33)"
GREY="$(fg 244 37)"
FRAME="$(fg 240 90)"
BADGE="$(bg 214 43)$(fg 16 30)$BOLD"
GRADIENT=()
for c in 99 105 141 177 213 211 209 208 214 220; do GRADIENT+=("$(fg "$c" 35)"); done

SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPIN_PID=""
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firetv-setup.XXXXXX")"
PROGRESS=0

cursor_hide() { $IS_TTY && printf '\033[?25l'; return 0; }
cursor_show() { $IS_TTY && printf '\033[?25h'; return 0; }
cursor_up() { printf '\033[%dA' "$1"; }
nap() { $ANIM && sleep "$1"; return 0; }

on_interrupt() {
  [[ -n "$SPIN_PID" ]] && kill "$SPIN_PID" 2>/dev/null
  printf '\r\033[2K\n  %s✗ Aborted.%s\n' "$RED" "$RESET"
  exit 130
}
trap 'cursor_show; printf "%s" "$RESET"' EXIT
trap on_interrupt INT

# rep <string> <count>
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

# Visible length of a string, ignoring ANSI color codes.
vis_len() { local s; s="$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')"; echo "${#s}"; }

# ---------- output helpers ----------

info() { printf '  %s\n' "$*"; }
ok() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s▲%s %s\n' "$YELLOW" "$RESET" "$*"; }
hint() { printf '  %s%s%s\n' "$GREY" "$*" "$RESET"; }
rule() { printf '  %s%s%s\n' "$FRAME" "$(rep ┄ 62)" "$RESET"; }

type_out() {
  local text=$1 color=$2 i
  printf '%s' "$color"
  if $ANIM; then
    for ((i = 0; i < ${#text}; i++)); do printf '%s' "${text:i:1}"; sleep 0.012; done
  else
    printf '%s' "$text"
  fi
  printf '%s\n' "$RESET"
}

# card <border color> <title> <line>...
card() {
  local color=$1 title=$2 line len max=0 iw
  shift 2
  for line in "$@"; do len=$(vis_len "$line"); (( len > max )) && max=$len; done
  iw=$(( max + 2 ))
  (( iw < ${#title} + 4 )) && iw=$(( ${#title} + 4 ))
  printf '  %s╭─ %s%s%s%s %s╮%s\n' "$color" "$BOLD" "$title" "$RESET" "$color" "$(rep ─ $(( iw - ${#title} - 3 )))" "$RESET"
  for line in "$@"; do
    len=$(vis_len "$line")
    printf '  %s│%s %s%*s %s│%s\n' "$color" "$RESET" "$line" $(( iw - 2 - len )) '' "$color" "$RESET"
    nap 0.02
  done
  printf '  %s╰%s╯%s\n' "$color" "$(rep ─ "$iw")" "$RESET"
}

fail() {
  local lines=() l
  while IFS= read -r l; do lines+=("$l"); done < <(printf '%s\n' "$*" | fold -s -w 64)
  printf '\n'
  card "$RED" "Setup stopped" "${lines[@]}"
  hint "Logs: $LOG_DIR"
  exit 1
}

show_log_tail() {
  local l
  while IFS= read -r l; do printf '    %s│%s %s\n' "$FRAME" "$RESET" "$l"; done < <(tail -n 15 "$1")
  hint "Full log: $1"
}

# ---------- prompts ----------

confirm() {
  if $ASSUME_YES; then
    printf '  %s?%s %s %syes%s\n' "$PURPLE" "$RESET" "$1" "$GREEN" "$RESET"
    return 0
  fi
  local answer
  printf '  %s?%s %s%s%s %s(y/N)%s ' "$PURPLE" "$RESET" "$BOLD" "$1" "$RESET" "$GREY" "$RESET"
  read -r answer </dev/tty
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause() {
  printf '  %s⏎%s %sPress Enter when done%s ' "$CYAN" "$RESET" "$GREY" "$RESET"
  read -r _ </dev/tty
}

open_url() {
  printf '  %s↗%s Opening %s%s%s\n' "$CYAN" "$RESET" "$CYAN" "$1" "$RESET"
  if command -v open >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  else info "Open this URL in your browser: $1"
  fi
}

# ---------- animations ----------

SCREEN_W=36
SCREEN_H=7
TV_LINES=$(( SCREEN_H + 7 ))
TAGLINE="F I R E   T V   S E T U P"
LOGO=(
  '__     _______ ____    _    '
  '\ \   / / ____/ ___|  / \   '
  ' \ \ / /|  _|| |  _  / _ \  '
  '  \ V / | |__| |_| |/ ___ \ '
  '   \_/  |_____\____/_/   \_\'
)

# screen_row <mode> <arg> <row>: prints exactly SCREEN_W visible characters.
screen_row() {
  local mode=$1 arg=$2 row=$3 s="" i left
  case $mode in
    line)
      if (( row == SCREEN_H / 2 )); then
        left=$(( (SCREEN_W - arg) / 2 ))
        printf '%*s%s%s%s%*s' "$left" '' "$BOLD" "$(rep ━ "$arg")" "$RESET" $(( SCREEN_W - arg - left )) ''
      else
        printf '%*s' "$SCREEN_W" ''
      fi ;;
    static)
      local chars=(' ' ' ' '.' ':' '░' '▒' '▓')
      for ((i = 0; i < SCREEN_W; i++)); do s+="${chars[RANDOM % 7]}"; done
      printf '%s%s' "$GREY" "$s" ;;
    logo)
      if (( row >= 1 && row <= 5 && row <= arg )); then
        printf '%s%s%*s%-32s' "${GRADIENT[row + 2]}" "$BOLD" 4 '' "${LOGO[row - 1]}"
      elif (( row == 6 && arg >= 6 )); then
        left=$(( (SCREEN_W - ${#TAGLINE}) / 2 ))
        printf '%s%*s%-*s' "$ORANGE" "$left" '' $(( SCREEN_W - left )) "$TAGLINE"
      else
        printf '%*s' "$SCREEN_W" ''
      fi ;;
    *) printf '%*s' "$SCREEN_W" '' ;;
  esac
}

# tv_frame <mode> <arg> <power LED color>
tv_frame() {
  local mode=$1 arg=$2 led=$3 r mid=$(( (SCREEN_W + 8) / 2 ))
  printf '%s%*s%s%s\n' "$FRAME" $(( mid - 4 )) '' '\     /' "$RESET"
  printf '%s%*s%s%s\n' "$FRAME" $(( mid - 3 )) '' '\___/' "$RESET"
  printf '  %s╭%s╮%s\n' "$FRAME" "$(rep ─ $(( SCREEN_W + 4 )))" "$RESET"
  printf '  %s│ ╭%s╮ │%s\n' "$FRAME" "$(rep ─ "$SCREEN_W")" "$RESET"
  for ((r = 0; r < SCREEN_H; r++)); do
    printf '  %s│ │%s%s%s%s│ │%s\n' "$FRAME" "$RESET" "$(screen_row "$mode" "$arg" "$r")" "$RESET" "$FRAME" "$RESET"
  done
  printf '  %s│ ╰%s╯ │%s\n' "$FRAME" "$(rep ─ "$SCREEN_W")" "$RESET"
  printf '  %s╰%s %s●%s %s─╯%s\n' "$FRAME" "$(rep ─ "$SCREEN_W")" "$led" "$RESET" "$FRAME" "$RESET"
  printf '%s%*s%s%s\n' "$FRAME" $(( mid - 5 )) '' '▀▀▀▀▀▀▀▀▀▀' "$RESET"
}

# A CRT-style power-on: dark screen, scanline, static, then the logo.
banner() {
  local n
  printf '\n'
  if $ANIM; then
    cursor_hide
    tv_frame off 0 "$RED"; sleep 0.35
    for n in 2 6 12 20 28 36; do cursor_up "$TV_LINES"; tv_frame line "$n" "$YELLOW"; sleep 0.03; done
    for n in 1 2 3 4 5; do cursor_up "$TV_LINES"; tv_frame static 0 "$YELLOW"; sleep 0.07; done
    for n in 1 2 3 4 5 6; do cursor_up "$TV_LINES"; tv_frame logo "$n" "$GREEN"; sleep 0.07; done
    cursor_show
  else
    tv_frame logo 6 "$GREEN"
  fi
  printf '\n  '; type_out "Vega OS Fire TV Stick · guided developer setup" "$BOLD"
  printf '  '; type_out "SDK check › developer account › first boot › Developer Mode" "$GREY"
}

progress_bar() {
  local pct=$1 width=32 filled i bar=""
  filled=$(( pct * width / 100 ))
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then bar+="${GRADIENT[i * ${#GRADIENT[@]} / width]}█"; else bar+="${FRAME}░"; fi
  done
  printf '\r  %s%s %s%3d%%%s' "$bar" "$RESET" "$GREY" "$pct" "$RESET"
}

progress_to() {
  local target=$1 p=$PROGRESS
  if $ANIM; then
    cursor_hide
    while (( p < target )); do
      p=$(( p + 2 )); (( p > target )) && p=$target
      progress_bar "$p"; sleep 0.012
    done
    cursor_show
  fi
  progress_bar "$target"
  printf '\n\n'
  PROGRESS=$target
}

step() {
  printf '\n  %s STEP %s/%s %s %s%s%s\n' "$BADGE" "$1" "$TOTAL_STEPS" "$RESET" "$BOLD" "$2" "$RESET"
  progress_to $(( $1 * 100 / TOTAL_STEPS ))
}

# spin_run <message> <log file> <command>...: runs the command with a spinner
# and its output captured to the log. Returns the command's exit code.
spin_run() {
  local msg=$1 log=$2 i=0 start=$SECONDS rc
  shift 2
  if ! $ANIM; then
    info "$msg..."
    "$@" >"$log" 2>&1 </dev/null
    return $?
  fi
  "$@" >"$log" 2>&1 </dev/null &
  SPIN_PID=$!
  cursor_hide
  while kill -0 "$SPIN_PID" 2>/dev/null; do
    printf '\r\033[2K  %s%s%s %s %s%ss%s' "${GRADIENT[i % ${#GRADIENT[@]}]}" "${SPIN_FRAMES[i % 10]}" "$RESET" \
      "$msg" "$GREY" $(( SECONDS - start )) "$RESET"
    i=$(( i + 1 )); sleep 0.08
  done
  wait "$SPIN_PID"; rc=$?
  SPIN_PID=""
  printf '\r\033[2K'
  cursor_show
  return $rc
}

# Shows the 7 Select presses that unlock Developer options.
press_demo() {
  $ANIM || return 0
  local k dots
  cursor_hide
  for ((k = 0; k <= 7; k++)); do
    dots="$ORANGE$(rep '● ' "$k")$FRAME$(rep '○ ' $(( 7 - k )))$RESET"
    printf '\r\033[2K    %s[ Select ]%s  %s' "$BOLD" "$RESET" "$dots"
    sleep 0.12
  done
  printf ' %sYou are now a developer!%s\n\n' "$GREEN" "$RESET"
  cursor_show
}

# Big boxed rendering of the OTP code, one tile at a time.
show_code() {
  local code=$1 k i top mid bot
  cursor_hide
  for ((k = 1; k <= ${#code}; k++)); do
    $ANIM || k=${#code}
    top="" mid="" bot=""
    for ((i = 0; i < k; i++)); do
      top+="╭───╮ "
      mid+="│ ${ORANGE}${BOLD}${code:i:1}${RESET}${PURPLE} │ "
      bot+="╰───╯ "
    done
    (( k > 1 )) && $ANIM && cursor_up 3
    printf '    %s%s%s\n    %s%s%s\n    %s%s%s\n' "$PURPLE" "$top" "$RESET" "$PURPLE" "$mid" "$RESET" "$PURPLE" "$bot" "$RESET"
    nap 0.06
  done
  cursor_show
}

celebrate() {
  $ANIM || return 0
  local rows=7 cols=58 f r c line sparks=('✦' '✧' '*' '+' '·' '•')
  cursor_hide
  for ((f = 0; f < 16; f++)); do
    for ((r = 0; r < rows; r++)); do
      line=""
      for ((c = 0; c < cols; c++)); do
        if (( RANDOM % 9 == 0 )); then line+="${GRADIENT[RANDOM % 10]}${sparks[RANDOM % 6]}"; else line+=" "; fi
      done
      printf '\033[2K  %s%s\n' "$line" "$RESET"
    done
    sleep 0.07
    cursor_up "$rows"
  done
  for ((r = 0; r < rows; r++)); do printf '\033[2K\n'; done
  cursor_up "$rows"
  cursor_show
}

# ---------- device helpers ----------

# Prints the serial numbers of connected Fire TV devices (one per line),
# excluding the Vega Virtual Device.
list_device_serials() {
  vega device list 2>/dev/null \
    | awk -F' : ' 'NF >= 2 { gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1 }' \
    | grep -v -i 'virtualdevice' || true
}

# Polls `vega device list` in the background while animating. Sets SERIAL.
wait_for_device() {
  local deadline=$(( SECONDS + REBOOT_TIMEOUT_SECONDS )) start=$SECONDS i=0 j w
  local next_poll=$SECONDS poll_pid="" found="" out="$LOG_DIR/serials.log"
  local wave=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▇ ▆ ▅ ▄ ▃ ▂)
  $ANIM || info "Waiting for the Fire TV to come back online (up to ${REBOOT_TIMEOUT_SECONDS}s)..."
  cursor_hide
  while (( SECONDS < deadline )); do
    if [[ -z "$poll_pid" ]] && (( SECONDS >= next_poll )); then
      list_device_serials >"$out" 2>/dev/null &
      poll_pid=$!
    fi
    if [[ -n "$poll_pid" ]] && ! kill -0 "$poll_pid" 2>/dev/null; then
      wait "$poll_pid"; poll_pid=""
      found="$(head -n1 "$out")"
      [[ -n "$found" ]] && break
      next_poll=$(( SECONDS + 5 ))
    fi
    if $ANIM; then
      w=""
      for ((j = 0; j < 12; j++)); do w+="${wave[(i + j) % 14]}"; done
      printf '\r\033[2K  %s%s%s Waiting for the Fire TV to come back online  %s%s%s  %s%ss / %ss%s' \
        "$ORANGE" "${SPIN_FRAMES[i % 10]}" "$RESET" "$PURPLE" "$w" "$RESET" \
        "$GREY" $(( SECONDS - start )) "$REBOOT_TIMEOUT_SECONDS" "$RESET"
      i=$(( i + 1 )); sleep 0.1
    else
      sleep 1
    fi
  done
  [[ -n "$poll_pid" ]] && kill "$poll_pid" 2>/dev/null
  $ANIM && printf '\r\033[2K'
  cursor_show
  SERIAL="$found"
}

finish() {
  # Fill the bar when steps 4–5 were skipped for an already-enabled device.
  printf '\n'
  (( PROGRESS < 100 )) && progress_to 100
  celebrate
  card "$GREEN" "You're all set" \
    "Device serial (DSN)  ${BOLD}${ORANGE}$SERIAL${RESET}" \
    "" \
    "${GREY}Shell${RESET}     vega device shell -d $SERIAL" \
    "${GREY}Install${RESET}   vega device install-app --packagePath <app.vpkg>"
  printf '\n'
}

# ================================================================
#  Main
# ================================================================

banner

# ---------- 1. SDK ----------

step 1 "Check the Vega SDK"

if ! command -v vega >/dev/null 2>&1 && [[ -f "$HOME/vega/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/vega/env"
fi
command -v vega >/dev/null 2>&1 \
  || fail "vega CLI not found. Install the Vega SDK 0.24 first: https://developer.amazon.com/docs/vega/0.24/install-vega-sdk.html"

spin_run "Reading the active Vega SDK version" "$LOG_DIR/version.log" vega --version
sdk_version="$(sed -n 's/^Active SDK Version: *//p' "$LOG_DIR/version.log")"
[[ -n "$sdk_version" ]] || fail "Could not read the active SDK version from 'vega --version'."
IFS=. read -r sdk_major sdk_minor _ <<<"$sdk_version"
if (( sdk_major < MIN_SDK_MAJOR || (sdk_major == MIN_SDK_MAJOR && sdk_minor < MIN_SDK_MINOR) )); then
  fail "Active SDK is $sdk_version; this setup needs $MIN_SDK_MAJOR.$MIN_SDK_MINOR+. Run 'vega sdk install 0.24.12112 && vega sdk use 0.24.12112'."
fi
ok "Vega SDK ${BOLD}$sdk_version${RESET}"

spin_run "Checking for 'vega devmode'" "$LOG_DIR/devmode.log" vega devmode --help \
  || fail "'vega devmode' isn't available in this SDK. Update the Vega SDK and run 'vega update'."
ok "'vega devmode' available"

# ---------- 2. Developer account + CLI login ----------

step 2 "Amazon Developer account"

if ! $SKIP_ACCOUNT; then
  if confirm "Already have an Amazon Developer account with a vendor profile?"; then
    ok "Using your existing account"
  else
    printf '\n'
    card "$ORANGE" "Create your Amazon Developer account" \
      "${ORANGE}1${RESET}  Select ${BOLD}Sign in${RESET} > ${BOLD}Create your Amazon Developer account${RESET}" \
      "${ORANGE}2${RESET}  Complete the email and phone verification" \
      "${ORANGE}3${RESET}  Fill in the developer profile (company name, address)" \
      "   This creates your vendor ID." \
      "" \
      "${YELLOW}!${RESET}  Use the ${BOLD}same${RESET} Amazon account on the Fire TV Stick."
    open_url "$DEVELOPER_PORTAL_URL"
    pause
  fi
fi

printf '\n'
card "$CYAN" "Login with Amazon" \
  "The Vega CLI opens your browser. Select ${BOLD}Allow${RESET} to authorize it." \
  "${GREY}If you're already logged in, this is skipped.${RESET}"
rule
vega devmode login
login_status=$?
rule
case $login_status in
  0) ok "Logged in" ;;
  2) ok "Already logged in ${GREY}(run 'vega devmode logout' to switch accounts)${RESET}" ;;
  *) fail "'vega devmode login' failed (exit $login_status). Re-run the script to retry." ;;
esac

# ---------- 3. Fire TV Stick first-boot ----------

step 3 "Fire TV Stick first-boot setup"

SERIAL=""
spin_run "Looking for devices already in Developer Mode" "$LOG_DIR/devices.log" list_device_serials
existing_serials="$(cat "$LOG_DIR/devices.log")"
if [[ -n "$existing_serials" ]]; then
  ok "Developer Mode already active on: ${BOLD}$(echo "$existing_serials" | tr '\n' ' ')${RESET}"
  if confirm "Skip enabling Developer Mode and continue with this device?"; then
    SERIAL="$(echo "$existing_serials" | head -n1)"
  fi
fi

if [[ -z "$SERIAL" ]]; then
  card "$ORANGE" "On the Fire TV Stick (use the remote from the box)" \
    "${ORANGE}1${RESET}  Plug the stick into the TV (HDMI) and a wall adapter" \
    "   ${GREY}Computer USB can underpower it and make it restart.${RESET}" \
    "${ORANGE}2${RESET}  Press ${BOLD}[ Home ]${RESET} to pair the remote, then ${BOLD}[ Play/Pause ]${RESET}" \
    "${ORANGE}3${RESET}  Pick a language, join the same Wi-Fi as this machine" \
    "${ORANGE}4${RESET}  Let the OTA updates finish. Don't unplug the stick." \
    "${ORANGE}5${RESET}  Sign in with your Amazon Developer account"
  confirm "Is the stick on the Home screen and signed in?" || pause

  # ---------- 4. Developer Mode ----------

  step 4 "Enable Developer Mode"
  card "$PURPLE" "On the Fire TV" \
    "${ORANGE}1${RESET}  Settings > My Fire TV > About" \
    "${ORANGE}2${RESET}  Highlight the device name, press ${BOLD}[ Select ]${RESET} 7 times" \
    "${ORANGE}3${RESET}  Back > Developer options > Developer Mode > Continue" \
    "" \
    "${YELLOW}!${RESET}  A 6-character code appears. It expires in 5 minutes."
  printf '\n'
  press_demo

  while true; do
    printf '  %s›%s Code shown on the TV %s(q to quit)%s: ' "$ORANGE" "$RESET" "$GREY" "$RESET"
    read -r otp </dev/tty
    [[ "$otp" == "q" ]] && exit 1
    otp="$(echo "$otp" | tr -d ' -' | tr '[:lower:]' '[:upper:]')"
    if [[ ! "$otp" =~ ^[A-Z0-9]{6}$ ]]; then
      warn "Expected 6 letters/digits, got '$otp'."
      continue
    fi
    printf '\n'
    show_code "$otp"
    printf '\n'

    enable_args=(devmode enable-device --code "$otp")
    if [[ -n "$VENDOR_ID" ]]; then
      enable_args+=(--vendor "$VENDOR_ID")
      spin_run "Sending the code to Amazon Developer Services" "$LOG_DIR/enable.log" vega "${enable_args[@]}"
      enable_status=$?
    else
      # Without --vendor the CLI may ask you to pick a vendor, so run it in the foreground.
      rule
      vega "${enable_args[@]}" </dev/tty
      enable_status=$?
      rule
    fi

    case $enable_status in
      0) ok "Device enabled. It's rebooting now."; break ;;
      2|3)
        warn "CLI session missing or expired. Logging in again..."
        vega devmode logout >/dev/null 2>&1
        vega devmode login || fail "Login failed."
        info "Request a new code on the TV, then enter it." ;;
      4) fail "No vendor profile on this account. Complete the developer profile at $DEVELOPER_PORTAL_URL and re-run." ;;
      6) warn "Code invalid or expired. On the TV choose ${BOLD}Request a New Code${RESET} and try again." ;;
      *)
        [[ -f "$LOG_DIR/enable.log" ]] && show_log_tail "$LOG_DIR/enable.log"
        fail "'vega devmode enable-device' failed (exit $enable_status)." ;;
    esac
  done

  # ---------- 5. Wait for reboot ----------

  step 5 "Wait for the reboot"
  wait_for_device
  [[ -n "$SERIAL" ]] || fail "Device not visible after ${REBOOT_TIMEOUT_SECONDS}s. Check Settings > Developer options > Developer Mode shows 'Enabled', connect the stick to this machine over USB, and run 'vega device list'."
fi

ok "Fire TV ready: ${BOLD}${ORANGE}$SERIAL${RESET}"
if spin_run "Reading device info" "$LOG_DIR/info.log" vega device info -d "$SERIAL"; then
  info_lines=()
  while IFS= read -r l; do [[ -n "$l" ]] && info_lines+=("${GREY}$(printf '%s' "$l" | cut -c1-64)${RESET}"); done \
    < <(head -n 8 "$LOG_DIR/info.log")
  (( ${#info_lines[@]} > 0 )) && card "$FRAME" "Device info" "${info_lines[@]}"
fi

finish
