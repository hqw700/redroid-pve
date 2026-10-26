#!/bin/bash
# ==============================================================================
# ReDroid PVE 原生容器生命周期 Hookscript
# 触发阶段：pre-start, post-start, pre-stop, post-stop
# ==============================================================================

VMID="$1"
PHASE="$2"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CT $VMID hookscript phase: $PHASE" >> /tmp/pve-hook.log

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
        exit 0
    fi

    CONF="/etc/pve/lxc/${VMID}.conf"
    if [ -f "$CONF" ]; then
        NET0_LINE=$(grep "^net0:" "$CONF" | head -n 1 || true)
        IP_VAL=$(echo "$NET0_LINE" | grep -o "ip=[^, ]*" | cut -d= -f2)
        GW_VAL=$(echo "$NET0_LINE" | grep -o "gw=[^, ]*" | cut -d= -f2)
        echo "CT $VMID (PID $PID) 配置网络: IP=$IP_VAL GW=$GW_VAL" >> /tmp/pve-hook.log
        if [ -n "$IP_VAL" ]; then
            nsenter -t "$PID" -n ip addr add "$IP_VAL" dev eth0 >> /tmp/pve-hook.log 2>&1 || true
            nsenter -t "$PID" -n ip link set eth0 up >> /tmp/pve-hook.log 2>&1 || true
            nsenter -t "$PID" -n ip rule add pref 9999 table main >> /tmp/pve-hook.log 2>&1 || true
            [ -n "$GW_VAL" ] && nsenter -t "$PID" -n ip route add default via "$GW_VAL" dev eth0 >> /tmp/pve-hook.log 2>&1 || true
            echo "CT $VMID 网络已成功注入并就绪!" >> /tmp/pve-hook.log
        fi
    fi
fi

exit 0
