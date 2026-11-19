#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
export ASH_STANDALONE=1
exec /data/adb/ksu/bin/busybox sh "$MODDIR/ctl.sh" start opencode2api
