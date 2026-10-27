#!/bin/bash
set -e

# ==============================================================================
# ReDroid 13 原生 PVE (LXC) 容器镜像模板打包与分发脚本
# 运行环境：pve-build 编译机
# 产物规范：符合 Proxmox VE LXC 模板标准的 .tar.zst 归档
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOSP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -n "$OUT" ] && [ -d "$OUT" ]; then
    OUT_DIR="$OUT"
else
    OUT_DIR="${AOSP_DIR}/out/target/product/redroid_x86_64"
fi

SYSTEM_IMG="${OUT_DIR}/system.img"
VENDOR_IMG="${OUT_DIR}/vendor.img"

if [ ! -f "$SYSTEM_IMG" ] || [ ! -f "$VENDOR_IMG" ]; then
    echo "[ERROR] 未找到 system.img 或 vendor.img: ${OUT_DIR}"
    exit 1
fi

RELEASE_DIR="${AOSP_DIR}/release"
TMP_ROOTFS="${OUT_DIR}/.tmp_pve_rootfs"

mkdir -p "${RELEASE_DIR}"
rm -rf "${TMP_ROOTFS}"
mkdir -p "${TMP_ROOTFS}"

DATE_STR=$(date "+%Y-%m-%d-%H")
TAR_ZST_FILE="${RELEASE_DIR}/redroid13_pve_template_${DATE_STR}.tar.zst"
LATEST_LINK="${RELEASE_DIR}/redroid13_pve_template_latest.tar.zst"

echo "============================================================"
echo " 开始打包 ReDroid 13 原生 PVE (LXC) 容器镜像模板"
echo " AOSP 源码目录 : ${AOSP_DIR}"
echo " 编译产物目录 : ${OUT_DIR}"
echo " 目标模板文件 : ${TAR_ZST_FILE}"
echo "============================================================"

# 1. 提取 system.img 与 vendor.img
echo "--> 1. 用户态提取 system.img 内容 (debugfs)..."
debugfs -R 'rdump / '${TMP_ROOTFS}'' "${SYSTEM_IMG}" >/dev/null 2>&1 || true

echo "--> 2. 用户态提取 vendor.img 内容 (debugfs)..."
mkdir -p "${TMP_ROOTFS}/vendor"
debugfs -R 'rdump / '${TMP_ROOTFS}/vendor'' "${VENDOR_IMG}" >/dev/null 2>&1 || true

# 2. 根文件系统兼容性补齐
echo "--> 3. 补齐 PVE LXC 根文件系统规范与启动入口..."
cd "${TMP_ROOTFS}"

# 创建标准挂载点目录（etc 默认为系统软链接，无需创建）
mkdir -p data apex ipc dev sys proc mnt sbin data_mirror metadata cache storage

# 确保 init.rc 中 binderfs 挂载去除了 stats=global 限制 (保证非特权 User Namespace 原生挂载)
if [ -f system/etc/init/hw/init.rc ]; then
    sed -i 's/mount binder binder \/dev\/binderfs stats=global/mount binder binder \/dev\/binderfs/' system/etc/init/hw/init.rc 2>/dev/null || true
fi

# 在 mksh 全局配置与 profiles 中关闭 TOSTOP，防止交互式控制台运行 top 等全屏程序时触发 SIGTTOU 挂起
if [ -f system/etc/mkshrc ]; then
    if ! grep -q "stty -tostop" system/etc/mkshrc; then
        echo "stty -tostop 2>/dev/null || true" >> system/etc/mkshrc
    fi
    cp -f system/etc/mkshrc system/etc/profile 2>/dev/null || true
    cp -f system/etc/mkshrc system/etc/suid_profile 2>/dev/null || true
    mkdir -p root
    cp -f system/etc/mkshrc root/.mkshrc 2>/dev/null || true
    cp -f system/etc/mkshrc root/.profile 2>/dev/null || true
fi

# 保持 AOSP 原生 Bionic Linker 软链接指向 /apex/com.android.runtime/bin/linker* (勿覆写为 bootstrap)

# 确保 vendor/bin/post-fs-data.redroid.sh 具备 APEX LinkerConfig 自愈逻辑
if [ -f vendor/bin/post-fs-data.redroid.sh ]; then
    if ! grep -q "linkerconfig --target /linkerconfig" vendor/bin/post-fs-data.redroid.sh; then
        cat << 'POSTFS_EOF' >> vendor/bin/post-fs-data.redroid.sh

## 确保 linkerconfig 生成完整版 APEX 命名空间配置 (178KB)
if [ -x /apex/com.android.runtime/bin/linkerconfig ]; then
    /apex/com.android.runtime/bin/linkerconfig --target /linkerconfig 2>/dev/null || true
fi
POSTFS_EOF
    fi
fi

# 注入 /sbin/init 兼容软链接
ln -sf /init sbin/init

# 注入 /sbin/entrypoint.sh 启动包装器 (若无外部传参则自动补齐默认参数)
cat << 'EOF' > sbin/entrypoint.sh
#!/system/bin/sh
DEFAULT_BOOTARGS="androidboot.hardware=redroid ro.boot.redroid_fps=60 androidboot.redroid_dpi=320"
if [ $# -gt 0 ]; then
    exec /init "$@"
else
    exec /init $DEFAULT_BOOTARGS
fi
EOF
chmod +x sbin/entrypoint.sh

# 3. 归档与 Zstandard 压缩
echo "--> 4. 生成带扩展属性的 tar.zst 模板 (zstd -T0 -19)..."
tar --xattrs -c -C "${TMP_ROOTFS}" . | zstd -T0 -19 -o "${TAR_ZST_FILE}"
ln -sf "$(basename "${TAR_ZST_FILE}")" "${LATEST_LINK}"

# 4. 清理临时解包目录
echo "--> 5. 清理临时解包目录..."
rm -rf "${TMP_ROOTFS}"

echo "============================================================"
echo " 打包完成!"
echo " 生成 PVE 模板: ${TAR_ZST_FILE}"
echo " 模板大小     : $(du -sh "${TAR_ZST_FILE}" | cut -f1)"
echo "============================================================"

# 5. 可选：自动同步至 PVE 宿主机 (pve-155h) 的模板目录
if ssh -o BatchMode=yes -o ConnectTimeout=3 pve-155h "test -d /var/lib/vz/template/cache" 2>/dev/null; then
    echo "--> 正在分发模板至 PVE 宿主机 (pve-155h)..."
    scp "${TAR_ZST_FILE}" pve-155h:/var/lib/vz/template/cache/
    ssh pve-155h "ln -sf $(basename "${TAR_ZST_FILE}") /var/lib/vz/template/cache/redroid13_intel_latest.tar.zst"
    echo "[SUCCESS] 模板已成功同步至 PVE 宿主机: /var/lib/vz/template/cache/redroid13_intel_latest.tar.zst"
else
    echo "[INFO] 未检测到 pve-155h 直连，请手动复制模板至 PVE 宿主机的 /var/lib/vz/template/cache/ 目录"
fi
