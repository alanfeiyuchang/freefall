# Freefall — support site（草稿）

App Store Connect 要的 Support URL 和 Privacy Policy URL。照 Wandless 的 `wandless-support` 做：
静态 HTML、一个样式表、不用构建，放进一个单独的仓库用 GitHub Pages 发布。

- `index.html`：支持页（舒适提示、常见问题、报 bug、致谢——音效 CC BY 4.0 署名和手套模型的来源都在这里），中英两种语言
- `privacy.html`：隐私政策，中英两种语言（内容和 `../privacy.md` 的草稿一致）
- `style.css`：深海蓝 + 伞衣橙
- `img/icon.jpg`：App 图标三层叠起来缩到 256 px

## 发布前要换掉的占位

| 占位 | 换成 |
|---|---|
| `SUPPORT_EMAIL` | 你的支持邮箱（出现在两个页面的 mailto 链接和按钮上） |
| `DEVELOPER_NAME` | 署名（致谢一句和页脚的 ©） |
| `LAST_UPDATED` | 隐私政策的日期，英文写 `13 November 2026` 这种，中文写 `2026 年 11 月 13 日` |

```bash
grep -rn "SUPPORT_EMAIL\|DEVELOPER_NAME\|LAST_UPDATED" docs/appstore/support-site   # 换完应该搜不到
```

## 发布（要你点头再做）

1. 新建公开仓库（比如 `freefall-support`），把这个目录里的文件拷到仓库根目录。
2. Settings → Pages → 从 `main` 分支的根目录发布。
3. 得到的两个网址填进 App Store Connect：
   - Support URL：`https://<用户名>.github.io/freefall-support/`
   - Privacy Policy URL：`https://<用户名>.github.io/freefall-support/privacy.html`
4. 游戏开始窗口里的「隐私政策 · 支持 · 致谢」链接（还没加，见 `../checklist.md`）用同样两个网址。

## 和游戏对得上的地方

页面里写的玩法和设置名按合并皮肤那批改动以后的版本：皮肤解锁、游戏内选语言、「伞下转向」。
如果那批改动最后有变化，FAQ 里「降落伞和手套怎么解锁」「怎么换语言」两条要跟着改。
