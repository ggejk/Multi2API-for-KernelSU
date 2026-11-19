# Sourced by the KernelSU installer after extraction.
[ "${KSU:-}" = true ] || abort "! This module requires KernelSU."
[ "${ARCH:-}" = arm64 ] || abort "! This build requires an arm64 Android device."

set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/ctl.sh" 0 0 0755
set_perm "$MODPATH/bin/opencode2api" 0 0 0755
[ -x "$MODPATH/bin/opencode2api" ] || abort "! Missing executable: bin/opencode2api"

if ! ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh "$MODPATH/ctl.sh" init opencode2api; then
  abort "! Failed to initialize the persistent configuration."
fi
ui_print "- Config (kept across updates): /data/adb/Multi2API-for-Kernelsu/config.json"
ui_print "- Set local and upstream API keys before starting."
ui_print "- Reboot to start opencode2api automatically."
