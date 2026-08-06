#!/usr/bin/env bash
# =============================================================================
# shrink-data10g.sh — 把标准版 ELF3588 镜像改造成 "系统 12G + 数据自适应" 版
#
# 背景（踩坑结论）：
#   设备上扩展流程有两条：
#     1. fnnas-tf（ophub 官方）——遵守 /etc/fnnas.conf 的 rootfs_limit_gib，
#        盘 > limit 时只扩到 limit 大小（受限策略）。已验证在用户设备上
#        成功把分区从 6.4G 扩到 19G。
#     2. resize-rootfs.sh（飞牛自己的脚本）——逻辑 "Disk <= 28GB → resize to 99%"，
#        不读 fnnas.conf，在 fnnas-tf 之后把 rootfs 再扩满整盘（元凶）。
#
# 本脚本（镜像保持 6.6G 小体积，不 truncate）：
#   1. 解压标准版镜像（原样，分区 6.4G）
#   2. 挂载 rootfs
#   3. 把 /usr/sbin/resize-rootfs.sh 改名（掐死 99% 元凶）
#   4. 把 resize-rootfs.service 的 ExecStart 改回 fnnas-tf（如果指向 resize-rootfs.sh）
#   5. fnnas.conf 置 rootfs_limit_gib=${ROOTFS_GIB} + rootfs_resize="yes"
#   6. 重打包发布
#
# 结果：烧录后首次启动 fnnas-tf 自动把 rootfs 扩到 ${ROOTFS_GIB}G（受限策略），
#       元凶脚本已死，不会再有 99% 扩展。镜像尾部到盘尾全部未分配：
#       32G 盘 → ~17G 数据；128G 盘 → ~116G 数据（自适应盘容量）。
#
# 所需环境变量：
#   DATE（必填，如 2026.07.12）、KERNEL_VERSION（可选）、
#   ROOTFS_GIB（可选，默认 12，系统分区目标大小，写进 fnnas.conf）
# =============================================================================
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$REPO_ROOT/work10g"
OUT="$REPO_ROOT/out10g"

: "${DATE:?缺少 DATE（标准版镜像日期，如 2026.07.12）}"
KERNEL_VERSION="${KERNEL_VERSION:-unknown}"
ROOTFS_GIB="${ROOTFS_GIB:-12}"       # fnnas.conf 的 rootfs_limit_gib（GiB）
PREINSTALL="${PREINSTALL:-yes}"      # 是否预装桌面/软件（qemu chroot）

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
# 1. 解压标准版镜像（保持 6.6G 小体积，不做任何 truncate）
# ---------------------------------------------------------------------------
echo "::group::1/6 解压标准版镜像"
GZ=$(ls fnnas_rockchip_elf3588_*.img.gz 2>/dev/null | head -1 || true)
[ -n "$GZ" ] || { echo "错误: 未找到标准版镜像 fnnas_rockchip_elf3588_*.img.gz"; exit 1; }
echo "标准版镜像: $GZ"
gzip -d "$GZ"
IMG=$(ls *.img 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "错误: 解压后未找到 .img 文件"; exit 1; }
echo "解压得到: $IMG（保持原体积，烧录后由 fnnas-tf 按配置扩展）"
ls -lh "$IMG"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. loop 挂载，定位 rootfs 分区
# ---------------------------------------------------------------------------
echo "::group::2/6 挂载 loop 并定位 rootfs 分区"
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
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. 挂载 rootfs，诊断现有扩展机制
# ---------------------------------------------------------------------------
echo "::group::3/6 挂载 rootfs 并诊断扩展机制"
sudo mount "$ROOTFS_DEV" "$MNT" || { echo "错误: mount $ROOTFS_DEV 失败"; exit 1; }

echo "--- resize-rootfs.service 文件 ---"
for f in \
    "$MNT/etc/systemd/system/resize-rootfs.service" \
    "$MNT/lib/systemd/system/resize-rootfs.service" \
    "$MNT/usr/lib/systemd/system/resize-rootfs.service"; do
    if [ -e "$f" ]; then
        echo "### ${f#$MNT}"
        cat "$f"
    fi
done
echo "--- wants 链接 ---"
for d in "$MNT"/etc/systemd/system/*.wants "$MNT"/etc/systemd/system/multi-user.target.wants; do
    [ -d "$d" ] && ls "$d" | grep -i resize && echo "  (位于 ${d#$MNT})" || true
done
echo "--- 相关工具存在性 ---"
for tool in fnnas-tf resize-rootfs.sh; do
    [ -e "$MNT/usr/sbin/$tool" ] && echo "存在: /usr/sbin/$tool" || echo "不存在: /usr/sbin/$tool"
done
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. 掐死 99% 元凶 + 让 service 指向 fnnas-tf + fnnas.conf 设 limit
# ---------------------------------------------------------------------------
echo "::group::4/6 改造扩展机制（保留 fnnas-tf，掐死 resize-rootfs.sh）"
# 4.1 改名 resize-rootfs.sh（99% 元凶）
if [ -e "$MNT/usr/sbin/resize-rootfs.sh" ]; then
    sudo mv "$MNT/usr/sbin/resize-rootfs.sh" "$MNT/usr/sbin/resize-rootfs.sh.disabled"
    echo "已改名: /usr/sbin/resize-rootfs.sh → resize-rootfs.sh.disabled"
fi
# 4.2 把 resize-rootfs.service 的 ExecStart 改回 fnnas-tf（若指向 resize-rootfs.sh）
for f in \
    "$MNT/etc/systemd/system/resize-rootfs.service" \
    "$MNT/lib/systemd/system/resize-rootfs.service" \
    "$MNT/usr/lib/systemd/system/resize-rootfs.service"; do
    if [ -e "$f" ]; then
        if grep -q "resize-rootfs.sh" "$f"; then
            sudo sed -i 's|ExecStart=.*resize-rootfs\.sh.*|ExecStart=/usr/sbin/fnnas-tf|' "$f"
            echo "已修改: ${f#$MNT} ExecStart → /usr/sbin/fnnas-tf"
            grep -n "ExecStart" "$f" || true
        else
            echo "无需修改: ${f#$MNT}（已指向 fnnas-tf）"
        fi
    fi
done
# 4.3 fnnas.conf：limit=${ROOTFS_GIB} + resize=yes（启用 fnnas-tf 受限扩展）
CONF="$MNT/etc/fnnas.conf"
if [ -f "$CONF" ]; then
    if grep -q '^rootfs_limit_gib=' "$CONF"; then
        sudo sed -i "s|^rootfs_limit_gib=.*|rootfs_limit_gib=\"${ROOTFS_GIB}\"|" "$CONF"
    else
        echo "rootfs_limit_gib=\"${ROOTFS_GIB}\"" | sudo tee -a "$CONF" >/dev/null
    fi
    grep -q '^rootfs_resize=' "$CONF" \
        && sudo sed -i "s|^rootfs_resize=.*|rootfs_resize=\"yes\"|" "$CONF" \
        || echo 'rootfs_resize="yes"' | sudo tee -a "$CONF" >/dev/null
else
    printf 'rootfs_limit_gib="%s"\nrootfs_resize="yes"\n' "$ROOTFS_GIB" | sudo tee "$CONF" >/dev/null
fi
echo "--- 修改后 fnnas.conf ---"
cat "$CONF"
sync
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. 预装软件（XFCE 桌面 + XRDP + python3-tk + aiohttp），默认开启
#    runner 为 x86_64，镜像 rootfs 为 arm64 → qemu-user + chroot 模拟安装
# ---------------------------------------------------------------------------
echo "::group::5/6 预装软件（qemu chroot: 桌面 + python3-tk + aiohttp）"
if [ "$PREINSTALL" = "yes" ]; then
    # 5.1 安装 qemu-user-static 并注册 binfmt（arm64 模拟）
    sudo apt-get update
    sudo apt-get install -y qemu-user-static binfmt-support
    sudo systemctl restart systemd-binfmt 2>/dev/null || sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true
    sudo cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/" 2>/dev/null || true

    # 5.2 挂载虚拟文件系统 + DNS（chroot 需要）
    sudo mount --bind /dev "$MNT/dev"
    sudo mount --bind /dev/pts "$MNT/dev/pts"
    sudo mount --bind /proc "$MNT/proc"
    sudo mount --bind /sys "$MNT/sys"
    sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

    # 5.3 拷贝安装脚本（vendor 版 + 补充包），chroot 里执行
    sudo cp "$REPO_ROOT/scripts/vendor/FnOS_Install_Desktop.sh" "$MNT/tmp/"
    # chroot 无运行中的 systemd：restart 替换为 true（enable 保留 → xrdp 开机自启）
    sudo sed -i 's|systemctl restart xrdp-sesman"|true"|; s|systemctl restart xrdp"|true"|' "$MNT/tmp/FnOS_Install_Desktop.sh"
    cat > /tmp/preinstall_extra.sh <<'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
bash /tmp/FnOS_Install_Desktop.sh
apt-get install -y python3-tk python3-pip
pip install aiohttp --break-system-packages
EOF
    sudo cp /tmp/preinstall_extra.sh "$MNT/tmp/"

    echo "开始 chroot 安装（qemu 模拟 arm64，桌面安装约需 15-25 分钟）..."
    sudo chroot "$MNT" /bin/bash /tmp/preinstall_extra.sh

    # 5.4 清理（防止 qemu 残留/污染镜像）
    sudo rm -f "$MNT/tmp/FnOS_Install_Desktop.sh" "$MNT/tmp/preinstall_extra.sh" "$MNT/usr/bin/qemu-aarch64-static"
    sudo umount "$MNT/dev/pts" 2>/dev/null || true
    sudo umount "$MNT/dev" 2>/dev/null || true
    sudo umount "$MNT/proc" 2>/dev/null || true
    sudo umount "$MNT/sys" 2>/dev/null || true
    echo "预装完成: XFCE + XRDP + python3-tk + aiohttp"
else
    echo "PREINSTALL=no，跳过预装"
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 6. 卸载 + 重命名 + 压缩 + 校验
# ---------------------------------------------------------------------------
echo "::group::6/6 卸载并重新打包"
sudo umount "$MNT"
sudo losetup -d "$LOOP"
LOOP=""

OUT_BASE="fnnas_rockchip_elf3588_sys12g_k${KERNEL_VERSION}_${DATE}.img"
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
echo "说明: 镜像保持小体积（解压后 $(ls -lh *.img.gz | awk '{print $5}') 压缩包），烧录后首次启动 fnnas-tf 按"
echo "      fnnas.conf 把 rootfs 扩到 ${ROOTFS_GIB}G（受限策略，99% 元凶已死）。"
if [ "$PREINSTALL" = "yes" ]; then
  echo "      已预装: XFCE 桌面 + XRDP + 中文字体 + python3-tk + aiohttp（开箱即用）"
fi
echo "      数据空间 = 设备盘容量 - ${ROOTFS_GIB}G（32G 盘 ≈ ${ROOTFS_GIB}G 系统 + ~$((32 - ROOTFS_GIB))G 数据；128G 盘 ≈ ${ROOTFS_GIB}G 系统 + ~$((128 - ROOTFS_GIB))G 数据）"
