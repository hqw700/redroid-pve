# ReDroid for PVE (redroid-pve)

<p align="center">
  <b>Native Android 13 (AOSP) Container Solution for Proxmox VE (PVE)</b><br>
  5s Cold Boot · Native LAN IP · Unprivileged Mode Support · Zero Docker Nesting · Instant Snapshots
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"></a>
  <a href="https://github.com/hqw700/redroid-pve/releases"><img src="https://img.shields.io/github/v/release/hqw700/redroid-pve?color=brightgreen" alt="Release"></a>
  <a href="README.md"><img src="https://img.shields.io/badge/Language-%E4%B8%AD%E6%96%87-red.svg" alt="Chinese README"></a>
</p>

<p align="center">
  <img src="assets/preview.png" width="95%" alt="ReDroid for PVE Preview (Proxmox VE + scrcpy)" />
</p>

---

## 1. Architecture & Performance Comparison

In traditional deployments, running ReDroid on Proxmox VE requires **Docker-in-LXC nesting** (`PVE ➔ Ubuntu LXC ➔ Docker Daemon ➔ ReDroid`). 

`redroid-pve` eliminates this overhead entirely by running **Android directly as a native PVE LXC container**, with support for **unprivileged mode (`unprivileged: 1`)**:

| Metric | Traditional Docker-in-LXC | This Project: Native PVE LXC (`redroid-pve`) |
| :--- | :--- | :--- |
| **Topology Layers** | PVE ➔ Ubuntu CT ➔ Docker ➔ ReDroid (3 layers) | **PVE ➔ ReDroid CT (1 layer)** |
| **Security Isolation** | Requires `--privileged` mode (risk of container escape) | **Support for Unprivileged Mode (`unprivileged: 1`)** |
| **Cold Boot Time** | ~30 - 50 seconds (booting Ubuntu + dockerd first) | **~5 seconds (direct Android /init to desktop)** |
| **RAM Overhead** | Wastes 1.5GB+ per VM for Ubuntu & Docker daemons | **Zero wasted RAM, container density increases 30%+** |
| **Networking** | Complex Docker NAT port mapping (`-p 5001:5555`) | **Native independent LAN IP via vmbr0 (direct port 5555)** |
| **Lifecycle Control** | Invisible to PVE Web UI; no granular resource quota | **Native PVE Web UI start/stop/restart & CPU/RAM quotas** |
| **Snapshots & Backup**| Cannot snapshot single Android without freezing all | **Instant PVE snapshots (LVM-Thin/ZFS), rollback & backups** |

---

## 2. Quick Start (3 Steps)

### Step 1: Download Pre-built PVE Template

Log into your PVE host (as root) and download the pre-built, highly compressed template (`.tar.zst`, ~600MB):

```bash
cd /var/lib/vz/template/cache/

# Download the v0.0.1 Android 13 x86_64 template image (~620MB)
wget https://github.com/hqw700/redroid-pve/releases/download/v0.0.1/redroid13_x86_64_pve_template_2026-10-26.tar.zst
```

---

### Step 2: Initialize PVE Host Security Hooks

Clone this repository on your PVE host and run the one-click initializer:

```bash
git clone https://github.com/hqw700/redroid-pve.git /root/redroid-pve
cd /root/redroid-pve
./deploy/install-hooks.sh
```

> **What this does:**
> 1. Enables `snippets` content support on PVE `local` storage;
> 2. Deploys security hooks that shield PVE's `pmxcfs` FUSE and prevent Android from suspending the physical host;
> 3. Installs `pve-create-redroid` into `/usr/local/bin`.

---

### Step 3: Create & Launch Container

Run the creation command with your desired VMID, static IP/CIDR, and gateway (**defaults to unprivileged secure mode**):

```bash
# Syntax: pve-create-redroid <VMID> <StaticIP/CIDR> <Gateway> [Cores] [RAM_MB] [Swap_MB] [Disk_GB] [Template] [Unprivileged]
# Example 1: Create CT 201 in Unprivileged Mode (unprivileged: 1, default)
pve-create-redroid 201 192.168.100.201/24 192.168.100.1

# Example 2: Create CT 201 in Privileged Mode (unprivileged: 0, for special kernel pass-through)
pve-create-redroid 201 192.168.100.201/24 192.168.100.1 8 4096 1024 32 "" 0
```

The container will automatically initialize and reach `sys.boot_completed=1` in **~5 seconds**!

---

### Step 4: Connect & Control

From any computer on your local network (Mac / Windows / Linux):

```bash
# 1. Connect via ADB
adb connect 192.168.100.201:5555

# 2. Low-latency screen mirror & touch/keyboard control (using scrcpy)
scrcpy -s 192.168.100.201:5555
```

<p align="center">
  <img src="assets/settings_screen.png" width="45%" alt="Android 13 Settings (Unprivileged Mode)" />
  <img src="assets/unprivileged_screen.png" width="45%" alt="Android 13 Launcher (Unprivileged Mode)" />
</p>

---

## 3. Unprivileged Mode (`unprivileged: 1`) Deep Dive

Traditionally, Android containers required `--privileged` due to host kernel security barriers. This project solved four fundamental challenges to achieve production-grade unprivileged execution:

1. **Native BinderFS under User Namespace (`0002-patch`)**:
   Linux kernels 5.0+ allow unprivileged userns mounting of `binderfs`. However, AOSP's `init.rc` hardcodes `stats=global` which requires global `CAP_SYS_ADMIN`. Removing this option allows the container to independently create and manage `binder`, `hwbinder`, and `vndbinder`.
2. **Eliminating Priority Scheduling Blocks (`RLIMIT_NICE: 40`)**:
   Android `SystemServer` elevates thread priorities to negative values (e.g. -2, -10). Without permission, Linux throws `SecurityException`. Configuring `lxc.prlimit.nice: 40` provides the required negative nice quota cleanly.
3. **Preventing SIGBUS Crashes on Property Areas (`autodev 128MB`)**:
   Android Bionic property areas allocate 128KB per context file. LXC's default 500KB tmpfs causes a memory write page fault `SIGBUS (signal 7)` on the 5th context. Providing a 128MB tmpfs completely resolves this.
4. **Fixing BpfMap Constructor Hardcoded `abort()` (`0005-patch`)**:
   When host eBPF maps cannot be accessed inside an unprivileged container, upstream libraries have fallback logic, but `BpfMap.h` hardcoded `if (mMapFd < 0) abort();`. Replacing it with a safe return allows `gpuservice` and `system_server` to boot smoothly without eBPF.

---

## 4. Boot Parameter Customization

Boot arguments are configured via **`lxc.init.cmd`** in `/etc/pve/lxc/<VMID>.conf`:

```ini
lxc.init.cmd: /init androidboot.hardware=redroid androidboot.redroid_gpu_mode=guest androidboot.redroid_width=1080 androidboot.redroid_height=1920 androidboot.redroid_dpi=320 ro.boot.redroid_fps=60
```

| Parameter | Description | Recommended Values |
| :--- | :--- | :--- |
| **`androidboot.hardware`** | **Required**, hardware platform | `redroid` |
| **`androidboot.redroid_gpu_mode`** | Graphics rendering mode | **`guest`**: CPU software rendering (SwiftShader, 100% reliable)<br>**`host`**: GPU hardware passthrough (requires `/dev/dri`) |
| **`androidboot.redroid_width`** | Screen width | `1080`, `720` |
| **`androidboot.redroid_height`** | Screen height | `1920`, `1280` |
| **`androidboot.redroid_dpi`** | Screen DPI | `320`, `480`, `240` |
| **`ro.boot.redroid_fps`** | Target FPS | `60`, `30` |

---

## 5. Security & Isolation Hooks

1. **PVE Cluster Filesystem (`pmxcfs`) Protection**:
   * Android `vold` scans `/sys/fs/fuse/connections` and writes `1` to abort connections upon shutdown or initialization.
   * `redroid-pve-hook.sh` overrides `/sys/fs/fuse` with a 1MB read-only tmpfs.
2. **Preventing Host Sleep**:
   * Android `system_suspend` writes `mem` to `/sys/power/state`. Hook binds it to a dummy virtual file.
3. **Input & Network Self-healing**:
   * Automatically prepares `/dev/uinput` for input control.
   * Injects network routes via `nsenter` to avoid `IpClient` NPE crashes.

---

## 6. Multi-version & Multi-arch Roadmap

| Android Version | API Level | x86_64 | ARM64 | Status |
| :---: | :---: | :---: | :---: | :---: |
| **Android 13** | API 33 | ✅ Supported (Unprivileged) | 🔄 Planned | **GA Stable (Recommended)** |
| **Android 11** | API 30 | 🔄 Adapting | 🔄 Planned | Best for ultra-low memory |
| **Android 14** | API 34 | 🔄 Planned | 🔄 Planned | Modern compatibility |
| **Android 15** | API 35 | ⏳ Evaluating | ⏳ Evaluating | Cutting edge |

---

## 7. Building from Source

```bash
# 1. Initialize AOSP 13.0.0_r82
repo init -u https://android.googlesource.com/platform/manifest -b android-13.0.0_r82 --depth=1 --git-lfs
git clone https://github.com/remote-android/local_manifests.git .repo/local_manifests -b 13.0.0
repo sync -c -j16

# 2. Apply upstream ReDroid patches
git clone https://github.com/remote-android/redroid-patches.git
./redroid-patches/apply-patch.sh .

# 3. Apply redroid-pve unprivileged adaptation patches
git -C vendor/redroid apply /path/to/redroid-pve/patches/android-13/0001-vendor-redroid-pve-lxc-post-fs-data.patch
git -C system/core apply /path/to/redroid-pve/patches/android-13/0002-system-core-unprivileged-container-adaptation.patch
git -C system/bpf apply /path/to/redroid-pve/patches/android-13/0003-system-bpf-unprivileged-adaptation.patch
git -C system/memory/lmkd apply /path/to/redroid-pve/patches/android-13/0004-system-memory-lmkd-unprivileged-adaptation.patch
git -C frameworks/libs/net apply /path/to/redroid-pve/patches/android-13/0005-frameworks-libs-net-bpfmap-abort-fix.patch
git -C external/toybox apply /path/to/redroid-pve/patches/android-13/0006-external-toybox-accurate-cpu-mem-for-containers.patch

# 4. Build system
source build/envsetup.sh
lunch redroid_x86_64-userdebug
m -j$(nproc)

# 5. Package PVE template (.tar.zst)
./build/mk-pve-template.sh
```

---

## 8. License

Apache-2.0 License. See [LICENSE](LICENSE).
ReDroid is an open-source project by [remote-android](https://github.com/remote-android).
