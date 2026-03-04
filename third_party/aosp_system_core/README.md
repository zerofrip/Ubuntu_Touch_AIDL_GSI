# AOSP system/core (Deferred Submodule)

This directory is a placeholder for the AOSP `platform/system/core` submodule.

## Provides
- `init` — Android init process (PID 1)
- `logd` — Logging daemon
- `logcat` — Log reader utility
- `libcutils`, `libutils`, `liblog` — Core Android libraries

## Pinned Version
- **Tag**: `android-16.0.0_r1`
- **Repository**: https://android.googlesource.com/platform/system/core
- **License**: Apache License 2.0
- **Copyright**: Copyright (C) The Android Open Source Project

## Initialization

This submodule is large (~300+ MB). Initialize only when you need to build from source:

```bash
git submodule update --init --depth 1 third_party/aosp_system_core
cd third_party/aosp_system_core
git fetch --depth 1 origin tag android-16.0.0_r1
git checkout android-16.0.0_r1
```
