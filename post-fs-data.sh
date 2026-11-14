#!/system/bin/sh
# Ensure the feature XML has the label SystemConfig expects.
MODDIR="${0%/*}"
FILE="$MODDIR/system/etc/permissions/avf-feature.xml"

[ -f "$FILE" ] || exit 0
if command -v chcon >/dev/null 2>&1; then
    chcon u:object_r:system_file:s0 "$FILE" 2>/dev/null
elif [ -x /system/bin/toybox ]; then
    /system/bin/toybox chcon u:object_r:system_file:s0 "$FILE" 2>/dev/null
fi
exit 0
