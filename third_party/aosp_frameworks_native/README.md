# AOSP frameworks/native (Deferred Submodule)

This directory is a placeholder for the AOSP `platform/frameworks/native` submodule.

## Provides
- `libbinder` — Android Binder IPC runtime library
- `servicemanager` — AIDL binder service manager

## Pinned Version
- **Tag**: `android-16.0.0_r1`
- **Repository**: https://android.googlesource.com/platform/frameworks/native
- **License**: Apache License 2.0
- **Copyright**: Copyright (C) The Android Open Source Project

## Initialization

This submodule is large (~400+ MB). Initialize only when you need to build from source:

```bash
git submodule update --init --depth 1 third_party/aosp_frameworks_native
cd third_party/aosp_frameworks_native
git fetch --depth 1 origin tag android-16.0.0_r1
git checkout android-16.0.0_r1
```
