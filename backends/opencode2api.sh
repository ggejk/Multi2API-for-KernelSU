# Sourced by ctl.sh. Keep the original config path for existing installs.
BIN="$MODDIR/bin/opencode2api"
CONFIG="$DATA_DIR/config.json"
CONFIG_EXAMPLE="$MODDIR/configs/opencode2api.example.json"
WORK_DIR="$DATA_DIR"

backend_exec() {
  # Newer Android versions supply the current CA store via Conscrypt APEX.
  if [ -z "${SSL_CERT_DIR:-}" ] && [ -d /apex/com.android.conscrypt/cacerts ]; then
    export SSL_CERT_DIR=/apex/com.android.conscrypt/cacerts
  fi
  exec "$BIN" -config "$CONFIG"
}
