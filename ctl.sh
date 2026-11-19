#!/system/bin/sh
# Run with KernelSU BusyBox ash (requires flock). See README.md for commands.
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
MODDIR=$(CDPATH='' cd -- "$MODDIR" && pwd -P) || exit 1
DATA_DIR=${MULTI2API_DATA_DIR:-/data/adb/Multi2API-for-Kernelsu}
umask 077

usage() {
  printf '%s\n' 'Usage: ctl.sh {init|start|stop|restart|status|logs} [opencode2api]' >&2
  exit 2
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
ACTION=$1
BACKEND=${2:-opencode2api}
case "$ACTION" in init|start|stop|restart|status|logs) ;; *) usage ;; esac
# Only source installed, explicitly registered adapters.
case "$BACKEND" in opencode2api) ;; *) fail "Unknown backend: $BACKEND" ;; esac
case "$DATA_DIR" in /*) ;; *) fail 'Data directory must be an absolute path.' ;; esac
. "$MODDIR/backends/$BACKEND.sh" || exit 1

LOG_DIR="$DATA_DIR/logs"
RUN_DIR="$DATA_DIR/run"
LOG="$LOG_DIR/$BACKEND.log"
PID_FILE="$RUN_DIR/$BACKEND.pid"

prepare_dirs() {
  mkdir -p "$LOG_DIR" "$RUN_DIR" && chmod 700 "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"
}

init_config() {
  if [ ! -e "$CONFIG" ]; then
    config_dir=${CONFIG%/*}
    mkdir -p "$config_dir" || return 1
    config_tmp=$(mktemp "$config_dir/.config.XXXXXX") || return 1
    if ! { cp "$CONFIG_EXAMPLE" "$config_tmp" && mv -f "$config_tmp" "$CONFIG"; }; then
      rm -f "$config_tmp"
      return 1
    fi
    printf 'Created %s; configure API keys before starting.\n' "$CONFIG"
  fi
  [ -f "$CONFIG" ] && chmod 600 "$CONFIG"
}

# /proc/PID/stat field 22 stays the same across exec. Strip comm (field 2),
# which can contain spaces and parentheses; field 22 then becomes field 20.
pid_start_time() (
  IFS= read -r statline <"/proc/$1/stat" || exit 1
  set -f
  set -- ${statline##*) }
  [ "$#" -ge 20 ] && [ "$1" != Z ] || exit 1
  printf '%s\n' "${20}"
) 2>/dev/null

is_managed_pid() {
  case "$1" in ''|0*|1|*[!0-9]*) return 1 ;; esac
  current_start=$(pid_start_time "$1") || return 1
  [ "$current_start" = "$2" ] || return 1
  exe=$(readlink "/proc/$1/exe") || return 1
  case "$exe" in "$BIN"|"$BIN (deleted)") return 0 ;; *) return 1 ;; esac
}

load_pid() {
  [ -f "$PID_FILE" ] || return 1
  read -r managed_pid managed_start saved_boot <"$PID_FILE" || return 1
  [ "$saved_boot" = "$BOOT_ID" ] && is_managed_pid "$managed_pid" "$managed_start"
}

record() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
  printf '%s\n' "$*"
}

rotate_log() {
  if [ -f "$LOG" ]; then
    size=$(wc -c <"$LOG") || return 1
    if [ "$size" -ge 5242880 ]; then
      mv -f "$LOG" "$LOG.1" || return 1
    fi
  fi
  touch "$LOG" && chmod 600 "$LOG"
}

start_backend() {
  if [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
    fail 'This module is disabled or scheduled for removal.'
  fi
  if load_pid; then
    printf '%s is already running (PID %s).\n' "$BACKEND" "$managed_pid"
    return 0
  fi
  rm -f "$PID_FILE" || fail 'Cannot clear stale PID file.'
  [ -x "$BIN" ] || fail "Binary is missing or not executable: $BIN"
  init_config || fail "Cannot initialize configuration: $CONFIG"
  rotate_log || fail "Cannot open log: $LOG"
  record "Starting $BACKEND with $CONFIG"

  (
    exec 9>&-
    trap '' HUP
    cd "$WORK_DIR" || exit 1
    backend_exec
  ) </dev/null >>"$LOG" 2>&1 &
  new_pid=$!
  if ! new_start=$(pid_start_time "$new_pid"); then
    record "$BACKEND exited during startup. See $LOG"
    return 1
  fi
  if ! printf '%s %s %s\n' "$new_pid" "$new_start" "$BOOT_ID" >"$PID_FILE"; then
    # Still our own child; do not leave an untracked service running.
    if [ "$(pid_start_time "$new_pid")" = "$new_start" ]; then
      kill -TERM "$new_pid" 2>/dev/null
    fi
    fail "Cannot write PID file: $PID_FILE"
  fi
  sleep 1
  if ! is_managed_pid "$new_pid" "$new_start"; then
    rm -f "$PID_FILE"
    record "$BACKEND did not stay running. See $LOG"
    return 1
  fi
  record "$BACKEND is running (PID $new_pid)."
}

stop_backend() {
  if ! load_pid; then
    rm -f "$PID_FILE" || fail 'Cannot clear stale PID file.'
    printf '%s is not running.\n' "$BACKEND"
    return 0
  fi
  if ! kill -TERM "$managed_pid" 2>/dev/null && is_managed_pid "$managed_pid" "$managed_start"; then
    fail "Cannot stop $BACKEND (PID $managed_pid)."
  fi
  remaining=20
  while is_managed_pid "$managed_pid" "$managed_start"; do
    [ "$remaining" -gt 0 ] || fail "$BACKEND did not stop within 20 seconds; no force kill was sent."
    sleep 1
    remaining=$((remaining - 1))
  done
  rm -f "$PID_FILE" || fail 'Cannot clear PID file.'
  record "$BACKEND stopped."
}

if [ "$ACTION" = logs ]; then
  [ -f "$LOG" ] || fail "No log yet: $LOG"
  exec tail -n 80 "$LOG"
fi

# A shared per-backend lock serializes install, boot, and manual commands.
prepare_dirs || fail "Cannot prepare data directory: $DATA_DIR"
exec 9>"$RUN_DIR/$BACKEND.lock"
flock -x 9 || fail 'Cannot acquire service lock (KernelSU BusyBox flock is required).'
if [ "$ACTION" = init ]; then
  init_config || fail "Cannot initialize configuration: $CONFIG"
  exit 0
fi
IFS= read -r BOOT_ID </proc/sys/kernel/random/boot_id || fail 'Cannot read current boot ID.'
[ -n "$BOOT_ID" ] || fail 'Current boot ID is empty.'

case "$ACTION" in
  start) start_backend ;;
  stop) stop_backend ;;
  restart) stop_backend && start_backend ;;
  status)
    if load_pid; then
      printf '%s is running (PID %s).\n' "$BACKEND" "$managed_pid"
    else
      printf '%s is not running.\n' "$BACKEND"
      exit 1
    fi
    ;;
esac
