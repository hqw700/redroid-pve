# ReDroid for PVE (redroid-pve)

<p align="center">
  <b>Native Android 13 (AOSP) Privileged Container Solution for Proxmox VE (PVE)</b><br>
  5s Cold Boot · Native LAN IP · Host Safety Hardening · Zero Docker Nesting · Instant Snapshots
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

`redroid-pve` eliminates this overhead entirely by running **Android directly as a first-class citizen on PVE native LXC**:

| Metric | Traditional Docker-in-LXC | This Project: Native PVE LXC (`redroid-pve`) |
| :--- | :--- | :--- |
| **Topology Layers** | PVE ➔ Ubuntu CT ➔ Docker ➔ ReDroid (3 layers) | **PVE ➔ ReDroid CT (1 layer)** |
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

Run the creation command with your desired VMID, static IP/CIDR, and gateway:

```bash
# Syntax: pve-create-redroid <VMID> <StaticIP/CIDR> <Gateway>
# Example: CT 201 with IP 192.168.100.201, Gateway 192.168.100.1
pve-create-redroid 201 192.168.100.201/24 192.168.100.1
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

---

## 3. Boot Parameter Customization

Boot arguments are configured via **`lxc.init.cmd`** in `/etc/pve/lxc/<VMID>.conf`.

Edit the configuration file (`nano /etc/pve/lxc/<VMID>.conf`) and reboot the container (`pct reboot <VMID>`):

```ini
lxc.init.cmd: /init androidboot.hardware=redroid androidboot.redroid_gpu_mode=guest androidboot.redroid_width=1080 androidboot.redroid_height=1920 androidboot.redroid_dpi=320 ro.boot.redroid_fps=60
```

| Parameter | Description | Recommended Values |
| :--- | :--- | :--- |
| **`androidboot.hardware`** | Hardware target identifier (**Required**) | `redroid` |
| **`androidboot.redroid_gpu_mode`** | GPU rendering mode | **`guest`**: CPU software rasterizer (SwiftShader, zero GPU dependencies, highly reliable)<br>**`host`**: Host GPU hardware acceleration (requires `/dev/dri` pass-through) |
| **`androidboot.redroid_width`** | Screen width | `1080`, `720` |
| **`androidboot.redroid_height`** | Screen height | `1920`, `1280` |
| **`androidboot.redroid_dpi`** | Display pixel density DPI | `320`, `480`, `240` |
| **`ro.boot.redroid_fps`** | Target frame rate | `60`, `30` |

---

## 4. Key Security Protections (Why Hooks are Crucial)

Running Android inside a privileged container shares `/sys` with the host. Two major system conflicts are resolved by our hooks:

1. **Protecting PVE Cluster Filesystem (`pmxcfs`)**:
   * Proxmox VE's `/etc/pve` cluster configuration operates over FUSE (`pmxcfs`).
   * Android's `vold` daemon runs `AbortFuseConnections()` during boot and shutdown, writing `1` to all entries in `/sys/fs/fuse/connections`.
   * **Protection**: `redroid-pve-hook.sh` mounts a read-only 1MB tmpfs over `/sys/fs/fuse` inside the container, preventing `vold` from ever accessing or severing the host's FUSE connections.
2. **Preventing Physical Host Sleep/Suspension**:
   * Android's `system_suspend` service writes `mem` to `/sys/power/state` when screen idles. In a privileged container, this would put the entire physical PVE server to sleep!
   * **Protection**: The hook bind-mounts a fake dummy file over `/sys/power/state`, neutralizing sleep commands.
3. **Touch Input & Network Self-Healing**:
   * Automatically creates `/dev/uinput` (mode 0666) for `scrcpy` mouse/touch events.
   * Injects static IP via `nsenter` in `post-start`, preventing Android's `IpClient` NPE crash loop.

---

## 5. Roadmap

| Android Version | API Level | x86_64 Arch | ARM64 Arch | Status |
| :---: | :---: | :---: | :---: | :---: |
| **Android 13** | API 33 | ✅ Supported | 🔄 Planned | **GA Stable (Recommended)** |
| **Android 11** | API 30 | 🔄 In Progress | 🔄 Planned | Ideal for ultra-low memory usage |
| **Android 14** | API 34 | 🔄 Planned | 🔄 Planned | High API compatibility |
| **Android 15** | API 35 | ⏳ Evaluating | ⏳ Evaluating | Bleeding-edge features |

---

## 6. Building from Source

```bash
# 1. Initialize AOSP 13.0.0_r82
repo init -u https://android.googlesource.com/platform/manifest -b android-13.0.0_r82 --depth=1 --git-lfs
git clone https://github.com/remote-android/local_manifests.git .repo/local_manifests -b 13.0.0
repo sync -c -j16

# 2. Apply upstream redroid patches
git clone https://github.com/remote-android/redroid-patches.git
./redroid-patches/apply-patch.sh .

# 3. Apply redroid-pve adaptation patch
git -C vendor/redroid apply /path/to/redroid-pve/patches/android-13/0001-vendor-redroid-pve-lxc-post-fs-data.patch

# 4. Build
source build/envsetup.sh
lunch redroid_x86_64-userdebug
m -j8

# 5. Package PVE template
./build/mk-pve-template.sh
```

---

## 7. License

This project is licensed under the [Apache-2.0 License](LICENSE).
ReDroid is an open-source project by [remote-android](https://github.com/remote-android).
