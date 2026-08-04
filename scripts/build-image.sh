#!/usr/bin/env bash
# =============================================================================
# build-image.sh — 把一个官方 orangepi-5-plus 的 FnOS 镜像改造成 ELF3588 专用镜像
#
# 完整复刻 2026-04-29 手动操作流程：
#   1. 下载官方镜像并校验 sha256
#   2. 解压得到 .img
#   3. 下载对应内核版本源码（版本号从文件名 kX.Y.Z 解析）
#   4. 放入 dts/rk3588-elf2.dts，defconfig + 交叉编译 rk3588-elf2.dtb
#   5. 挂载启动分区（GPT 分区1，偏移 32768*512），写入 dtb 并把 armbianEnv.txt 的 fdtfile 指到它
#   6. gzip 重新打包，输出 fnnas_rockchip_elf3588_*.img.gz + SHA256SUMS
#
# 所需环境变量（由 GitHub Actions matrix 传入）：
#   ASSET_NAME / ASSET_URL / ASSET_DIGEST / KERNEL_VERSION / DATE
# 可选：UPSTREAM_TAG（用于日志）
# =============================================================================
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$REPO_ROOT/work"
OUT="$REPO_ROOT/out"

: "${ASSET_NAME:?缺少 ASSET_NAME}"
: "${ASSET_URL:?缺少 ASSET_URL}"
: "${ASSET_DIGEST:?缺少 ASSET_DIGEST}"
: "${KERNEL_VERSION:?缺少 KERNEL_VERSION}"
: "${DATE:?缺少 DATE}"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# 出错时尽量卸载分区，避免残留导致后续步骤异常
trap 'sudo umount /mnt/fnos 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# 1. 下载官方镜像 + sha256 校验
# ---------------------------------------------------------------------------
echo "::group::1/7 下载官方镜像 ($ASSET_NAME)"
curl -fL --retry 3 --retry-delay 5 -o "$ASSET_NAME" "$ASSET_URL"
echo "$ASSET_DIGEST  $ASSET_NAME" | sha256sum -c -
ls -lh "$ASSET_NAME"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. 解压（gzip -d 成功后 .gz 自动删除）
# ---------------------------------------------------------------------------
echo "::group::2/7 解压镜像"
gzip -d "$ASSET_NAME"
IMG="${ASSET_NAME%.gz}"
ls -lh "$IMG"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. 下载对应版本内核源码（从 cdn.kernel.org）
# ---------------------------------------------------------------------------
echo "::group::3/7 下载内核源码 linux-$KERNEL_VERSION"
MAJOR="${KERNEL_VERSION%%.*}"                       # 6.18.18 -> 6
KTARBALL="linux-$KERNEL_VERSION.tar.xz"
KURL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/$KTARBALL"
echo "  下载: $KURL"
curl -fL --retry 3 --retry-delay 5 -o "$KTARBALL" "$KURL"
tar -xf "$KTARBALL"
rm -f "$KTARBALL"                                    # 解压完即删，省磁盘
KSRC="linux-$KERNEL_VERSION"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. 放入设备树，生成基础配置（无 .config 时顶层 make 会拒绝编译），交叉编译
# ---------------------------------------------------------------------------
echo "::group::4/7 交叉编译 rk3588-elf2.dtb"
cp "$REPO_ROOT/dts/rk3588-elf2.dts" "$KSRC/arch/arm64/boot/dts/rockchip/rk3588-elf2.dts"
cd "$KSRC"
# defconfig 仅为满足内核 make 的 .config 检查（arm64 默认配置已含 Rockchip 支持），
# 不影响 dtb 产物内容；FnOS 官方镜像启动分区里并没有 config 文件，不能依赖它
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- rockchip/rk3588-elf2.dtb -j"$(nproc)"
cd "$WORK"
DTB="$KSRC/arch/arm64/boot/dts/rockchip/rk3588-elf2.dtb"
test -f "$DTB" && echo "  dtb 编译成功: $DTB"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. 挂载启动分区，写入 dtb + 修改 armbianEnv.txt
# ---------------------------------------------------------------------------
echo "::group::5/7 挂载启动分区并写入 dtb"
sudo mkdir -p /mnt/fnos
sudo mount -o loop,offset=$((32768 * 512)) "$IMG" /mnt/fnos
sudo cp "$DTB" /mnt/fnos/dtb/rockchip/
sudo sed -i 's|^fdtfile=.*|fdtfile=rockchip/rk3588-elf2.dtb|' /mnt/fnos/armbianEnv.txt
echo "  --- armbianEnv.txt ---"
sudo cat /mnt/fnos/armbianEnv.txt
ls -la /mnt/fnos/
sudo umount /mnt/fnos
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 6. 清理内核源码 + 重新打包 + 校验
# ---------------------------------------------------------------------------
echo "::group::6/7 重新打包"
rm -rf "$WORK/$KSRC"                                   # 内核源码已用完，删除省磁盘

OUT_NAME="fnnas_rockchip_elf3588_k${KERNEL_VERSION}_${DATE}.img.gz"
gzip -9 -c "$IMG" > "$OUT/$OUT_NAME"
rm -f "$IMG"

cd "$OUT"
sha256sum "$OUT_NAME" > SHA256SUMS
ls -lh
echo "::endgroup::"

echo ""
echo "构建完成: $OUT/$OUT_NAME"
cat SHA256SUMS
