#!/bin/bash
set -e

# ==============================================================================
# ReDroid 13 原生 PVE (LXC) 容器一键创建与部署脚本
# 运行环境：PVE 宿主机 (pve-155h / 192.168.100.2)
# 支持模式：非特权模式 (默认推荐，unprivileged: 1) / 特权模式 (unprivileged: 0)
# ==============================================================================

VMID=${1:-201}
IP=${2:-"192.168.100.201/24"}
GW=${3:-"192.168.100.1"}
CORES=${4:-8}
MEMORY=${5:-4096}
SWAP=${6:-1024}
DISK_SIZE=${7:-32}
TEMPLATE=${8:-"/var/lib/vz/template/cache/redroid13_intel_latest.tar.zst"}
UNPRIVILEGED=${9:-1} # 默认开启非特权模式 (1=非特权, 0=特权)

if [ ! -f "$TEMPLATE" ]; then
    # 自动检测 /var/lib/vz/template/cache/ 下最新的 redroid 模板
    DETECTED_TPL=$(ls -t /var/lib/vz/template/cache/*redroid*.tar.zst 2>/dev/null | head -n 1 || true)
    if [ -n "$DETECTED_TPL" ] && [ -f "$DETECTED_TPL" ]; then
        TEMPLATE="$DETECTED_TPL"
    else
        echo "[ERROR] 未找到 ReDroid PVE 模板: $TEMPLATE"
        echo "[HINT] 请先下载模板至 /var/lib/vz/template/cache/ 目录"
        exit 1
    fi
fi

echo "============================================================"
echo " 开始创建 ReDroid 13 原生 PVE (LXC) 容器"
echo " 容器 ID      : ${VMID}"
echo " 静态 IP      : ${IP}"
echo " 默认网关    : ${GW}"
echo " CPU 核心数  : ${CORES} 核"
echo " 内存大小    : ${MEMORY} MB (Swap: ${SWAP} MB)"
echo " 磁盘大小    : ${DISK_SIZE} GB"
echo " 运行模式    : $([ "$UNPRIVILEGED" = "1" ] && echo "非特权模式 (Unprivileged)" || echo "特权模式 (Privileged)")"
echo " 模板路径    : ${TEMPLATE}"
echo "============================================================"

# 1. 如果已存在同名容器，先清理
if pct status "$VMID" >/dev/null 2>&1; then
    echo "[WARN] 容器 CT $VMID 已存在，正在销毁..."
    pct stop "$VMID" >/dev/null 2>&1 || true
    pct destroy "$VMID" --purge
fi

# 2. 确保 PVE Hook 脚本就绪
mkdir -p /var/lib/vz/snippets /usr/share/lxc/hooks
pvesm set local --content iso,vztmpl,snippets,import,backup >/dev/null 2>&1 || true

# 3. 创建 PVE 原生容器
echo "--> 1. 创建 PVE 原生容器 CT ${VMID}..."
pct create ${VMID} "${TEMPLATE}" \
  --ostype unmanaged \
  --cores ${CORES} \
  --memory ${MEMORY} \
  --swap ${SWAP} \
  --rootfs local-lvm:${DISK_SIZE} \
  --net0 name=eth0,bridge=vmbr0,firewall=0,ip=${IP},gw=${GW},type=veth \
  --cmode shell \
  --unprivileged ${UNPRIVILEGED} \
  --features nesting=1,mknod=1 \
  --hookscript local:snippets/redroid-hook.sh \
  --description "ReDroid 13 Native Android Cloud Phone (CT ${VMID})"

# 4. 注入加固配置与运行参数
echo "--> 2. 注入直通与 LXC 安全加固参数..."
cat << EOF >> /etc/pve/lxc/${VMID}.conf
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cap.drop: sys_boot
lxc.mount.auto: proc:rw sys:mixed cgroup:rw
lxc.hook.mount: /usr/share/lxc/hooks/redroid-pve-hook.sh
lxc.init.cmd: /init androidboot.hardware=redroid androidboot.redroid_gpu_mode=guest androidboot.redroid_width=1080 androidboot.redroid_height=1920 androidboot.redroid_dpi=320 ro.boot.redroid_fps=60
lxc.autodev: 0
lxc.mount.entry: tmpfs dev tmpfs create=dir,rw,nosuid,size=134217728,mode=755 0 0
EOF

if [ "${UNPRIVILEGED}" = "1" ]; then
    # 非特权模式 (Unprivileged)
    cat << EOF >> /etc/pve/lxc/${VMID}.conf
lxc.prlimit.nice: 40
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 248:* rwm
lxc.mount.entry: /dev/null dev/null none bind,create=file 0 0
lxc.mount.entry: /dev/zero dev/zero none bind,create=file 0 0
lxc.mount.entry: /dev/random dev/random none bind,create=file 0 0
lxc.mount.entry: /dev/urandom dev/urandom none bind,create=file 0 0
lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file 0 0
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/dma_heap dev/dma_heap none bind,optional,create=dir 0 0
EOF
    # 宿主放行 kmsg 与 GPU 读写权限给容器普通映射用户
    chmod 666 /dev/kmsg 2>/dev/null || true
    chmod 666 /dev/dri/* 2>/dev/null || true
else
    # 特权模式 (Privileged)
    cat << EOF >> /etc/pve/lxc/${VMID}.conf
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/dri dev/dri none bind,create=dir 0 0
lxc.mount.entry: /dev/dma_heap dev/dma_heap none bind,create=dir 0 0
lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop-control dev/loop-control none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop0 dev/loop0 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop1 dev/loop1 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop2 dev/loop2 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop3 dev/loop3 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop4 dev/loop4 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop5 dev/loop5 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop6 dev/loop6 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/loop7 dev/loop7 none bind,optional,create=file 0 0
EOF
fi

# 5. 启动容器
echo "--> 3. 启动容器 CT ${VMID}..."
pct start ${VMID}

echo "============================================================"
echo " 容器 CT ${VMID} 启动成功!"
echo " 正在等待系统完全初始化 (sys.boot_completed)..."
IP_ADDR=$(echo "$IP" | cut -d/ -f1)
for i in $(seq 1 40); do
    STATUS=$(pct exec ${VMID} -- /system/bin/getprop sys.boot_completed 2>/dev/null || true)
    if [ "$STATUS" = "1" ]; then
        echo "[SUCCESS] Android 13 初始化完成 (sys.boot_completed=1)!"
        echo "ADB 连接命令: adb connect ${IP_ADDR}:5555"
        exit 0
    fi
    sleep 1
done

echo "[INFO] 容器已运行，系统仍在启动中，请稍后执行: adb connect ${IP_ADDR}:5555"
