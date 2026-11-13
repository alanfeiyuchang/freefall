# Freefall 上架材料

都在 release 分支上（`claude/release-d0a64c`，从 master 3ddce3a 切出）。上架文案按**合并皮肤那批改动以后**的功能写
（皮肤解锁、从 5,000 英尺练习、航线回看、自动 / 手动拉平、游戏内选语言）；如果那批改动最后有删减，对应改文案。

| 文件 | 内容 |
|---|---|
| [release-vs-master.md](release-vs-master.md) | release 分支和 master 的差别、怎么验证的、以后怎么从 master 合并 |
| [metadata/](metadata/) | 十种语言各一份：名称、副标题、推广文本、描述、关键词、此版本新增内容 |
| [privacy.md](privacy.md) | 代码核查结论、App 隐私问卷怎么答、隐私清单、两条权限说明、隐私政策草稿（中英） |
| [review-and-rating.md](review-and-rating.md) | 类别、年龄分级问卷、App Motion Information、审核备注（英文，可直接粘贴） |
| [screenshots.md](screenshots.md) | 截图和预览视频的规格、拍摄清单、每张配的文案、离屏渲染的候选图 |
| [checklist.md](checklist.md) | 上架前检查清单：版本号、图标、授权、出口合规、App Store Connect 每一项填什么 |

检查文案长度：

```bash
python3 tools/appstore/check_metadata.py
```

## 字段上限（App Store Connect Help，2026-11-13 查）

| 字段 | 上限 |
|---|---|
| App 名称 | 2–30 字符（每个语言里全局唯一） |
| 副标题 | 30 字符 |
| 推广文本 | 170 字符（随时能改，不用重新审核） |
| 描述 | 4000 字符，纯文本 |
| 关键词 | **100 字节**，逗号分隔、不加空格；不重复名称和公司名 |
| 此版本新增内容 | 4000 字符（首个版本之后才必填） |

出处：<https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/>、
<https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/>。
Apple 的营销页（<https://developer.apple.com/app-store/search/>）写关键词是 "100 characters"，和帮助页的 "100 bytes" 不一致，按更严的字节数准备。

## 十种语言对应的 App Store Connect 本地化

| 游戏里的语言 | ASC 选项 | 文件 |
|---|---|---|
| 英文 | English (U.S.)（主语言） | `en-US.md` |
| 简体中文 | Chinese (Simplified) | `zh-Hans.md` |
| 繁体中文 | Chinese (Traditional) | `zh-Hant.md` |
| 日文 | Japanese | `ja.md` |
| 韩文 | Korean | `ko.md` |
| 西班牙文 | Spanish (Spain)，同一份建议也填 Spanish (Mexico) | `es-ES.md` |
| 法文 | French (France)，可同时填 French (Canada) | `fr-FR.md` |
| 德文 | German | `de-DE.md` |
| 意大利文 | Italian | `it.md` |
| 巴西葡萄牙文 | Portuguese (Brazil) | `pt-BR.md` |

出处：<https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/>

## 文案里的用词

和游戏界面一致，以 `tools/l10n/strings.py` 为准：关名（Atoll / Grassland / Alpine / Snow Peaks / Island / Volcano / Sky City 及各语言）、
降落伞 = canopy / キャノピー / vela / voile / Schirm / velame，操纵环 = toggles / トグル / mandos / commandes / Steuerschlaufen / comandi / batoques，
「拉环转向」「晕动症」的说法也照游戏里的警告。繁体按台湾用语。HUD 读数标签各语言都是英文。
