#!/usr/bin/env python3
"""从 tools/l10n/strings.py 生成 Freefall/Resources/Localizable.xcstrings 和 InfoPlist.xcstrings（十种语言）。

用法：python3 tools/l10n/make.py
会检查：每行都有十种语言；格式占位符（%lld、%@、%.1f……）的种类和个数各语言一致。
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from strings import INFOPLIST, LANGS, STRINGS  # noqa: E402

SPEC = re.compile(r"%(?:\d+\$)?(lld|@|\.\d+f)")


def specs(s):
    return sorted(SPEC.findall(s))


def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}


def build(rows, key_is_zh):
    out = {}
    for row in rows:
        if key_is_zh:
            key, values = row[0], dict(zip(LANGS, row[1:]))
            values["zh-Hans"] = key
        else:
            key, zh, rest = row[0], row[1], row[2:]
            values = dict(zip(LANGS, rest))
            values["zh-Hans"] = zh
        if len(values) != len(LANGS) + 1 or any(not v for v in values.values()):
            sys.exit(f"缺语言：{key!r}")
        if key in out:
            sys.exit(f"重复的键：{key!r}")
        want = specs(values["zh-Hans"])
        for lang, v in values.items():
            if specs(v) != want:
                sys.exit(f"占位符对不上（{lang}）：{key!r} → {v!r}")
        out[key] = {"extractionState": "manual",
                    "localizations": {lang: unit(values[lang]) for lang in sorted(values)}}
    return {"sourceLanguage": "en", "strings": out, "version": "1.0"}


for name, rows, key_is_zh in [("Localizable", STRINGS, True), ("InfoPlist", INFOPLIST, False)]:
    path = os.path.join(ROOT, "Freefall", "Resources", f"{name}.xcstrings")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(build(rows, key_is_zh), f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{name}.xcstrings：{len(rows)} 条 × {len(LANGS) + 1} 种语言")
