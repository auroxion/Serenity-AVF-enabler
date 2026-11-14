# Serenity AVF Enabler

A KernelSU/Magisk module that enables Android Virtualization Framework (AVF) support and the Android Terminal VM package on supported Unisoc devices.

## Target devices

Designed for the Xiaomi Serenity family using the Unisoc UMS9230 / T615 SoC, including Redmi A5 / A7 and POCO derivatives. Other devices are not recommended; installation requires explicit volume-key confirmation when checks raise a warning.

## Installation

1. Flash the ZIP using KernelSU or Magisk Manager.
2. If prompted, press **Volume Up** to continue or **Volume Down** to abort. No key press within 15 seconds aborts installation.
3. Reboot.

## What it does

During installation, the module:

- Checks for UMS9230 / T615-family identifiers in device-tree, board-platform, hardware, and CPU information. It does not rely on the device codename, Xiaomi/Redmi branding, or build fingerprint.
- Requires Android 15 or newer (SDK 35+).
- Checks that the AVF framework (`com.android.virt`) is present.
- Checks DTBO images for `kvm-arm.mode=none`. When found, it backs up the original DTBO before clearing the value in place and verifying the result.
- Enables `com.android.virtualization.terminal`.

At each boot, `service.sh` sets `ro.boot.hypervisor.vm.supported` to `1`, retries enabling the Terminal VM package, and writes results to `/data/adb/serenity-avf.log`.

## Troubleshooting

Inspect the module log and basic KVM / AVF state:

```sh
su -c 'cat /data/adb/serenity-avf.log'
su -c 'ls -l /dev/kvm'
getprop ro.boot.hypervisor.vm.supported
pm has-feature android.software.virtualization_framework
```

## Rollback

1. Disable or remove the module in KernelSU / Magisk Manager.
2. Restore the original DTBO backup from `AVF-Enabler-backup` on internal storage to each DTBO slot that was modified.
3. Reboot.

**Warning:** Keep the original DTBO backup. Do not restore a backup to a different device or flash a DTBO image to a slot that was not modified by this module.
