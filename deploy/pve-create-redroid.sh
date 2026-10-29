#!/bin/bash
# Native PVE entry point. Runtime rules are owned by pve-configure-redroid.
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
    echo 'Usage: pve-create-redroid VMID IP/CIDR|dhcp [GATEWAY|-] [CORES] [MEMORY_MB] [SWAP_MB] [DISK_GB] [TEMPLATE] [UNPRIVILEGED=1] [GPU_MODE=host] [--no-start] [--storage STORAGE] [--bridge BRIDGE]'
    echo 'DHCP example: pve-create-redroid 201 dhcp (use - as the gateway placeholder when supplying resource arguments)'
    exit 0
fi
ARGS=()
START=1
STORAGE=${REDROID_PVE_STORAGE:-local-lvm}
BRIDGE=${REDROID_PVE_BRIDGE:-vmbr0}
while (( $# )); do
    case "$1" in
        --no-start) START=0; shift ;;
        --storage|--bridge)
            option=$1
            [ "$#" -ge 2 ] || { echo "Missing value for $option" >&2; exit 1; }
            if [ "$option" = --storage ]; then STORAGE=$2; else BRIDGE=$2; fi
            shift 2 ;;
        --*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
[[ "$STORAGE" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ && "$BRIDGE" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] || { echo 'Invalid storage or bridge name' >&2; exit 1; }
set -- "${ARGS[@]}"
VMID=${1:-201}
IP=${2:-192.168.100.201/24}
if [ "$IP" = dhcp ]; then
    GW=${3:-}
    [ -z "$GW" ] || [ "$GW" = - ] || { echo 'DHCP obtains the gateway automatically; omit it or use - as a placeholder' >&2; exit 1; }
    GW=''
else
    GW=${3:-192.168.100.1}
fi
CORES=${4:-8}
MEMORY=${5:-4096}
SWAP=${6:-1024}
DISK=${7:-32}
TEMPLATE=${8:-/var/lib/vz/template/cache/redroid13_intel_latest.tar.zst}
UNPRIVILEGED=${9:-1}
GPU_MODE=${10:-host}
for value in "$VMID" "$CORES" "$MEMORY" "$SWAP" "$DISK"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo 'Invalid numeric argument' >&2; exit 1; }
done
[[ "$UNPRIVILEGED" =~ ^[01]$ && "$GPU_MODE" =~ ^(host|guest)$ ]] || { echo 'Invalid runtime mode' >&2; exit 1; }
# Never destroy or overwrite an existing native PVE container.
if pct status "$VMID" >/dev/null 2>&1; then
    echo "CT $VMID already exists; choose another VMID or use pve-configure-redroid on a stopped container" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE" ] && [ -z "${8:-}" ]; then
    TEMPLATE=$(find /var/lib/vz/template/cache -maxdepth 1 -type f -name '*redroid*.tar.zst' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[ -f "$TEMPLATE" ] || { echo "Template not found: $TEMPLATE; download the image to PVE first" >&2; exit 1; }
command -v pve-configure-redroid >/dev/null
NET0="name=eth0,bridge=$BRIDGE,firewall=0,ip=$IP,type=veth"
if [ "$IP" = dhcp ]; then
    # Validate support before allocating a disk or creating a CT.
    pve-configure-redroid --check-dhcp --template "$TEMPLATE"
else
    NET0+=",gw=$GW"
fi
pct create "$VMID" "$TEMPLATE" --ostype unmanaged --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" --net0 "$NET0" \
    --unprivileged "$UNPRIVILEGED" --description "ReDroid Native Android (CT $VMID)"
pve-configure-redroid "$VMID" --gpu-mode "$GPU_MODE" --json
if [ "$START" = 0 ]; then
    echo "CT $VMID configured; left stopped (--no-start)"
    exit 0
fi
pct start "$VMID"
for ((i=0; i<40; i++)); do
    if [ "$(pct exec "$VMID" -- /system/bin/getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
        if [ "$IP" = dhcp ]; then
            network=$(pve-configure-redroid "$VMID" --network-status --wait-network 40)
            address=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ipv4"][0].split("/")[0])' <<< "$network")
        else
            address=${IP%/*}
        fi
        echo "CT $VMID: Android ready; adb connect ${address}:5555"
        exit 0
    fi
    sleep 1
done
echo "CT $VMID is running, but Android boot readiness was not confirmed within 40 seconds" >&2
exit 1
