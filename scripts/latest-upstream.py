#!/usr/bin/env python3
"""
latest-upstream.py — 输出 ophub/fnnas 上游当前提供的最新 orangepi-5-plus 镜像的内核版本和日期。

输出（stdout）："<kernel> <date>"，例如 "6.12.41 2026.06.25"
若查询失败或无匹配则向 stderr 报错并返回非 0。

用途：build-sys12g.yml 用它对齐上游当前镜像。
     不能按日期字典序选标准版 tag——上游切换内核后（如 6.18 -> 6.12 LTS），
     新镜像日期可能比旧内核镜像更早（6.12.41_06.25 < 6.18.18_07.12），
     按日期排序会选到旧内核；这里直接对齐上游当前提供的镜像。
"""
import json
import re
import sys
import urllib.request

UPSTREAM_REPO = "ophub/fnnas"

# 例: fnnas_rockchip_orangepi-5-plus_k6.12.41_2026.06.25.img.gz
ASSET_PATTERN = re.compile(
    r"^fnnas_rockchip_orangepi-5-plus_(k\d+\.\d+\.\d+)_(\d{4}\.\d{2}\.\d{2})\.img\.gz$"
)


def main() -> int:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{UPSTREAM_REPO}/releases/latest",
        headers={
            "User-Agent": "fnos-elf3588-builder",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        data = json.load(urllib.request.urlopen(req, timeout=60))
    except Exception as exc:
        print(f"[ERROR] 无法获取上游 release: {exc}", file=sys.stderr)
        return 1

    items = []
    for asset in data.get("assets", []):
        m = ASSET_PATTERN.match(asset.get("name", ""))
        if m:
            items.append((m.group(2), m.group(1)[1:]))  # (date, kernel)

    if not items:
        print("[ERROR] 上游 release 中未找到 orangepi-5-plus 镜像", file=sys.stderr)
        return 1

    items.sort()
    date, kernel = items[-1]  # 最新日期的那条
    print(f"{kernel} {date}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
