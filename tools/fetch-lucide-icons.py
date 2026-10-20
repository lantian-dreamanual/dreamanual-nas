#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Lucide 官方 SVG 落成 Assets.xcassets 里的 `lucide-<name>.imageset`。

图标名不在这里列第二遍：直接从 `DesignSystem.swift` 的 `symbolFallback` 取键，
那张表就是「这个 app 会请求哪些图标」的唯一清单 —— 两处各写一份迟早会漂。

为什么要有这个脚本：`LucideIcon` 先找 bundle 里的 `lucide-<name>` 图，找不到才退
SF Symbols。资产缺一枚，真机上那枚就画成 SF 的近似形态（或者问号），肉眼很难发现。
2026-10-20 之前只有 3 枚有资产，其余 46 枚其实全是 SF 兜底 —— 形态接近、不是 Lucide。

用法：
    python3 tools/fetch-lucide-icons.py            # 只补缺的
    python3 tools/fetch-lucide-icons.py --force    # 全量重下（Lucide 发新版后跑）
    python3 tools/fetch-lucide-icons.py --check    # 只核对，不写盘（缺一枚就非零退出）

面性变体：Lucide 只出线性图。播放 / 暂停 / 上一首 / 下一首这四个**按键**要面性
（用户 2026-10-20 拍板：除这四个以外一律线性），所以额外生成 `<name>-fill`：
把根节点的 `fill="none"` 改成 `currentColor`，描边保留 —— 实心三角 / 实心竖条。
"""

import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
DESIGN = ROOT / "DreamanualNAS/DesignSystem/DesignSystem.swift"
ASSETS = ROOT / "DreamanualNAS/Assets.xcassets"
BASE = "https://cdn.jsdelivr.net/npm/lucide-static@latest/icons/%s.svg"

# 面性白名单：只有这四个运送键例外，其余一律线性。
FILLED = ("play", "pause", "skip-back", "skip-forward")

CONTENTS = """{{
  "images" : [
    {{
      "filename" : "{file}",
      "idiom" : "universal"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }},
  "properties" : {{
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }}
}}
"""


def names_from_table() -> list[str]:
    text = DESIGN.read_text(encoding="utf-8")
    start = text.index("symbolFallback: [String: String] = [")
    block = text[start:]
    block = block[: block.index("\n    ]")]
    return [k for k, _ in re.findall(r'"([^"]+)":\s*"([^"]+)"', block)]


def fetch(name: str, suffix: str = "") -> str:
    url = BASE % name
    with urllib.request.urlopen(url, timeout=20) as resp:
        return resp.read().decode("utf-8")


def fill_variant(svg: str) -> str:
    """把线性图变成面性：根节点 fill 换成 currentColor，描边留着。"""
    if 'fill="none"' not in svg:
        raise SystemExit("这份 SVG 没有 fill=\"none\"，面性变体的改法要重看")
    return svg.replace('fill="none"', 'fill="currentColor"', 1)


def write_imageset(slug: str, svg: str, force: bool) -> bool:
    folder = ASSETS / f"lucide-{slug}.imageset"
    svg_file = folder / f"lucide-{slug}.svg"
    if folder.exists() and svg_file.exists() and not force:
        return False
    folder.mkdir(parents=True, exist_ok=True)
    svg_file.write_text(svg, encoding="utf-8")
    (folder / "Contents.json").write_text(
        CONTENTS.format(file=f"lucide-{slug}.svg"), encoding="utf-8")
    return True


def main() -> int:
    force = "--force" in sys.argv
    check_only = "--check" in sys.argv
    names = names_from_table()
    if not names:
        print("没从兜底表里读到图标名", file=sys.stderr)
        return 2

    missing, written, failed = [], [], []
    for name in names:
        folder = ASSETS / f"lucide-{name}.imageset"
        if check_only:
            if not folder.exists():
                missing.append(name)
            continue
        try:
            if write_imageset(name, fetch(name), force):
                written.append(name)
        except Exception as err:  # 网络或改名：报出来，别静默
            failed.append((name, str(err)))

    for name in FILLED:
        folder = ASSETS / f"lucide-{name}-fill.imageset"
        if check_only:
            if not folder.exists():
                missing.append(f"{name}-fill")
            continue
        try:
            if write_imageset(f"{name}-fill", fill_variant(fetch(name)), force):
                written.append(f"{name}-fill")
        except Exception as err:
            failed.append((f"{name}-fill", str(err)))

    total = len(names) + len(FILLED)
    if check_only:
        if missing:
            print(f"缺 {len(missing)} 枚资产：{'、'.join(missing)}")
            return 1
        print(f"{total} 枚 lucide 资产齐了")
        return 0

    print(f"扫描 {len(names)} 枚线性 + {len(FILLED)} 枚面性 = {total}")
    print(f"新写 {len(written)} 枚，已有 {total - len(written) - len(failed)} 枚")
    if failed:
        for name, err in failed:
            print(f"  失败 {name}：{err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
