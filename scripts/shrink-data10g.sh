#!/usr/bin/env bash
# =============================================================================
# shrink-data10g.sh — 把标准版 ELF3588 镜像（rootfs 占满全盘）改造成
#                    "系统 + 10G 数据空间" 版
#
# 背景：arm 版 FnOS 镜像烧录后没有 x86 那样的安装向导，分区表在镜像里定死，
#       rootfs 占满整个磁盘（32G eMMC 全被系统吃掉）。
# 本脚本把 rootfs 分区缩小 DATA_GB GiB，磁盘尾部留出 DATA_GB GiB 未分配空间，
# 飞牛安装后即可在「设置 → 存储空间管理 → 创建存储空间」使用内置空间。
#
# 流程：
#   1. 下载/解压标准版 .img.gz（内部文件名可能是 orangepi-5-plus，不关心，取实际值）
#   2. losetup 挂载为 loop 设备（含分区）
#   3. 探测 rootfs 分区（ext4 → 可缩；btrfs → 不支持缩小，报错退出）
#   4. e2fsck -f → resize2fs 缩小到 (原大小 - DATA_GB)
#   5. parted resizepart 把分区表缩到同样大小（尾部留 DATA_GB 未分配）
#   6. 重命名为 elf3588_d10g 名 → gzip -9 → 输出 + SHA256SUMS
#
# 所需环境变量：DATE（必填）、KERNEL_VERSION（可选）、DATA_GB（可选，默认 10）
# =============================================================================
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$REPO_ROOT/work10g"
OUT="$REPO_ROOT/out10g"

: "${DATE:?缺少 DATE（标准版镜像日期，如 2026.07.12）}"
KERNEL_VERSION="${KERNEL_VERSION:-unknown}"
DATA_GB="${DATA_GB:-10}"        # 预留数据空间大小（GiB）

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# 出错时清理 loop 设备
cleanup() {
    if [ -n "${LOOP:-}" ]; then
        sudo umount "${LOOP}"p* 2>/dev/null || true
        sudo losetup -d "$LOOP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. 找到标准版镜像并解压（workflow 已下载到 WORK 目录）
# ---------------------------------------------------------------------------
echo "::group::1/6 解压标准版镜像"
GZ=$(ls fnnas_rockchip_elf3588_*.img.gz 2>/dev/null | head -1 || true)
[ -n "$GZ" ] || { echo "错误: 未找到标准版镜像 fnnas_rockchip_elf3588_*.img.gz"; exit 1; }
echo "标准版镜像: $GZ"
gzip -d "$GZ"
IMG=$(ls *.img 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "错误: 解压后未找到 .img 文件"; exit 1; }
echo "解压得到: $IMG（内部文件名沿用镜像原始名，不影响操作）"
ls -lh "$IMG"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. loop 挂载（带分区表）
# ---------------------------------------------------------------------------
echo "::group::2/6 挂载 loop 设备"
# 保险：确保 loop 模块已加载（runner 内核一般自带，失败忽略）
sudo modprobe loop 2>/dev/null || true
LOOP=$(sudo losetup -fP --show "$IMG")
echo "loop 设备: $LOOP"
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. 探测 rootfs 分区（最大的 ext4/btrfs 分区）
# ---------------------------------------------------------------------------
echo "::group::3/6 探测 rootfs 分区"
ROOTFS_PART=""
ROOTFS_FS=""
BIGGEST=0
for p in "${LOOP}"p*; do
    [ -b "$p" ] || continue
    # 注意：loop 分区设备属于 root:disk，必须用 sudo 才能读 superblock
    fstype=$(sudo lsblk -no FSTYPE "$p" 2>/dev/null || true)
    size=$(sudo lsblk -bno SIZE "$p" 2>/dev/null || true)
    if [ "$fstype" = "ext4" ] || [ "$fstype" = "btrfs" ]; then
        if [ "${size:-0}" -gt "$BIGGEST" ]; then
            ROOTFS_PART="$p"; ROOTFS_FS="$fstype"; BIGGEST="$size"
        fi
    fi
done
[ -n "$ROOTFS_PART" ] || { echo "错误: 未找到 ext4/btrfs 分区（rootfs）"; exit 1; }
PART_NUM=$(echo "$ROOTFS_PART" | grep -oE '[0-9]+$')
echo "rootfs: ${LOOP}p${PART_NUM}  文件系统: $ROOTFS_FS"
if [ "$ROOTFS_FS" = "btrfs" ]; then
    echo "错误: rootfs 是 btrfs，btrfs 不支持缩小分区，需要更换方案。" >&2
    exit 1
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. 计算目标大小并缩小文件系统（先 fs 后分区表，顺序不能反）
# ---------------------------------------------------------------------------
echo "::group::4/6 缩小 rootfs（${DATA_GB}G）"
CUR_BYTES=$(sudo lsblk -bno SIZE "$ROOTFS_PART")
CUR_GB=$(( CUR_BYTES / 1024 / 1024 / 1024 ))
NEW_GB=$(( CUR_GB - DATA_GB ))
[ "$NEW_GB" -gt 5 ] || { echo "错误: 缩小后 rootfs 仅 ${NEW_GB}G，疑似磁盘过小"; exit 1; }
echo "rootfs: ${CUR_GB}G → ${NEW_GB}G（尾部留 ${DATA_GB}G 未分配）"

sudo e2fsck -fy "$ROOTFS_PART" >/dev/null 2>&1 || sudo e2fsck -fy "$ROOTFS_PART"
sudo resize2fs "$ROOTFS_PART" "${NEW_GB}G"
echo "文件系统缩小完成"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. 缩小分区表（parted resizepart，按绝对扇区）
# ---------------------------------------------------------------------------
echo "::group::5/6 缩小分区表"
PART_START_S=$(sudo parted "$LOOP" unit s print | awk -v n="$PART_NUM" '($1==n) {gsub(/s/,"",$1); print $1; exit}')
PART_END_S=$(sudo parted "$LOOP" unit s print | awk -v n="$PART_NUM" '($1==n) {gsub(/s/,"",$2); print $2; exit}')
SECTORS_PER_G=$(( 1024 * 1024 * 1024 / 512 ))
NEW_END_S=$(( PART_START_S + NEW_GB * SECTORS_PER_G - 1 ))
echo "分区 $PART_NUM: [$PART_START_S .. $PART_END_S] → 新结束 $NEW_END_S"
sudo parted "$LOOP" resizepart "$PART_NUM" "${NEW_END_S}s"
sudo partprobe "$LOOP" 2>/dev/null || true
sleep 2

# 校验最终布局
echo "--- 最终分区布局 ---"
sudo parted "$LOOP" unit MiB print
# 再次检查文件系统完好
sudo e2fsck -f "$ROOTFS_PART" 2>&1 | tail -2
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 6. 重命名 + 压缩 + 校验
# ---------------------------------------------------------------------------
echo "::group::6/6 重新打包"
sudo losetup -d "$LOOP"
LOOP=""

OUT_BASE="fnnas_rockchip_elf3588_d10g_k${KERNEL_VERSION}_${DATE}.img"
mv "$IMG" "$OUT_BASE"
gzip -9 -c "$OUT_BASE" > "$OUT/${OUT_BASE}.gz"
rm -f "$OUT_BASE"

cd "$OUT"
sha256sum *.img.gz > SHA256SUMS
ls -lh
echo "::endgroup::"

echo ""
echo "完成: $OUT/"
cat SHA256SUMS
