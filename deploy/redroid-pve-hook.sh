#!/bin/bash
# ==============================================================================
# ReDroid PVE LXC 极简安全加固与环境自愈 Hook (纯净开源版)
# 支持模式：非特权容器 (unprivileged: 1) 与 特权容器 (unprivileged: 0)
# ==============================================================================

HOOK_TYPE="$3"

# 1. start-host 阶段：配置容器静态网络
if [ "$HOOK_TYPE" = "start-host" ] || [ "$HOOK_TYPE" = "pre-start" ] || [ -n "$LXC_PID" -a -z "$LXC_ROOTFS_MOUNT" ]; then
    CONF="/etc/pve/lxc/${LXC_NAME:-$1}.conf"
    if [ -f "$CONF" ] && [ -n "$LXC_PID" ]; then
        NET0_LINE=$(sed '/^\[/,$d' "$CONF" | grep "^net0:" | head -n 1 || true)
        IP_VAL=$(echo "$NET0_LINE" | grep -o "ip=[^, ]*" | cut -d= -f2)
        GW_VAL=$(echo "$NET0_LINE" | grep -o "gw=[^, ]*" | cut -d= -f2)
        # 'dhcp' and 'manual' are PVE modes, not addresses for `ip addr add`.
        # Android owns DHCP. Never import a DHCP lease as a static address.
        if [[ "$IP_VAL" == */* ]] && [[ ",$NET0_LINE," != *,host-managed=1,* ]]; then
            nsenter -t "$LXC_PID" -n ip addr add "$IP_VAL" dev eth0 2>/dev/null || true
            nsenter -t "$LXC_PID" -n ip link set eth0 up 2>/dev/null || true
            [ -n "$GW_VAL" ] && nsenter -t "$LXC_PID" -n ip route add default via "$GW_VAL" dev eth0 2>/dev/null || true
        fi
        # 仅处理明确指定的蜂窝接口 (默认 rmnet0)，不再接管全部 net1-net9
        CELL_LINE=$(sed '/^\[/,$d' "$CONF" | grep -E 'name=rmnet0|name=rmnet' | head -n 1 || true)
        if [ -n "$CELL_LINE" ]; then
            DEV_NAME=$(echo "$CELL_LINE" | grep -o 'name=[^, ]*' | cut -d= -f2 || true)
            [ -n "$DEV_NAME" ] || DEV_NAME="rmnet0"
            DEV_IP=$(echo "$CELL_LINE" | grep -o 'ip=[^, ]*' | cut -d= -f2 || true)
            DEV_GW=$(echo "$CELL_LINE" | grep -o 'gw=[^, ]*' | cut -d= -f2 || true)

            if [ "$DEV_IP" = "dhcp" ]; then
                echo "CT ${LXC_NAME:-$1}: Cellular interface $DEV_NAME does not support DHCP yet" >&2
                exit 1
            fi

            if [[ "$DEV_IP" == */* ]]; then
                nsenter -t "$LXC_PID" -n ip link set "$DEV_NAME" up 2>/dev/null || true
                nsenter -t "$LXC_PID" -n ip addr replace "$DEV_IP" dev "$DEV_NAME" 2>/dev/null || true
                if [ -n "$DEV_GW" ]; then
                    nsenter -t "$LXC_PID" -n ip route replace default via "$DEV_GW" dev "$DEV_NAME" table 101 2>/dev/null || true
                fi
            fi
        fi
    fi
    exit 0
fi

# 2. mount 阶段：极简安全隔离与设备就绪
if [ -n "${LXC_ROOTFS_MOUNT}" ] && [ -d "${LXC_ROOTFS_MOUNT}" ]; then
    CONF="/etc/pve/lxc/${LXC_NAME:-$1}.conf"
    NET0_LINE=$(sed '/^\[/,$d' "$CONF" | grep '^net0:' | head -n 1 || true)
    if [[ ",$NET0_LINE," == *,ip=dhcp,* ]]; then
        if ! grep -a -q 'vendor.redroid.network_api' "${LXC_ROOTFS_MOUNT}/vendor/bin/ipconfigstore"; then
            echo 'DHCP requires a redroid-pve image with network API 1 (patches 0007 and 0008); update the image or use static IPv4' >&2
            exit 1
        fi
    fi
    # 彻底切断 Android 扫描与 abort 宿主机 FUSE 的通道！(保护 pmxcfs)
    mkdir -p "${LXC_ROOTFS_MOUNT}/sys/fs/fuse" 2>/dev/null || true
    mount -t tmpfs -o rw,size=1m none "${LXC_ROOTFS_MOUNT}/sys/fs/fuse" 2>/dev/null || true
    mkdir -p "${LXC_ROOTFS_MOUNT}/sys/fs/fuse/connections" 2>/dev/null || true
    mount -o remount,ro "${LXC_ROOTFS_MOUNT}/sys/fs/fuse" 2>/dev/null || true

    # 彻底切断 Android 休眠物理宿主机的通道！
    if [ -f "${LXC_ROOTFS_MOUNT}/sys/power/state" ]; then
        FAKE_POWER_STATE="/run/fake_power_state"
        [ ! -f "$FAKE_POWER_STATE" ] && touch "$FAKE_POWER_STATE" && chmod 666 "$FAKE_POWER_STATE"
        mount --bind "$FAKE_POWER_STATE" "${LXC_ROOTFS_MOUNT}/sys/power/state" 2>/dev/null || true
    fi

    # 预创建基础 /dev 字符设备节点供 stdio 与 early-boot 使用 (特权模式直接生效；非特权模式由 bind mount 覆盖)
    mkdir -p "${LXC_ROOTFS_MOUNT}/dev" 2>/dev/null || true
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/null" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/null" c 1 3 2>/dev/null || true
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/zero" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/zero" c 1 5 2>/dev/null || true
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/urandom" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/urandom" c 1 9 2>/dev/null || true
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/tty" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/tty" c 5 0 2>/dev/null || true
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/random" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/random" c 1 8 2>/dev/null || true

    # 自动创建容器内 /dev/uinput (直通内核 misc uinput 10:223，供 adb/scrcpy 触控输入)
    [ ! -c "${LXC_ROOTFS_MOUNT}/dev/uinput" ] && mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/uinput" c 10 223 2>/dev/null || true
    chmod 666 /dev/uinput 2>/dev/null || true

    # 授权 cgroup 给 Android system (UID 1000:1000)
    if [ -d "${LXC_ROOTFS_MOUNT}/sys/fs/cgroup" ]; then
        chown -R 1000:1000 "${LXC_ROOTFS_MOUNT}/sys/fs/cgroup" 2>/dev/null || true
        chmod -R 775 "${LXC_ROOTFS_MOUNT}/sys/fs/cgroup" 2>/dev/null || true
    fi

    # 只授权字符设备，避免移除 by-path 等目录的执行权限。
    for device in "${LXC_ROOTFS_MOUNT}"/dev/dri/* "${LXC_ROOTFS_MOUNT}"/dev/dma_heap/*; do
        [ ! -c "$device" ] || chmod 666 "$device" 2>/dev/null || true
    done

    # 清理遗留的损坏以太网配置
    rm -f "${LXC_ROOTFS_MOUNT}/data/misc/ethernet/ipconfig.txt" 2>/dev/null || true
    rm -f "${LXC_ROOTFS_MOUNT}/data/misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt" 2>/dev/null || true

    # 准备 Modem 蜂窝配置文件 (cellular_network.json)
    CELL_LINE=$(sed '/^\[/,$d' "$CONF" | grep -E 'name=rmnet0|name=rmnet' | head -n 1 || true)
    MODEM_CONF_DIR="${LXC_ROOTFS_MOUNT}/data/vendor/modem_simulator"
    mkdir -p "$MODEM_CONF_DIR" 2>/dev/null || true
    if [ -n "$CELL_LINE" ]; then
        DEV_NAME=$(echo "$CELL_LINE" | grep -o 'name=[^, ]*' | cut -d= -f2 || true)
        [ -n "$DEV_NAME" ] || DEV_NAME="rmnet0"
        DEV_IP=$(echo "$CELL_LINE" | grep -o 'ip=[^, ]*' | cut -d= -f2 || true)
        DEV_GW=$(echo "$CELL_LINE" | grep -o 'gw=[^, ]*' | cut -d= -f2 || true)
        if [[ "$DEV_IP" == */* ]]; then
            cat << EOF_CELL > "${MODEM_CONF_DIR}/cellular_network.json"
{
  "interface": "${DEV_NAME}",
  "enabled": true,
  "ipv4": "${DEV_IP}",
  "gateway": "${DEV_GW}",
  "dns": ["${DEV_GW}", "8.8.8.8"]
}
EOF_CELL
        else
            cat << EOF_CELL > "${MODEM_CONF_DIR}/cellular_network.json"
{
  "interface": "${DEV_NAME}",
  "enabled": false,
  "ipv4": "",
  "gateway": "",
  "dns": []
}
EOF_CELL
        fi
    else
        cat << EOF_CELL > "${MODEM_CONF_DIR}/cellular_network.json"
{
  "interface": "rmnet0",
  "enabled": false,
  "ipv4": "",
  "gateway": "",
  "dns": []
}
EOF_CELL
    fi
    chmod 644 "${MODEM_CONF_DIR}/cellular_network.json" 2>/dev/null || true
fi

exit 0
