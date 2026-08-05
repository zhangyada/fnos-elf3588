#!/usr/bin/env bash
# =============================================================================
# set-data10g.sh — 把标准版 ELF3588 镜像改造成 "系统 + 10G 数据空间" 版
#
# 原理（关键）：fnnas 首次启动时 resize-rootfs.service 会调用 /usr/sbin/fnnas-tf
# 自动扩展 rootfs。它的扩展策略由 /etc/fnnas.conf 控制：
#     rootfs_limit_gib="16"    # rootfs 大小上限（GiB）
#     rootfs_resize="yes"      # 是否自动扩展
# 盘容量 > limit 时走"受限策略"：rootfs 只扩到 limit 大小，剩余空间不分配！
#
# 本脚本只做一件事：把镜像 rootfs 里的 fnnas.conf 改为
#     rootfs_limit_gib="19"    # 系统 19G（32GB 盘实际 29.8GiB → 剩余 ≥10G 给数据）
# 烧录后首次启动，fnnas-tf 自动把 rootfs 扩到 19G，尾部留出 10G+ 未分配空间，
# 飞牛「设置 → 存储空间管理 → 创建存储空间」即可使用内置 eMMC 空间。
#
# 优势：不改分区表、不 resize2fs，完全走官方机制，且自适应任何盘容量。
#
# 所需环境变量：DATE（必填）、KERNEL_VERSION（可选）、LIMIT_GB（可选，默认 19）
# =============================================================================
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$REPO_ROOT/work10g"
OUT="$REPO_ROOT/out10g"

: "${DATE:?缺少 DATE（标准版镜像日期，如 2026.07.12）}"
KERNEL_VERSION="${KERNEL_VERSION:-unknown}"
LIMIT_GB="${LIMIT_GB:-19}"       # rootfs 上限（GiB）；数据空间 = 盘实际 - LIMIT_GB

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# 出错时清理 loop 设备
cleanup() {
    if [ -n "${LOOP:-}" ]; then
        sudo umount "$MNT" 2>/dev/null || true
        sudo losetup -d "$LOOP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. 找到标准版镜像并解压（workflow 已下载到 WORK 目录）
# ---------------------------------------------------------------------------
echo "::group::1/5 解压标准版镜像"
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
echo "::group::2/5 挂载 loop 设备"
# 保险：确保 loop 模块已加载（runner 内核一般自带，失败忽略）
sudo modprobe loop 2>/dev/null || true
LOOP=$(sudo losetup -fP --show "$IMG")
echo "loop 设备: $LOOP"
sleep 2
# losetup -P 在某些内核环境不自动创建分区节点：用 partx 通知内核扫描兜底
if ! sudo lsblk -no PATH "$LOOP" | grep -q "^${LOOP}p"; then
    echo "loop 分区节点未自动创建，partx -a 扫描..."
    sudo partx -a "$LOOP" 2>/dev/null || true
    sleep 2
fi
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. 探测 rootfs 分区（最大的 ext4 分区）并挂载
# ---------------------------------------------------------------------------
echo "::group::3/5 挂载 rootfs"
ROOTFS_PART=""
BIGGEST=0
# 用变量接收分区列表，grep 无匹配时 || true 保护（避免 set -e 静默退出）
PARTS=$(sudo lsblk -no PATH "$LOOP" 2>/dev/null | grep "^${LOOP}p" || true)
for p in $PARTS; do
    [ -b "$p" ] || { echo "  跳过（非块设备）: $p"; continue; }
    # 注意：loop 分区设备属于 root:disk，必须用 sudo 才能读 superblock
    fstype=$(sudo lsblk -no FSTYPE "$p" 2>/dev/null || true)
    [ -n "$fstype" ] || fstype=$(sudo blkid -s TYPE -o value "$p" 2>/dev/null || true)
    size=$(sudo lsblk -bno SIZE "$p" 2>/dev/null || true)
    label=$(sudo lsblk -no LABEL "$p" 2>/dev/null || true)
    echo "  $p: fs=${fstype:-?} size=${size:-?} label=${label:-?}"
    # 跳过启动分区（label=BOOT），rootfs 只可能是 ext4/btrfs
    if [ "$label" = "BOOT" ] || [ "$label" = "boot" ]; then
        echo "  跳过启动分区: $p"
        continue
    fi
    if [ "$fstype" = "ext4" ] || [ "$fstype" = "btrfs" ]; then
        if [ "${size:-0}" -gt "$BIGGEST" ]; then
            ROOTFS_PART="$p"; BIGGEST="$size"; ROOTFS_FS="$fstype"
        fi
    fi
done
if [ -z "$ROOTFS_PART" ]; then
    echo "错误: 未找到 rootfs 分区（ext4/btrfs，非 BOOT）。当前分区布局："
    sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP" || true
    exit 1
fi
echo "rootfs 分区: $ROOTFS_PART ($(( BIGGEST / 1024 / 1024 / 1024 ))G, $ROOTFS_FS)"

MNT="$WORK/mnt"
mkdir -p "$MNT"
sudo mount "$ROOTFS_PART" "$MNT" || { echo "错误: mount $ROOTFS_PART 失败"; exit 1; }
echo "已挂载: $ROOTFS_PART → $MNT"
ls "$MNT/etc/fnnas.conf" 2>/dev/null && cat "$MNT/etc/fnnas.conf" || echo "（镜像内无 fnnas.conf，将新建）"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. 修改 /etc/fnnas.conf：rootfs_limit_gib=LIMIT_GB, rootfs_resize=yes
# ---------------------------------------------------------------------------
echo "::group::4/5 写入 fnnas.conf（rootfs 上限 ${LIMIT_GB}G）"
CONF="$MNT/etc/fnnas.conf"
if [ -f "$CONF" ]; then
    # 文件已存在：改 limit 值；补 rootfs_resize
    if grep -q '^rootfs_limit_gib=' "$CONF"; then
        sudo sed -i "s|^rootfs_limit_gib=.*|rootfs_limit_gib=\"${LIMIT_GB}\"|" "$CONF"
    else
        echo "rootfs_limit_gib=\"${LIMIT_GB}\"" | sudo tee -a "$CONF" >/dev/null
    fi
    grep -q '^rootfs_resize=' "$CONF" \
        && sudo sed -i "s|^rootfs_resize=.*|rootfs_resize=\"yes\"|" "$CONF" \
        || echo 'rootfs_resize="yes"' | sudo tee -a "$CONF" >/dev/null
else
    # 文件不存在：直接创建（fnnas-tf 的 init_var 默认值即如此）
    printf 'rootfs_limit_gib="%s"\nrootfs_resize="yes"\n' "$LIMIT_GB" | sudo tee "$CONF" >/dev/null
fi
echo "--- 修改后 ---"
cat "$CONF"
sync
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. 卸载 + 重命名 + 压缩 + 校验
# ---------------------------------------------------------------------------
echo "::group::5/5 卸载并重新打包"
sudo umount "$MNT"
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
echo ""
echo "说明: 烧录后首次启动 fnnas-tf 会把 rootfs 扩到 ${LIMIT_GB}G，"
echo "      剩余空间（≥10G）留作未分配，可在飞牛创建存储空间。"
