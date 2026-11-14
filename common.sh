#!/system/bin/sh
# ============================================================
# Serenity AVF enabler - shared install logic
# Author: Auroxion
# ============================================================
# This file is sourced both from update-binary (recovery / manager
# flash) and customize.sh (Magisk-native flow). It expects:
#   ui_print <msg>   and   abort <msg>   to already exist
#   MODPATH          = staging module dir
# and performs, in order:
#   1. Deep Serenity device verification (ROM spoof resistant)
#   2. Android version check (>= 15)
#   3. AVF framework availability check
#   4. Combined warning + volume-key confirmation if anything is off
#   5. DTBO scan -> backup to /sdcard -> patch -> flash (all slots)
#   6. pm enable com.android.virtualization.terminal (Android env)
# ============================================================

TMPD="/data/local/tmp/serenity-avf"
mkdir -p "$TMPD" 2>/dev/null
[ -d "$TMPD" ] || { TMPD="/tmp/serenity-avf"; mkdir -p "$TMPD"; }

STATUS_FILE="/data/adb/serenity-avf-status"
PATCHED_SLOTS=""
WARN_COUNT=0

# ---------- helpers ----------
tolower() { echo "$1" | tr 'A-Z' 'a-z'; }

gprop() { tolower "$(getprop "$1" 2>/dev/null)"; }

# getprop fallback that also greps build.prop files (needed in recovery)
prop_from_files() {
    grep -s "^$1=" \
        /system/build.prop /system/system/build.prop \
        /system_root/system/build.prop \
        /vendor/build.prop /system/vendor/build.prop \
        /system_root/system/vendor/build.prop \
        /product/build.prop /odm/build.prop /mi_ext/build.prop \
        2>/dev/null | head -n 1 | cut -d= -f2
}
gprop2() {
    local v
    v="$(gprop "$1")"
    [ -z "$v" ] && v="$(prop_from_files "$1")"
    tolower "$(echo "$v" | tr -d '\r')"
}

# Volume key confirmation. Prints: UP / DOWN / TIMEOUT
wait_volume_key() {
    local secs="${1:-15}" out="/tmp/avf_keyscan" res="" ev ge i=0
    : > "$out" 2>/dev/null
    ge="$(command -v getevent)"
    [ -x "$ge" ] || [ -x /system/bin/getevent ] || { echo "TIMEOUT"; return; }
    [ -x "$ge" ] || ge=/system/bin/getevent
    for ev in /dev/input/event*; do
        "$ge" -ql "$ev" >> "$out" 2>/dev/null &
    done
    while [ "$i" -lt "$secs" ]; do
        if grep -q "KEY_VOLUMEUP" "$out" 2>/dev/null; then res=UP; break; fi
        if grep -q "KEY_VOLUMEDOWN" "$out" 2>/dev/null; then res=DOWN; break; fi
        sleep 1; i=$((i + 1))
    done
    # kill leftover getevent children
    pkill -f "getevent -ql" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    echo "${res:-TIMEOUT}"
}

confirm_or_abort() {
    ui_print " "
    ui_print " ! VOLUME CONFIRMATION REQUIRED"
    ui_print "   Vol+ = continue installation anyway"
    ui_print "   Vol- = abort installation"
    local k
    k="$(wait_volume_key 15)"
    case "$k" in
        UP)   ui_print " - Continuing at your own risk." ;;
        DOWN) abort "Installation cancelled by user (Vol-)." ;;
        *)    abort "No key press detected (timeout). Installation aborted." ;;
    esac
}

# ---------- check 1: Unisoc UMS9230 / T615 SoC check ----------
check_device() {
    ui_print "- Verifying SoC identity (CPU/platform check)..."
    local dt_model dt_compat dt_scid platform hardware cpuinfo evidence=""

    # Use hardware/SoC identifiers only. Do not require the commercial
    # device codename, Xiaomi branding, fingerprint, or product properties.
    dt_model="$(tolower "$(cat /proc/device-tree/model 2>/dev/null)")"
    dt_compat="$(tolower "$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ')")"
    dt_scid="$(tolower "$(cat /proc/device-tree/sprd,sc-id 2>/dev/null | tr '\0' ' ')")"
    platform="$(tolower "$(gprop2 ro.board.platform)")"
    hardware="$(tolower "$(gprop2 ro.hardware)$(gprop2 ro.boot.hardware)")"
    cpuinfo="$(tolower "$(cat /proc/cpuinfo 2>/dev/null)")"

    [ -n "$dt_model" ] && ui_print "   dt model       : $dt_model"
    [ -n "$dt_compat" ] && ui_print "   dt compatible  : $dt_compat"
    [ -n "$dt_scid" ] && ui_print "   dt sc-id       : $dt_scid"
    [ -n "$platform" ] && ui_print "   board platform : $platform"
    [ -n "$hardware" ] && ui_print "   hardware       : $hardware"

    # UMS9230 is the SoC platform used by the Unisoc T615 family.
    # T615/T616 aliases are accepted where a ROM exposes the marketing name.
    case "$dt_model$dt_compat$dt_scid$platform$hardware$cpuinfo" in
        *ums9230*|*t615*|*t616*|*ums9230hs*) evidence="matched" ;;
    esac

    if [ "$evidence" = "matched" ]; then
        ui_print " - SoC: Unisoc UMS9230 / T615 family detected"
        return 0
    fi

    ui_print " ! WARNING: could not identify a supported Unisoc UMS9230 / T615 SoC"
    ui_print "   No matching SoC/platform identifier was found."
    WARN_COUNT=$((WARN_COUNT + 1))
    return 1
}

# ---------- check 2: Android >= 15 ----------
check_android_version() {
    local sdk
    sdk="$(gprop2 ro.build.version.sdk)"
    if [ -z "$sdk" ]; then
        ui_print " ! WARNING: could not determine Android version (recovery mode?)"
        WARN_COUNT=$((WARN_COUNT + 1)); return 1
    fi
    ui_print " - Android SDK level: $sdk"
    if [ "$sdk" -ge 35 ]; then
        return 0
    fi
    ui_print " ! WARNING: Android $sdk < 15 (SDK 35). AVF Terminal requires Android 15+."
    WARN_COUNT=$((WARN_COUNT + 1)); return 1
}

# ---------- check 3: AVF framework present on system ----------
check_avf_framework() {
    local f found=0
    for f in /apex/com.android.virt \
             /system/apex/com.android.virt.apex \
             /system_ext/apex/com.android.virt.apex \
             /product/apex/com.android.virt.apex \
             /vendor/apex/com.android.virt.apex \
             /system_root/system/apex/com.android.virt.apex \
             /system_root/system/system_ext/apex/com.android.virt.apex; do
        if [ -e "$f" ]; then found=1; ui_print " - AVF framework found: $f"; break; fi
    done
    if [ "$found" = 0 ] && command -v pm >/dev/null 2>&1; then
        if pm list packages 2>/dev/null | grep -q "^package:com.android.virt"; then
            found=1; ui_print " - AVF framework found: package com.android.virt"
        fi
    fi
    if [ "$found" = 1 ]; then return 0; fi
    ui_print " ! WARNING: com.android.virt (AVF framework) not found on this system."
    ui_print "   A custom/ripped ROM may lack AVF; the module feature XML alone"
    ui_print "   cannot provide virtualization services."
    WARN_COUNT=$((WARN_COUNT + 1)); return 1
}

# ---------- DTBO stage ----------
dtbo_backup_dir() {
    local d
    for d in /sdcard /storage/emulated/0 /data/media/0 /mnt/media_rw/*; do
        if [ -d "$d" ] && touch "$d/.avf_wtest" 2>/dev/null; then
            rm -f "$d/.avf_wtest"
            echo "$d/AVF-Enabler-backup"
            return
        fi
    done
    echo ""
}

dtbo_find_blocks() {
    DTBO_BLOCKS=""
    local p
    for p in /dev/block/by-name/dtbo_a /dev/block/by-name/dtbo_b \
             /dev/block/platform/*/by-name/dtbo_a \
             /dev/block/platform/*/by-name/dtbo_b \
             /dev/block/by-name/dtbo \
             /dev/block/platform/*/by-name/dtbo; do
        [ -b "$p" ] && DTBO_BLOCKS="$DTBO_BLOCKS $p"
    done
    DTBO_BLOCKS="$(echo $DTBO_BLOCKS | tr ' ' '\n' | sort -u | tr '\n' ' ')"
}

dtbo_tag() { tolower "$(basename "$1")"; }

patch_one_dtbo() {
    local blk="$1" bdir="$2" tag bak
    tag="$(dtbo_tag "$blk")"
    ui_print "- Inspecting dtbo [$tag] ($blk)"
    if ! dd if="$blk" of="$TMPD/dtbo_$tag.img" bs=4096 2>/dev/null; then
        ui_print "  ! cannot read $blk - skipped"; return 1
    fi
    if ! grep -q -a "kvm-arm.mode" "$TMPD/dtbo_$tag.img" 2>/dev/null; then
        ui_print "  - no kvm-arm.mode token in dtbo [$tag]; nothing to do"
        return 0
    fi
    if ! grep -q -a "kvm-arm.mode=none" "$TMPD/dtbo_$tag.img" 2>/dev/null; then
        ui_print "  - kvm-arm.mode present but blocker '=none' absent; leaving as-is"
        return 0
    fi
    # blocker confirmed -> backup BEFORE touching anything
    bak="$bdir/dtbo_${tag}-original-$(date +%Y%m%d-%H%M%S).img"
    if ! cp "$TMPD/dtbo_$tag.img" "$bak" 2>/dev/null; then
        ui_print "  ! BACKUP FAILED - refusing to modify dtbo [$tag]"
        return 1
    fi
    ui_print "  - blocker 'kvm-arm.mode=none' found; original backed up to:"
    ui_print "    $bak"
    # blank every occurrence with 18 spaces (length-preserving, zero layout change)
    SP18="                  "
    grep -a -b -o "kvm-arm.mode=none" "$TMPD/dtbo_$tag.img" | cut -d: -f1 | \
    while read -r o; do
        [ -n "$o" ] || continue
        printf '%s' "$SP18" | dd of="$TMPD/dtbo_$tag.img" bs=1 seek="$o" conv=notrunc 2>/dev/null
    done
    # verify before flashing
    if grep -q -a "kvm-arm.mode=none" "$TMPD/dtbo_$tag.img" 2>/dev/null; then
        ui_print "  ! verification failed after patching; NOT flashing dtbo [$tag]"
        ui_print "    (your original backup is safe at $bak)"
        return 1
    fi
    if ! dd if="$TMPD/dtbo_$tag.img" of="$blk" bs=4096 2>/dev/null; then
        ui_print "  ! FAILED writing patched dtbo back to $blk"
        ui_print "    (your original backup is safe at $bak)"
        return 1
    fi
    ui_print "  - dtbo [$tag] patched and flashed: 'kvm-arm.mode=none' removed"
    PATCHED_SLOTS="$PATCHED_SLOTS $tag"
    return 0
}

dtbo_stage() {
    local bdir
    bdir="$(dtbo_backup_dir)"
    if [ -z "$bdir" ]; then
        ui_print " ! WARNING: no writable storage found for DTBO backup."
        ui_print "   Cannot safely patch DTBO without a backup - SKIPPING DTBO stage."
        WARN_COUNT=$((WARN_COUNT + 1))
        return 1
    fi
    mkdir -p "$bdir" 2>/dev/null
    dtbo_find_blocks
    if [ -z "$DTBO_BLOCKS" ]; then
        ui_print " ! WARNING: no dtbo block found on this device - skipping DTBO stage."
        WARN_COUNT=$((WARN_COUNT + 1))
        return 1
    fi
    ui_print "- Using backup directory: $bdir"
    local b
    for b in $DTBO_BLOCKS; do
        patch_one_dtbo "$b" "$bdir"
    done
    return 0
}

# ---------- Terminal package ----------
enable_terminal() {
    ui_print "- Enabling Android Terminal VM package..."
    if ! command -v pm >/dev/null 2>&1; then
        ui_print "  (recovery environment: will enable at first boot via service.sh)"
        return 0
    fi
    if pm list packages 2>/dev/null | grep -q "^package:com.android.virtualization.terminal"; then
        if pm enable com.android.virtualization.terminal >/dev/null 2>&1; then
            ui_print " - 'pm enable com.android.virtualization.terminal' executed OK"
        else
            ui_print " ! pm enable failed now; service.sh will retry at boot"
        fi
    else
        ui_print " ! package com.android.virtualization.terminal not found on this ROM;"
        ui_print "   enable step skipped (AVF Terminal app absent)."
    fi
}

write_status() {
    {
        echo "serenity-avf-enabler install: $(date)"
        echo "patched_dtbo_slots:${PATCHED_SLOTS:- none}"
    } > "$STATUS_FILE" 2>/dev/null
}

# ---------- main ----------
avf_install() {
    ui_print " "
    ui_print "  Serenity AVF enabler v2.0  -  by Auroxion"
    ui_print " "
    WARN_COUNT=0
    PATCHED_SLOTS=""

    check_device
    check_android_version
    check_avf_framework

    if [ "$WARN_COUNT" -gt 0 ]; then
        ui_print " "
        ui_print " ! $WARN_COUNT warning(s) raised (non-Serenity / unsupported config)."
        confirm_or_abort
    fi

    dtbo_stage
    enable_terminal
    write_status

    ui_print " "
    ui_print " - Done. Reboot required for DTBO + VM support to take effect."
    ui_print " - After reboot check: ls -l /dev/kvm ; getprop ro.boot.hypervisor.vm.supported"
}
