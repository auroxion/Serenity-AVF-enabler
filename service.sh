#!/system/bin/sh
# Serenity AVF enabler - boot service
# 1. Declare non-protected VM support for the AVF framework.
# 2. Enable the Android Terminal VM package (retry for recovery installs).
MODDIR="${0%/*}"
LOG=/data/adb/serenity-avf.log

exec >> "$LOG" 2>&1
echo "=== Serenity AVF enabler boot: $(date) ==="
[ -f /data/adb/serenity-avf-status ] && cat /data/adb/serenity-avf-status

if command -v resetprop >/dev/null 2>&1; then
    resetprop ro.boot.hypervisor.vm.supported 1
    echo "ro.boot.hypervisor.vm.supported=$(getprop ro.boot.hypervisor.vm.supported)"
else
    echo "ERROR: resetprop not found in service.sh PATH"
fi

if command -v pm >/dev/null 2>&1; then
    if pm list packages 2>/dev/null | grep -q "^package:com.android.virtualization.terminal"; then
        pm enable com.android.virtualization.terminal >/dev/null 2>&1 \
            && echo "com.android.virtualization.terminal enabled" \
            || echo "WARNING: pm enable failed"
    else
        echo "NOTE: com.android.virtualization.terminal package not present"
    fi
fi

if [ -e /dev/kvm ]; then
    echo "RESULT: /dev/kvm present - VM support active"
else
    echo "RESULT: /dev/kvm MISSING - kernel KVM or bootloader hypervisor not active"
fi
exit 0
