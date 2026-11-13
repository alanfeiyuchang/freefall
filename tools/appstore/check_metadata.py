#!/usr/bin/env python3
"""检查 docs/appstore/metadata/*.md 里每种语言的上架文案有没有超出 App Store Connect 的长度上限。

用法：python3 tools/appstore/check_metadata.py
每个文件里 `## name` / `## subtitle` / … 标题下面第一个 ``` 代码块就是要填进 App Store Connect 的原文。
上限见 docs/appstore/README.md（出处是 App Store Connect Help）。关键词按 UTF-8 字节数算以防万一（中日韩一个字 3 字节）。
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIMITS = {  # 字段：(上限, 按什么数)
    "name": (30, "chars"),
    "subtitle": (30, "chars"),
    "promotional_text": (170, "chars"),
    "description": (4000, "chars"),
    "keywords": (100, "bytes"),
    "whats_new": (4000, "chars"),
}
BLOCK = re.compile(r"^## (\w+)\s*\n+```\n(.*?)\n```", re.S | re.M)

bad = 0
for path in sorted(glob.glob(os.path.join(ROOT, "docs", "appstore", "metadata", "*.md"))):
    lang = os.path.basename(path)[:-3]
    fields = dict(BLOCK.findall(open(path, encoding="utf-8").read()))
    cells = []
    for key, (limit, unit) in LIMITS.items():
        text = fields.get(key)
        if text is None:
            print(f"{lang}: 缺 {key}")
            bad += 1
            continue
        n = len(text.encode("utf-8")) if unit == "bytes" else len(text)
        mark = "" if n <= limit else " ← 超了"
        bad += n > limit
        cells.append(f"{key} {n}/{limit}{mark}")
        if key == "keywords":
            words = text.split(",")
            if any(w != w.strip() for w in words):
                print(f"{lang}: 关键词逗号前后不要有空格（空格也占字数）")
                bad += 1
            name_words = set(re.split(r"[\s:：]+", fields.get("name", "").lower()))
            dup = [w for w in words if w.lower() in name_words]
            if dup:
                print(f"{lang}: 关键词和名称重复（名称本来就会被搜索）：{dup}")
    print(f"{lang:8} " + " · ".join(cells))
sys.exit(1 if bad else 0)
