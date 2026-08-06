# ELF3588 飞牛 FnOS 镜像自动构建

> 官方（ophub/fnnas）每次发布新的香橙派 5 Plus 飞牛镜像时，本项目自动下载 →
> 应用 ELF3588 设备树魔改 → 产出 ELF3588 专用镜像并发布到 Release，直接下载烧写即可。

## 原理

飞牛 FnOS 官方为香橙派 5 Plus 发布镜像（`fnnas_rockchip_orangepi-5-plus_k<内核>_<日期>.img.gz`）。
ELF3588 与 OK3588-C 硬件高度相似，但启动分区里的设备树不匹配。本项目定时检查官方 Release，
发现新镜像后自动执行与 [手动移植教程](https://resona.top/ok3588-c-yi-zhi-fei-niu-fnos/) 相同的步骤：

```mermaid
graph LR
    A[官方新镜像] --> B[下载+sha256校验]
    B --> C[下载同版本内核源码]
    C --> D[编译 rk3588-elf2.dtb]
    D --> E[替换启动分区 dtb + 改 fdtfile]
    E --> F[重新打包 gz]
    F --> G[发布到本项目 Release]
```

## 仓库结构

```
.
├── .github/workflows/
│   ├── build.yml                # 自动构建工作流（定时 + 手动）
│   └── build-sys12g.yml         # 数据版构建（系统 12G + 数据自适应 + 预装软件）
├── dts/
│   └── rk3588-elf2.dts           # ELF3588 专用设备树（已验证，含 USB3.0 quirk 修复）
├── scripts/
│   ├── check-upstream.py         # 检测上游新镜像（按文件名+sha256 跟踪，不重复构建）
│   ├── build-image.sh            # 构建脚本（复刻 4/29 手动流程）
│   ├── shrink-data10g.sh         # 数据版改造脚本（停用越权扩展 + fnnas-tf 扩 12G + 预装）
│   └── vendor/
│       └── FnOS_Install_Desktop.sh  # XFCE 桌面安装脚本（vendor 固定版本）
├── state/
│   └── last-built.txt            # 已构建记录（工作流自动维护）
└── README.md
```

## 使用方法

### 1. 首次部署（约 5 分钟）

1. 在 GitHub 新建一个 **public** 仓库（public 仓库的 Actions 分钟数与 Release
   存储/流量全免费；private 仓库有 500MB Release 存储限制，1.8GB 镜像放不下）
2. 把本目录推上去：

   ```bash
   cd fnos-elf3588
   git init
   git add .
   git commit -m "init: ELF3588 FnOS 自动构建"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

3. 打开仓库 **Actions** 页面 → 左侧选 **Build ELF3588 FnOS Image** → 右侧
   **Run workflow** 手动触发一次，把当前最新镜像构建出来

### 2. 日常使用

- 每天 10:00（北京时间）自动检查一次，有新版自动构建并发 Release（标准版 + 数据版两个镜像）
- 打开仓库 **Releases** 页下载镜像：
  - `fnnas_rockchip_elf3588_k*.img.gz`（标准版：rootfs 自动扩满整盘）
  - `fnnas_rockchip_elf3588_sys12g_k*.img.gz`（数据版：rootfs 扩到 12G，尾部数据空间自适应，**已预装桌面/软件**）
- 校验：`sha256sum -c SHA256SUMS`
- 解压后按原方法烧写（dd 到 TF 卡 / eMMC 或 rk3588 烧写工具）

> 提示：32G eMMC 设备建议用 **数据版（sys12g）**——烧录后在飞牛
> 「设置 → 存储空间管理 → 创建存储空间」即可用内置 eMMC 的 17G+ 空间；
> 标准版 rootfs 会扩满整盘，没有剩余空间可建存储空间。
> （sys12g 方案已在真机验证：rootfs 12G + 数据空间正常 + 预装软件可用）
>
> **数据版原理（v3 方案）**：设备上 rootfs 扩展有两条机制——
> ① fnnas-tf（官方，遵守 `/etc/fnnas.conf` 的 `rootfs_limit_gib` 受限策略）；
> ② resize-rootfs.sh（飞牛自带，逻辑“Disk ≤ 28GB → 扩到 99%”，**不读配置**，
>    会覆盖 ① 把 rootfs 扩满整盘——前两版失败根因）。
> 数据版镜像直接：把 `resize-rootfs.sh` 改名停用 + 把 service ExecStart 指回
> fnnas-tf + fnnas.conf 置 `rootfs_limit_gib=12` + `rootfs_resize=yes`。
> 烧录后 fnnas-tf 首启把 rootfs 扩到 12G，rootfs 大小保持固定；尾部剩余空间
> 全部未分配（32G 盘 ≈ 17G，128G 盘 ≈ 116G），供飞牛创建存储空间。
>
> **预装软件**（开箱即用）：XFCE 桌面 + XRDP + 中文字体、python3-tk、aiohttp
> （构建时 qemu 模拟 arm64 chroot 安装，脚本 vendor 在 `scripts/vendor/`）。

### 3. 烧写方法（RKDevTool，eMMC）

> 图片为实际烧写过程截图（RKDevTool v3.32，Loader v1.11），与下述步骤对应。

**物料**：解压后的 `*.img` + `MiniLoaderAll.bin`（G 盘镜像目录内）

**步骤**：
1. **解压**：`tar -xzf xxx.img.gz`（或 Etcher 直接烧录 .gz；不要用 7-Zip 双击解压，会把 .img 解成目录）
2. 打开瑞芯微开发工具（RKDevTool）→ **升级固件** 标签页
3. **Loader** 栏选择 `MiniLoaderAll.bin`（版本 1.11）
4. **固件** 栏选择解压好的 `.img`（地址 0x00000000）
5. 设备通过 USB 连接并进入 **Maskrom 模式**（或 Loader 模式），工具显示"发现一个 Maskrom 设备"
6. 点 **开始**（升级固件，强制按地址写）

**烧写日志流程**（截图可见）：

```
下载 Boot → 等待 Maskrom → 测试设备 → 校验芯片 → 获取 Flash 信息
→ 准备 IDB → 下载 IDB → 切换存储到 EMMC → 下载固件 → 完成
```

**烧写后验证**：
- `lsblk` 应看到 `mmcblk0p2` 约 12G（rootfs），尾部剩余未分配
- 飞牛「设置 → 存储空间管理 → 创建存储空间」使用剩余空间（32G 盘约 17G）
- XFCE 桌面 / XRDP / python3-tk / aiohttp 已预装，可直接使用

### 4. Release 命名

- 标准版 tag: `elf3588-<日期>`（如 `elf3588-2026.07.12`）
- 数据版 tag: `elf3588-sys12g-<日期>`（如 `elf3588-sys12g-2026.07.12`）
- 标准版镜像: `fnnas_rockchip_elf3588_k<内核>_<日期>.img.gz`
- 数据版镜像: `fnnas_rockchip_elf3588_sys12g_k<内核>_<日期>.img.gz`

> 数据版流水线（build-sys12g.yml）由标准版成功后自动触发，无需手动干预。
> 标准版产出的镜像内部文件名已统一为 elf3588（不再残留 orangepi-5-plus）。

## 常见问题

| 问题 | 说明 |
|---|---|
| **构建失败：设备树编译报错** | 多为官方升级了内核版本（如 k6.20.x），dts 里引用的节点有变动。看日志里报错的 dts 行，按 4/29 当时的经验微调 `dts/rk3588-elf2.dts` 后重新触发即可 |
| **磁盘空间不足** | 标准 runner 约 14GB，脚本已做边用边删（峰值约 8GB）。若未来镜像增大，可换 `larger runner` 或自建 runner |
| **private 仓库 Release 上传失败** | private 仓库 Release 有存储配额，建议 public |
| **state 文件提交失败** | 若仓库开了分支保护，需在 Settings → Actions 里给 GITHUB_TOKEN 配置写权限，或改用其他方式记录状态 |
| **官方很久没更新** | 检测脚本每天只调一次 API，无新镜像时流程正常退出、不产生任何开销 |

## 本地调试（可选）

```bash
# 检测脚本（无需网络以外依赖）
python3 scripts/check-upstream.py

# 构建脚本需要 aarch64 交叉编译工具链 + sudo 挂载权限，建议直接在 CI 里跑
```

## 参考

- 上游: https://github.com/ophub/fnnas
- 移植教程: https://resona.top/
- 内核源码: https://www.kernel.org/
