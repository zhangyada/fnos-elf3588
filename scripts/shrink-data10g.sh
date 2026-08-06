#!/usr/bin/env bash
# =============================================================================
# shrink-data10g.sh — 把标准版 ELF3588 镜像改造成 "系统 8G + 数据自适应" 版
#
# 背景（踩坑结论）：仅改 /etc/fnnas.conf 的 rootfs_limit_gib 无效——
# 设备上 resize-rootfs.service 实际调用的是飞牛自己的 resize-rootfs.sh，
# 其逻辑是 "Disk <= 28GB → resize to 99%"，完全不读 fnnas.conf，
# 会把 rootfs 扩满整盘。fnnas-tf 的受限策略被它覆盖。
#
# 本脚本终极方案（不依赖设备上任何扩展机制）：
#   1. 镜像只拉长到 ROOTFS_GIB+少量余量（保持小镜像，不是整盘！）
#   2. parted 修复 GPT 备份头 + resizepart 把 rootfs 分区扩到 ROOTFS_GIB
#   3. btrfs filesystem resize max 把文件系统扩满分区
#   4. 禁用一切扩展机制：
#      - 移除 resize-rootfs.service（wants 链接 + 服务文件）
#      - 把 /usr/sbin/fnnas-tf 与 /usr/sbin/resize-rootfs.sh 改名（谁调都找不到）
#      - fnnas.conf 置 rootfs_resize=no
#   5. 重打包发布
#
# 结果：烧录后 rootfs 固定 ROOTFS_GIB，扩展服务已死，
#       从镜像尾部到设备盘末尾全部是未分配空间（**自适应盘容量**）：
#       32G 盘 → ~21G 数据；128G 盘 → ~120G 数据。
#       飞牛「设置 → 存储空间管理 → 创建存储空间」即可使用。
#
# 所需环境变量：
#   DATE（必填，如 2026.07.12）、KERNEL_VERSION（可选）、
#   ROOTFS_GIB（可选，默认 8，系统分区大小）
# =============================================================================
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$REPO_ROOT/work10g"
OUT="$REPO_ROOT/out10g"

: "${DATE:?缺少 DATE（标准版镜像日期，如 2026.07.12）}"
KERNEL_VERSION="${KERNEL_VERSION:-unknown}"
ROOTFS_GIB="${ROOTFS_GIB:-8}"             # 系统分区大小（GiB）
# 镜像拉长到 ROOTFS_GIB + 4MiB（余量给 GPT 备份头）——保持小镜像
TARGET_BYTES=$((ROOTFS_GIB * 1024 * 1024 * 1024 + 4 * 1024 * 1024))

mkdir -p "$WORK" "$OUT"
cd "$WORK"

LOOP=""
MNT="$WORK/mnt"
mkdir -p "$MNT"

# 出错时清理 loop 设备
cleanup() {
    if [ -n "$LOOP" ]; then
        sudo umount "$MNT" 2>/dev/null || true
        sudo losetup -d "$LOOP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. 解压标准版镜像
# ---------------------------------------------------------------------------
echo "::group::1/6 解压标准版镜像"
GZ=$(ls fnnas_rockchip_elf3588_*.img.gz 2>/dev/null | head -1 || true)
[ -n "$GZ" ] || { echo "错误: 未找到标准版镜像 fnnas_rockchip_elf3588_*.img.gz"; exit 1; }
echo "标准版镜像: $GZ"
gzip -d "$GZ"
IMG=$(ls *.img 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "错误: 解压后未找到 .img 文件"; exit 1; }
echo "解压得到: $IMG"
ls -lh "$IMG"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. 拉长镜像到 ROOTFS_GIB + 余量（保持小镜像，尾部零区留给扩展分区）
# ---------------------------------------------------------------------------
echo "::group::2/6 拉长镜像到 ${ROOTFS_GIB}GiB + 余量"
truncate -s "$TARGET_BYTES" "$IMG"
echo "truncate 完成: $(ls -lh "$IMG" | awk '{print $5}')"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. loop 挂载 + GPT 修复 + 分区扩展
# ---------------------------------------------------------------------------
echo "::group::3/6 挂载 loop 并扩展 rootfs 分区到 ${ROOTFS_GIB}GiB"
sudo modprobe loop 2>/dev/null || true
LOOP=$(sudo losetup -fP --show "$IMG")
echo "loop 设备: $LOOP"
sleep 2
if ! sudo lsblk -no PATH "$LOOP" | grep -q "^${LOOP}p"; then
    echo "loop 分区节点未自动创建，partx -a 扫描..."
    sudo partx -a "$LOOP" 2>/dev/null || true
    sleep 2
fi
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"

# 修复 GPT 备份头（truncate 后失效）：parted 询问 Fix/Ignore 时回答 fix
printf 'fix\n' | sudo parted ---pretend-input-tty "$LOOP" unit s print >/dev/null 2>&1 || true

# 找到 rootfs 分区号（btrfs 优先，ext4 兜底；排除 BOOT）
ROOTFS_PART_NUM=""
ROOTFS_DEV=""
BIGGEST=0
PARTS=$(sudo lsblk -no PATH "$LOOP" 2>/dev/null | grep "^${LOOP}p" || true)
for p in $PARTS; do
    [ -b "$p" ] || continue
    fstype=$(sudo lsblk -no FSTYPE "$p" 2>/dev/null || true)
    [ -n "$fstype" ] || fstype=$(sudo blkid -s TYPE -o value "$p" 2>/dev/null || true)
    size=$(sudo lsblk -bno SIZE "$p" 2>/dev/null || true)
    label=$(sudo lsblk -no LABEL "$p" 2>/dev/null || true)
    echo "  $p: fs=${fstype:-?} size=${size:-?} label=${label:-?}"
    if [ "$label" = "BOOT" ] || [ "$label" = "boot" ]; then
        echo "  跳过启动分区"; continue
    fi
    if [ "$fstype" = "btrfs" ] || [ "$fstype" = "ext4" ]; then
        if [ "${size:-0}" -gt "$BIGGEST" ]; then
            ROOTFS_DEV="$p"; BIGGEST="$size"
            ROOTFS_PART_NUM=$(basename "$p" | grep -oE '[0-9]+$')
        fi
    fi
done
[ -n "$ROOTFS_PART_NUM" ] || { echo "错误: 未找到 rootfs 分区"; exit 1; }
echo "rootfs 分区: $ROOTFS_DEV (编号 $ROOTFS_PART_NUM)"

# 扩展 rootfs 分区到 ROOTFS_GIB（parted 询问 Yes/No 时回答 Yes）
printf 'Yes\n' | sudo parted ---pretend-input-tty "$LOOP" resizepart "$ROOTFS_PART_NUM" "${ROOTFS_GIB}GiB" 2>&1 || true
sudo partx -u "$LOOP" 2>/dev/null || true
sudo partprobe "$LOOP" 2>/dev/null || true
sleep 2
echo "--- 扩展后 ---"
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. 挂载 rootfs，扩展文件系统到分区大小（btrfs resize max）
# ---------------------------------------------------------------------------
echo "::group::4/6 挂载 rootfs 并扩展文件系统"
sudo mount "$ROOTFS_DEV" "$MNT" || { echo "错误: mount $ROOTFS_DEV 失败"; exit 1; }
FSTYPE=$(sudo lsblk -no FSTYPE "$ROOTFS_DEV" | head -1)
if [ "$FSTYPE" = "btrfs" ]; then
    sudo btrfs filesystem resize max "$MNT"
else
    sudo e2fsck -f "$ROOTFS_DEV" || true
    sudo resize2fs "$ROOTFS_DEV"
fi
df -h "$MNT"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. 禁用一切扩展机制（删服务 + 改名工具 + fnnas.conf 置 no）
# ---------------------------------------------------------------------------
echo "::group::5/6 禁用扩展机制（服务/工具/配置）"
# 5.1 删除 resize-rootfs 服务（wants 链接 + 服务文件）
for f in \
    "$MNT/etc/systemd/system/multi-user.target.wants/resize-rootfs.service" \
    "$MNT/etc/systemd/system/resize-rootfs.service" \
    "$MNT/lib/systemd/system/resize-rootfs.service" \
    "$MNT/usr/lib/systemd/system/resize-rootfs.service"; do
    if [ -e "$f" ]; then
        sudo rm -f "$f" && echo "已删除: ${f#$MNT}"
    fi
done
# 5.2 改名扩展工具（谁调用都找不到）
for tool in fnnas-tf resize-rootfs.sh; do
    if [ -e "$MNT/usr/sbin/$tool" ]; then
        sudo mv "$MNT/usr/sbin/$tool" "$MNT/usr/sbin/$tool.disabled"
        echo "已改名: /usr/sbin/$tool → $tool.disabled"
    fi
done
# 5.3 fnnas.conf 置为禁用 + limit 与分区一致
CONF="$MNT/etc/fnnas.conf"
if [ -f "$CONF" ]; then
    if grep -q '^rootfs_limit_gib=' "$CONF"; then
        sudo sed -i "s|^rootfs_limit_gib=.*|rootfs_limit_gib=\"${ROOTFS_GIB}\"|" "$CONF"
    else
        echo "rootfs_limit_gib=\"${ROOTFS_GIB}\"" | sudo tee -a "$CONF" >/dev/null
    fi
    grep -q '^rootfs_resize=' "$CONF" \
        && sudo sed -i "s|^rootfs_resize=.*|rootfs_resize=\"no\"|" "$CONF" \
        || echo 'rootfs_resize="no"' | sudo tee -a "$CONF" >/dev/null
else
    printf 'rootfs_limit_gib="%s"\nrootfs_resize="no"\n' "$ROOTFS_GIB" | sudo tee "$CONF" >/dev/null
fi
echo "--- 修改后 fnnas.conf ---"
cat "$CONF"
sync
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 6. 卸载 + 重命名 + 压缩 + 校验
# ---------------------------------------------------------------------------
echo "::group::6/6 卸载并重新打包"
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
echo "说明: 烧录后 rootfs 固定 ${ROOTFS_GIB}G，扩展服务已禁用；"
if [ "${ROOTFS_GIB}" -ge 18 ]; then
  echo "      数据空间 = 设备盘容量 - ${ROOTFS_GIB}G（32G 盘 ≈ $((ROOTFS_GIB))G 系统 + ~11G 数据）"
else
  echo "      数据空间 = 设备盘容量 - ${ROOTFS_GIB}G（32G 盘 ≈ 8G 系统 + ~21G 数据；128G 盘 ≈ 8G 系统 + ~120G 数据）"
fi
