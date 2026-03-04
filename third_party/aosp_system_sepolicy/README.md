# AOSP system/sepolicy (Deferred Submodule)

This directory is a placeholder for the AOSP `platform/system/sepolicy` submodule.

## Provides
- Platform SELinux policy (`plat_sepolicy.cil`)
- SELinux type definitions referenced by `ubuntu_gsi.cil`
- `service_contexts` — Binder service labeling
- Policy compilation tools and macros

## Pinned Version
- **Tag**: `android-16.0.0_r1`
- **Repository**: https://android.googlesource.com/platform/system/sepolicy
- **License**: Apache License 2.0
- **Copyright**: Copyright (C) The Android Open Source Project

## Initialization

```bash
git submodule update --init --depth 1 third_party/aosp_system_sepolicy
cd third_party/aosp_system_sepolicy
git fetch --depth 1 origin tag android-16.0.0_r1
git checkout android-16.0.0_r1
```
