#!/usr/bin/env bash
# ==============================================================================
# ReDroid PVE (LXC) 补丁自动应用脚本
# 用法: ./apply-patch.sh [-R|--reverse] [AOSP_SRC_DIR] [TAG]
# 示例:
#   ./apply-patch.sh /home/aosp/source/redroid13-pve
#   ./apply-patch.sh . android-13
#   ./apply-patch.sh -R /home/aosp/source/redroid13-pve  # 反向卸载补丁
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${SCRIPT_DIR}/patches" ]; then
    PATCHES_ROOT="${SCRIPT_DIR}/patches"
elif [ -d "${SCRIPT_DIR}/android-13" ] || [ -d "${SCRIPT_DIR}/android-13.0.0_r82" ]; then
    PATCHES_ROOT="${SCRIPT_DIR}"
else
    PATCHES_ROOT="${SCRIPT_DIR}/patches"
fi

REVERSE=0
VERBOSE=0
SRC=""
TAG=""

usage() {
    local code="${1:-1}"
    echo "用法: $(basename "$0") [选项] [AOSP源码目录] [版本TAG]"
    echo ""
    echo "选项:"
    echo "  -R, --reverse    反向卸载/还原补丁"
    echo "  -v, --verbose    输出详细日志"
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $(basename "$0") /home/aosp/source/redroid13-pve"
    echo "  $(basename "$0") . android-13"
    echo "  $(basename "$0") -R /home/aosp/source/redroid13-pve"
    exit "$code"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -R|--reverse)
            REVERSE=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            if [ -z "$SRC" ]; then
                SRC="$1"
            elif [ -z "$TAG" ]; then
                TAG="$1"
            else
                echo "[ERROR] 未知参数: $1"
                usage
            fi
            shift
            ;;
    esac
done

# 若未指定源码目录，且当前目录为 AOSP 源码根目录，则默认为当前目录
if [ -z "$SRC" ]; then
    if [ -f "build/envsetup.sh" ] || [ -d ".repo" ]; then
        SRC="."
    else
        echo "[ERROR] 请指定 AOSP 源码根目录路径！"
        usage
    fi
fi

if [ ! -d "$SRC" ]; then
    echo "[ERROR] 指定的 AOSP 源码目录不存在: $SRC"
    exit 1
fi
SRC="$(cd "$SRC" && pwd)"

# 自动探测 AOSP TAG / 分支
if [ -z "$TAG" ]; then
    MANIFEST_XML="${SRC}/.repo/manifests/default.xml"
    if [ -f "$MANIFEST_XML" ]; then
        if command -v xmllint >/dev/null 2>&1; then
            TAG=$(basename "$(xmllint --xpath "string(/manifest/default/@revision)" "$MANIFEST_XML" 2>/dev/null || true)")
        fi
        if [ -z "$TAG" ]; then
            TAG=$(grep -o 'revision="[^"]*"' "$MANIFEST_XML" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)
            TAG=$(basename "$TAG")
        fi
    fi
fi

# 匹配合适的 patches 目录
TARGET_PATCH_DIR=""
if [ -n "$TAG" ] && [ -d "${PATCHES_ROOT}/${TAG}" ]; then
    TARGET_PATCH_DIR="${PATCHES_ROOT}/${TAG}"
elif [ -d "${PATCHES_ROOT}/android-13" ]; then
    TARGET_PATCH_DIR="${PATCHES_ROOT}/android-13"
    TAG="android-13"
fi

if [ -z "$TARGET_PATCH_DIR" ] || [ ! -d "$TARGET_PATCH_DIR" ]; then
    echo "[ERROR] 未找到匹配的补丁目录！(TAG=${TAG}, 查找路径: ${PATCHES_ROOT})"
    exit 1
fi

echo "============================================================"
if [ "$REVERSE" -eq 1 ]; then
    echo " 正在反向卸载/还原 ReDroid PVE (LXC) 适配补丁"
else
    echo " 正在应用 ReDroid PVE (LXC) 适配补丁"
fi
echo " AOSP 源码目录 : ${SRC}"
echo " 目标版本标签   : ${TAG}"
echo " 补丁目录路径   : ${TARGET_PATCH_DIR}"
echo "============================================================"

TOTAL_COUNT=0
APPLIED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

cd "$TARGET_PATCH_DIR"

# 查找所有包含 .patch 文件的子目录（对应 AOSP 中的各子项目）
PROJECTS=$(find . -mindepth 1 -type d | sed 's|^\./||' | sort)

for p in $PROJECTS; do
    PATCH_FILES=$(find "$p" -maxdepth 1 -name '*.patch' 2>/dev/null | sort || true)
    if [ -z "$PATCH_FILES" ]; then
        continue
    fi

    PROJECT_DIR="${SRC}/${p}"
    echo ""
    echo "==> 检查目标模块: ${p}"

    if [ ! -d "$PROJECT_DIR" ]; then
        echo "    [WARN] 源码中未找到该项目目录: ${PROJECT_DIR}，跳过"
        continue
    fi

    for patch_file in $PATCH_FILES; do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        PATCH_PATH="${TARGET_PATCH_DIR}/${patch_file}"
        PATCH_NAME="$(basename "$patch_file")"

        if [ "$REVERSE" -eq 1 ]; then
            # 反向卸载模式：先检查补丁是否已经被打上 (可以反向 check)
            if git -C "$PROJECT_DIR" apply --check --reverse "$PATCH_PATH" >/dev/null 2>&1; then
                if git -C "$PROJECT_DIR" apply --reverse "$PATCH_PATH" >/dev/null 2>&1; then
                    echo "    [REVERTED] 成功还原补丁: ${PATCH_NAME}"
                    APPLIED_COUNT=$((APPLIED_COUNT + 1))
                else
                    echo "    [FAILED] 还原失败: ${PATCH_NAME}"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
            else
                # 检查是否原本就未打上
                if git -C "$PROJECT_DIR" apply --check "$PATCH_PATH" >/dev/null 2>&1; then
                    echo "    [SKIP] 补丁尚未打入，无需还原: ${PATCH_NAME}"
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                else
                    echo "    [FAILED] 补丁状态不匹配，无法还原: ${PATCH_NAME}"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
            fi
        else
            # 正常打补丁模式：先检查补丁是否已应用
            if git -C "$PROJECT_DIR" apply --check --reverse "$PATCH_PATH" >/dev/null 2>&1; then
                echo "    [ALREADY APPLIED] 补丁已打入，跳过: ${PATCH_NAME}"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            elif git -C "$PROJECT_DIR" apply --check "$PATCH_PATH" >/dev/null 2>&1; then
                if git -C "$PROJECT_DIR" apply "$PATCH_PATH"; then
                    echo "    [APPLIED] 成功打入补丁: ${PATCH_NAME}"
                    APPLIED_COUNT=$((APPLIED_COUNT + 1))
                else
                    echo "    [FAILED] 打入补丁失败: ${PATCH_NAME}"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
            else
                # 尝试带 3-way 或 reject 检测
                echo "    [WARN] 标准检查失败，尝试执行 git apply --reject..."
                if git -C "$PROJECT_DIR" apply --reject "$PATCH_PATH" 2>/dev/null; then
                    echo "    [APPLIED (REJECT)] 补丁部分打入(见 .rej): ${PATCH_NAME}"
                    APPLIED_COUNT=$((APPLIED_COUNT + 1))
                else
                    echo "    [FAILED] 补丁冲突，无法打入: ${PATCH_NAME}"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
            fi
        fi
    done
done

echo ""
echo "============================================================"
echo " 补丁操作完成!"
echo " 总计补丁数 : ${TOTAL_COUNT}"
if [ "$REVERSE" -eq 1 ]; then
    echo " 成功还原   : ${APPLIED_COUNT}"
else
    echo " 成功打入   : ${APPLIED_COUNT}"
fi
echo " 跳过处理   : ${SKIPPED_COUNT}"
echo " 失败数量   : ${FAILED_COUNT}"
echo "============================================================"

if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 1
fi
