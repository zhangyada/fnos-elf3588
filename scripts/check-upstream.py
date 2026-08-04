#!/usr/bin/env python3
"""
check-upstream.py — 检测 ophub/fnnas 上游是否有新的 orangepi-5-plus FnOS 镜像。

工作方式：
1. 请求 GitHub API 获取 ophub/fnnas 的最新 release
2. 筛选出所有 fnnas_rockchip_orangepi-5-plus_*.img.gz 资产
3. 与 state/last-built.txt 中已构建过的记录对比
4. 把新增的镜像写入 $GITHUB_OUTPUT（workflow 用它做矩阵构建）

输出（写入 $GITHUB_OUTPUT）：
  new_count   新增数量
  matrix      JSON 数组，格式 {"include": [...]}，供 workflow matrix 使用

依赖：Python 3 标准库，无第三方包。
"""
import json
import os
import re
import sys
import urllib.request

UPSTREAM_REPO = os.environ.get("UPSTREAM_REPO", "ophub/fnnas")
STATE_FILE = os.environ.get("STATE_FILE", "state/last-built.txt")

# 例: fnnas_rockchip_orangepi-5-plus_k6.18.18_2026.07.12.img.gz
ASSET_PATTERN = re.compile(
    r"^fnnas_rockchip_orangepi-5-plus_(k\d+\.\d+\.\d+)_(\d{4}\.\d{2}\.\d{2})\.img\.gz$"
)


def fetch_json(url: str):
    """GET 一个 JSON URL，带 User-Agent（GitHub API 要求）。"""
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "fnos-elf3588-builder",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def load_built(path: str) -> set:
    """读取已构建记录，返回 asset_name 集合。空行和 # 注释忽略。"""
    if not os.path.exists(path):
        return set()
    built = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                built.add(line.split()[0])  # 每行格式: <asset_name> <sha256>
    return built


def main() -> int:
    built = load_built(STATE_FILE)

    try:
        latest = fetch_json(f"https://api.github.com/repos/{UPSTREAM_REPO}/releases/latest")
    except Exception as exc:  # 网络/API 出错要显式失败，让 workflow 报警
        print(f"[ERROR] 无法获取上游 release: {exc}", file=sys.stderr)
        return 1

    upstream_tag = latest.get("tag_name", "unknown")

    new_assets = []
    for asset in latest.get("assets", []):
        name = asset.get("name", "")
        m = ASSET_PATTERN.match(name)
        if not m:
            continue
        if name in built:
            continue
        kernel_full = m.group(1)   # k6.18.18
        date = m.group(2)          # 2026.07.12
        digest = asset.get("digest", "") or ""
        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]

        new_assets.append({
            "asset_name": name,
            "asset_url": asset.get("browser_download_url", ""),
            "asset_digest": digest,
            "kernel_version": kernel_full[1:],   # 6.18.18
            "date": date,
            "upstream_tag": upstream_tag,
            "release_tag": f"elf3588-{date}",
        })

    # 按日期排序，旧的先构建（一个 release 下可能有多个日期的镜像）
    new_assets.sort(key=lambda x: x["date"])

    print(f"[INFO] 上游 tag: {upstream_tag}，共 {len(new_assets)} 个新镜像")
    for a in new_assets:
        print(f"  - {a['asset_name']}  (k{a['kernel_version']}, {a['date']})")

    # 写入 GitHub Actions 输出
    out_path = os.environ.get("GITHUB_OUTPUT")
    if out_path:
        with open(out_path, "a", encoding="utf-8") as out:
            out.write(f"new_count={len(new_assets)}\n")
            if new_assets:
                out.write(f"matrix={json.dumps({'include': new_assets}, ensure_ascii=False)}\n")
    else:
        # 本地调试时直接打印
        print(json.dumps({"include": new_assets}, ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
