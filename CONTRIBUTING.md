# Contributing to Freefall

Thanks for wanting to add to Freefall — new worlds especially. Start with
[docs/adding-a-scene.md](docs/adding-a-scene.md), which walks through every file a new world touches.

Issues (bugs, ideas, playtest notes) are always welcome. Pull requests are welcome too, **under the
terms below** — please read them before you open one.

## Contribution terms

Freefall's source is published under the [PolyForm Noncommercial License 1.0.0](LICENSE): anyone may use
it for noncommercial purposes. The author also ships Freefall commercially (for example a paid version on
other platforms), and needs to be able to include accepted contributions there. So, by submitting a
contribution (code, shaders, assets, text, translations — anything in a pull request) you agree that:

1. **You keep the copyright** in your contribution.
2. **License to the author.** You grant Feiyu Chang (the "author") a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable license to use, reproduce, modify, prepare
   derivative works of, publicly display, publicly perform, sublicense and distribute your contribution
   and such derivative works, **for any purpose, including commercial purposes**, and to license them
   to others under any terms, including the terms of this repository's LICENSE.
3. **Patents.** You grant the author a perpetual, worldwide, non-exclusive, no-charge, royalty-free,
   irrevocable license under any patent claims you can license that are necessarily infringed by your
   contribution, to make, use, sell, offer for sale, import and otherwise transfer it.
4. **Everyone else** receives your contribution under this repository's LICENSE (PolyForm
   Noncommercial 1.0.0), like the rest of the code.
5. **You have the right to submit it.** The contribution is your own original work, or you have the
   right to submit it under these terms — including permission from your employer if it has rights in
   what you create. You will say so in the pull request if any part of it is not your own work.
6. **No obligation.** The author doesn't have to accept, use or credit any contribution, though
   accepted contributors are credited in the README.

You confirm this by ticking the box in the pull request template. If you can't agree to these terms,
please open an issue describing your idea instead of a pull request.

> These terms are written in plain language for a small project and are not legal advice. If you
> contribute on behalf of a company, check with it first.

## Third-party assets

Freefall generates almost everything procedurally. If your contribution includes anything you didn't
make yourself (sounds, textures, models, fonts, code):

- Only **CC0, CC BY, MIT, BSD, Apache-2.0** or similar permissive licenses. **No NonCommercial (NC),
  NoDerivatives (ND), ShareAlike / GPL-family, or "personal use only" assets** — they can't go into the
  commercial version.
- Add it to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with the author, a link, the license and
  what you changed; add sounds to `Freefall/Resources/Audio/CREDITS.txt` too.
- Say in the pull request if any image, model or sound was made with a generative AI model, and which
  model (its license has to allow commercial use).

## Before you open a pull request

- `xcodegen generate`, then build the `Freefall` scheme for visionOS (Release) with no new warnings.
- If you touched terrain: run the CPU/GPU terrain comparison and the autopilot jumps described in
  [docs/adding-a-scene.md](docs/adding-a-scene.md#verify).
- New player-facing text goes into `tools/l10n/strings.py` in all ten languages (machine translation is
  fine as a first pass — say so in the PR), then `python3 tools/l10n/make.py`.
- Keep pull requests to one world or one change.

---

## 中文说明

欢迎给 Freefall 加东西，尤其是新的场景。先看 [docs/adding-a-scene.md](docs/adding-a-scene.md)，里面列了加一关要改的每个文件。

Issue（bug、想法、试玩反馈）随时欢迎；Pull Request 也欢迎，但**要接受下面的贡献条款**：

源码按 PolyForm Noncommercial 1.0.0 发布，任何人都可以非商业使用。作者自己还会把 Freefall 做成商业版本（比如其他平台上的付费版），需要能把合进来的贡献放进去。所以提交贡献（PR 里的任何东西：代码、着色器、素材、文字、翻译）即表示你同意：

1. **版权仍归你**。
2. **授权给作者**：你授予 Feiyu Chang 一项永久、全球、非独占、免费、不可撤销的许可，可以为**任何目的（包括商业目的）**使用、复制、修改、发布、再许可你的贡献及其衍生作品，并可以按任何条款（包括本仓库的 LICENSE）授权给他人。
3. **专利**：对你的贡献必然涉及的、你有权许可的专利，同样授予作者上述许可。
4. **其他人**按本仓库的 LICENSE（PolyForm Noncommercial 1.0.0）获得你的贡献。
5. **你有权提交**：贡献是你自己的原创，或者你有权按这些条款提交（如果雇主对你的创作有权利，要先得到雇主同意）；不是你自己做的部分要在 PR 里说明。
6. **没有义务**：作者不必接受、使用你的贡献；被合并的贡献者会在 README 里致谢。

在 PR 模板里勾选那一项即表示同意。不能接受这些条款的话，请改开 Issue 描述你的想法。

第三方素材只收 CC0、CC BY、MIT、BSD、Apache-2.0 这类宽松许可；**不收非商用（NC）、禁止演绎（ND）、相同方式共享 / GPL 系、仅限个人使用的素材**。要写进 THIRD_PARTY_NOTICES.md；AI 生成的图片、模型、声音要在 PR 里说明用的是哪个模型（模型许可要允许商用）。

（这些条款是给小项目写的白话版，不构成法律意见。）
