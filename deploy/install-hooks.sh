#!/bin/bash
set -e

# ==============================================================================
# ReDroid PVE 一键宿主机环境初始化脚本
# 适用环境：Proxmox VE 7.x / 8.x / 9.x 宿主机
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " 开始初始化 PVE 宿主机 ReDroid 运行环境..."
echo "============================================================"

# 1. 确保 PVE local 存储开启 snippets 特性
echo "--> 1. 配置 PVE 本地存储支持 snippets..."
pvesm set local --content iso,vztmpl,snippets,backup,import >/dev/null 2>&1 || true

# 2. 创建系统目录
echo "--> 2. 准备系统钩子目录..."
mkdir -p /var/lib/vz/snippets /usr/share/lxc/hooks /var/lib/vz/template/cache

# 3. 部署加固 Hook 与网络 Hook
echo "--> 3. 部署加固 Hook 脚本..."
cp -f "${SCRIPT_DIR}/redroid-hook.sh" /var/lib/vz/snippets/redroid-hook.sh
chmod +x /var/lib/vz/snippets/redroid-hook.sh

cp -f "${SCRIPT_DIR}/redroid-pve-hook.sh" /usr/share/lxc/hooks/redroid-pve-hook.sh
chmod +x /usr/share/lxc/hooks/redroid-pve-hook.sh

# 4. 安装快捷创建命令到 /usr/local/bin
echo "--> 4. 安装 pve-create-redroid 命令..."
cp -f "${SCRIPT_DIR}/pve-create-redroid.sh" /usr/local/bin/pve-create-redroid
chmod +x /usr/local/bin/pve-create-redroid

echo "============================================================"
echo " [SUCCESS] PVE 宿主机初始化就绪！"
echo ""
echo " 您现在可以直接使用以下命令创建 Android 容器："
echo "   pve-create-redroid <VMID> <静态IP/掩码> <默认网关>"
echo ""
echo " 示例："
echo "   pve-create-redroid 201 192.168.100.201/24 192.168.100.1"
echo "============================================================"
