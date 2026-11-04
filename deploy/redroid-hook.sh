#!/bin/bash
# ==============================================================================
# ReDroid PVE 原生容器生命周期 Hookscript
# 触发阶段：pre-start, post-start, pre-stop, post-stop
# ==============================================================================

set -eu
VMID="${1:-}"
PHASE="${2:-}"
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo 'Invalid VMID' >&2; exit 1; }
CONF="/etc/pve/lxc/${VMID}.conf"
# Only read the live configuration, never a snapshot's older net0.
NET0_LINE=$(sed '/^\[/,$d' "$CONF" | grep '^net0:' | head -n 1 || true)
IP_VAL=$(echo "$NET0_LINE" | grep -o 'ip=[^, ]*' | cut -d= -f2 || true)
GW_VAL=$(echo "$NET0_LINE" | grep -o 'gw=[^, ]*' | cut -d= -f2 || true)
HOST_MANAGED=$(echo "$NET0_LINE" | grep -o 'host-managed=[^, ]*' | cut -d= -f2 || true)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CT $VMID hookscript phase: $PHASE" >> /tmp/pve-hook.log

# A copied CT or a host reboot must not leave Android booting without BinderFS.
# Keep this prerequisite in the official runtime for both native PVE and controllers.
if [ "$PHASE" = pre-start ]; then
    /usr/local/bin/pve-configure-redroid --prepare-host --json >/dev/null
fi

if [ "$PHASE" = pre-start ] && [ "$IP_VAL" = dhcp ]; then
    [ "$HOST_MANAGED" != 1 ] || {
        echo "CT $VMID: Android owns DHCP; run pve-configure-redroid on the stopped container to disable host-managed DHCP" >&2
        exit 1
    }
fi

if [ "$PHASE" = "post-start" ]; then
    PID=""
    for i in $(seq 1 20); do
        PID=$(lxc-info -n "$VMID" -p -H 2>/dev/null || true)
        if [ -n "$PID" ] && [ "$PID" -gt 0 ] 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if [ -z "$PID" ] || [ "$PID" -le 0 ] 2>/dev/null; then
        echo "[ERROR] 无法获取 CT $VMID 的 PID" >> /tmp/pve-hook.log
        exit 1
    fi

    if [ -f "$CONF" ]; then
        echo "CT $VMID (PID $PID) 配置网络: IP=$IP_VAL GW=$GW_VAL" >> /tmp/pve-hook.log
        if [ "$IP_VAL" = dhcp ] || [[ "$IP_VAL" == */* ]]; then
            nsenter -t "$PID" -n ip link set eth0 up >> /tmp/pve-hook.log 2>&1 || true
            if [ "$IP_VAL" != dhcp ] && [ "$HOST_MANAGED" != 1 ]; then
                if ! nsenter -t "$PID" -n ip rule show | grep -q '^9999:.*lookup main'; then
                    nsenter -t "$PID" -n ip rule add pref 9999 table main
                fi
                nsenter -t "$PID" -n ip addr replace "$IP_VAL" dev eth0
                [ -z "$GW_VAL" ] || nsenter -t "$PID" -n ip route replace default via "$GW_VAL" dev eth0
            fi
            echo "CT $VMID: network prepared (DHCP lifecycle belongs to Android; no host DHCP client)" >> /tmp/pve-hook.log
        fi
        # 仅处理明确指定的蜂窝接口 (默认 rmnet0)，不再接管全部 net1-net9
        CELL_LINE=$(sed '/^\[/,$d' "$CONF" | grep -E 'name=rmnet0|name=rmnet' | head -n 1 || true)
        MODEM_CONF_DIR="/proc/$PID/root/data/vendor/modem_simulator"
        mkdir -p "$MODEM_CONF_DIR" 2>/dev/null || true
        if [ -n "$CELL_LINE" ]; then
            DEV_NAME=$(echo "$CELL_LINE" | grep -o 'name=[^, ]*' | cut -d= -f2 || true)
            [ -n "$DEV_NAME" ] || DEV_NAME="rmnet0"
            DEV_IP=$(echo "$CELL_LINE" | grep -o 'ip=[^, ]*' | cut -d= -f2 || true)
            DEV_GW=$(echo "$CELL_LINE" | grep -o 'gw=[^, ]*' | cut -d= -f2 || true)

            if [ "$DEV_IP" = "dhcp" ]; then
                echo "[ERROR] CT $VMID: Cellular interface $DEV_NAME does not support DHCP yet" >> /tmp/pve-hook.log
                echo "CT $VMID: Cellular interface $DEV_NAME does not support DHCP yet" >&2
                exit 1
            fi

            if [[ "$DEV_IP" == */* ]]; then
                nsenter -t "$PID" -n ip link set "$DEV_NAME" up >> /tmp/pve-hook.log 2>&1
                nsenter -t "$PID" -n ip addr replace "$DEV_IP" dev "$DEV_NAME" >> /tmp/pve-hook.log 2>&1
                if [ -n "$DEV_GW" ]; then
                    nsenter -t "$PID" -n ip route replace default via "$DEV_GW" dev "$DEV_NAME" table 101 >> /tmp/pve-hook.log 2>&1
                fi
                cat << EOF_CELL > "${MODEM_CONF_DIR}/cellular_network.json"
{
  "interface": "${DEV_NAME}",
  "enabled": true,
  "ipv4": "${DEV_IP}",
  "gateway": "${DEV_GW}",
  "dns": ["${DEV_GW}", "8.8.8.8"]
}
EOF_CELL
                chmod 644 "${MODEM_CONF_DIR}/cellular_network.json" 2>/dev/null || true
                echo "CT $VMID: cellular interface $DEV_NAME ($DEV_IP) prepared (table 101 route ready; netd owns routing policy)" >> /tmp/pve-hook.log
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
            chmod 644 "${MODEM_CONF_DIR}/cellular_network.json" 2>/dev/null || true
        fi
    fi
fi

exit 0
