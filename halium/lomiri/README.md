# Halium-style Lomiri Bring-up Notes (AIDL Variant)

This directory contains the **scaffolding** that the Ubuntu Touch shell
(Lomiri / Mir) needs once `ubuntu-gsi-launcher` has chrooted into the
Ubuntu rootfs.

> The exact, device-tested launch sequence still requires per-vendor tuning
> and the libhybris build artefacts that match the Android base on the
> device. Treat these scripts as a documented starting point, not a
> turnkey implementation.

## Files

| File | Role |
|------|------|
| `start-lomiri.sh` | Body of `lomiri.service` inside the chroot. Sets every libhybris environment variable and `exec`s the Lomiri shell. |
| `README.md` (this file) | Step-by-step bring-up checklist + references. |

## Pre-requisites the rootfs must satisfy

The Ubuntu rootfs (`rootfs.erofs`) is built by `scripts/build_rootfs.sh`. For
Lomiri to start, that rootfs must contain the following packages (declared
in `rootfs/packages.list`):

```
# libhybris bridge
libhybris-common1
libhybris-common1:armhf       # for armv7 vendor blobs
libhybris-utils

# Android-glue gralloc/HWC
libgralloc1                   # synthesised by halium build, not in apt
libhwc2                       # synthesised by halium build, not in apt
libsync                       # synthesised by halium build, not in apt

# Compositor + shell
mir-server
qtmir-android
lomiri-shell
unity8-desktop                # transitional metapackage (Focal only)
qt-components-ubuntu

# Misc
onboard
zenity
```

Packages marked *synthesised* are **not** in the official Ubuntu archive.
They must be built from
[halium-extras-deb](https://gitlab.com/ubports/development/core/halium-extras-deb)
or pulled from a UBports PPA. See "Step 4" below.

## Bring-up checklist

1. **Confirm the chroot pivot.**
   After flashing, you should be able to `adb shell` into Android,
   `setprop persist.ubuntu_gsi.enable 1`, and `start ubuntu-gsi-launcher`.
   Inside the chroot you should see systemd reach `multi-user.target`.
   At this stage SSH on port 22 must work.

2. **Confirm vendor library reachability.**
   ```
   /usr/lib/aarch64-linux-gnu/libhybris/test_egl
   /usr/lib/aarch64-linux-gnu/libhybris/test_hwcomposer
   ```
   If these fail with `cannot find libEGL_<vendor>.so`, the bind-mount of
   `/vendor` is missing or `HYBRIS_LD_LIBRARY_PATH` does not match the
   directory layout shipped by the OEM.

3. **Confirm SurfaceFlinger has been stopped.**
   `getprop init.svc.surfaceflinger` must return `stopped`.

4. **Build/import libhybris-glue debs for this device.**
   This step is deeply device-specific. The minimum recipe is:

   ```bash
   git clone https://gitlab.com/ubports/development/core/halium-extras-deb
   cd halium-extras-deb
   ./build.sh --arch arm64 --vendor <vendor>
   # → produces libgralloc1, libhwc2, libsync .deb files
   cp out/*.deb ../Ubuntu_Touch_HIDL_GSI/builder/cache/halium-debs/
   ```

   `scripts/build_rootfs.sh` will pick those up automatically.

5. **Tune `start-lomiri.sh`.**
   * `EGL_PLATFORM`: `hwcomposer` for most devices; `mir` for OEMs that
     ship a Mir-native EGL.
   * `HYBRIS_LD_LIBRARY_PATH`: extend with extra OEM library paths
     (e.g., `/vendor/lib64/qti-display:/system/lib64/vndk-29`).
   * Add `MIR_SERVER_BUFFER_FORMAT=rgba8888` if Mir refuses to start
     because of HAL pixel format mismatches.

6. **Iterate.**
   * Logs from Mir: `journalctl -u lomiri.service -f`.
   * Logs from libhybris: `LIBHYBRIS_DEBUG=1` env var.
   * Crashlogs that survived a reboot: `/var/lib/ubuntu-gsi/crashlogs/`.

## When a real device is unavailable

`scripts/test-halium-launcher.sh` runs the launcher against a
`linux-image-generic` container with stubs for `/vendor` and `/dev/binderfs`.
This lets the chroot pivot itself be exercised without needing a phone, but
the Lomiri launch will of course fail at "no EGL platform".

## Authoritative references

| Source | Section |
|--------|---------|
| <https://docs.halium.org/en/latest/porting/12.html> | libhybris environment variables |
| <https://gitlab.com/ubports/development/core/qtmir> | Mir/HWC integration code |
| <https://docs.ubports.com/en/latest/porting/index.html> | UBports porting guide |
| <https://wiki.lineageos.org/devices/spacewar/> | Nothing Phone (1) device-tree references |
