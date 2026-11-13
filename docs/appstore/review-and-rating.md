# 年龄分级、类别、运动信息、审核备注

## 类别

- **主类别：Games（游戏）**，子类别最多选两个：建议 **Simulation（模拟）+ Sports（体育）**。
  这两个都在 Apple 官方的游戏子类别示例里（<https://developer.apple.com/app-store/categories/>）；
  官方没给完整清单，Casual 之类能不能选要在 App Store Connect 的下拉框里看。
- 次类别（Secondary Category，可选）：不填，或者填 Sports。别选和内容不符的类别（违反审核指南 2.3）。

## 年龄分级

档位现在是 4+ / 9+ / 13+ / 16+ / 18+（另有澳大利亚、巴西、韩国、越南的地区分级）。
出处：<https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/>

问卷建议这样答（按 release 分支 + 皮肤那批改动的内容）：

| 组 | 条目 | 建议 | 理由 |
|---|---|---|---|
| 应用内控件 | 家长控制、年龄确认 | 无 / 否 | 没有 |
| 功能 | 不受限网页访问、用户生成内容、社交媒体、消息聊天、广告 | 全部否 | 不联网，没有这些 |
| 成熟主题 | 粗口、烟酒毒品 | 无 | 没有 |
| 成熟主题 | 恐怖 / 惊悚（Horror/Fear Themes） | **无**（保守可选「偶尔 / 轻微」→ 9+） | 有坠落和高空画面，失败时只有一行「摔了」「掉进熔岩」之类的文字结果，没有受伤、血、死亡画面。我倾向于「无」；如果你觉得一万八千英尺的自由落体对小孩算「引发恐惧」，选「偶尔」，分级变 9+ |
| 医疗或健康 | 医疗 / 治疗信息、健康话题 | 无 | 没有 |
| 性与裸露 | 全部 | 无 | 没有 |
| 暴力 | 卡通 / 幻想暴力、写实暴力、枪械 | 无 | 没有任何暴力 |
| 机会类 | 赌博、模拟赌博、竞赛、开箱 | 无 / 否 | 皮肤是按落点固定解锁，不随机，不花钱，不是开箱 |
| 2026-11-16 新增 | Shared Location（共享位置）、Dating and Relationships（交友 / 恋爱） | 否 | 没有 |

→ 预计 **4+**（恐怖选「偶尔」则 9+）。
时间点：2026 年 9 月起提交新 app / 更新必须填问卷；2026-11-16 新增的两项**所有 app 要在 2027-01-12 前答完**
（<https://developer.apple.com/news/?id=yxkh08us>，2026-11-02）。问卷选项的确切写法我没能在页面上核实，以 ASC 里实际看到的为准。

## App Motion Information（visionOS 必填）

App Store Connect 的 visionOS 版本页有 **App Motion Information**（"Contains High Motion"），不填不能提交审核。
满足任一条就要选「是」：镜头前后快速移动；横滚 / 俯仰超过 10° 且间隔不到 5 分钟；边前进边平滑偏航；**意外运动（含坠落）**且间隔不到 5 分钟。
只算不是由用户头和身体带动的镜头运动。
出处：<https://developer.apple.com/help/app-store-connect/reference/provide-app-motion-information/>、
<https://developer.apple.com/help/app-store-connect/manage-app-information/set-the-app-motion-information-for-apple-vision-pro/>

**建议选「Yes, this app contains high motion」**：自由落体时你以每秒几十米的速度往下掉、伞下一直在往前飞，打开「拉环转向」后世界还会绕着你转。
产品页会因此显示 high-motion 标签——这对玩家是诚实的提示，也能避免审核时因为没标而被退回。

我们已经做了的、和 HIG（Motion、Immersive experiences）建议对得上的地方，可以写进审核备注：
默认不旋转世界（转向靠玩家自己转头转身）；拉环转向默认关、打开前有晕动警告；转弯时视野四周压暗；头盔 HUD 是跟着头走的静止参照物；
建议坐着玩，不需要走动。

## 审核备注（App Review Information → Notes）

审核员用英文看，下面这段可以直接粘贴（≤ 4000 字符）。Sign-in required 不勾（没有账号）。联系人信息由你在 ASC 里填。

```
Freefall is a first-person skydiving game. It is fully offline: no account, no network access, no in-app purchases, no ads.

HOW TO PLAY (about 4 minutes per jump)
1. In the start window, swipe the cards to pick a world (Atoll is the easiest) and tap Jump. Allow hand tracking when asked.
2. You start in your own room (mixed immersion). Reach out with one hand and grab the glowing yellow bar to your right (make a fist or pinch). The plane grows around you; this takes about 5 seconds.
3. When the jump light above the door turns green, let go of the bar. You slide out of the plane and start falling.
4. The altimeter is on your wrist (left by default). When it alarms at 3,500 ft, use the watch hand to grab the red handle on your other forearm, near the wrist, and pull it outward about 13 cm (5 in). The canopy opens.
5. Under canopy, turn your head and body to steer; the canopy follows you. Grab the yellow toggles on either side of your head and pull both down to slow down. Fly to the red-and-white circle on the ground and land in it to win.
6. Tap the watch with your other hand's index finger to show or hide the helmet HUD (altitude, heading, landing spot). Hold the watch for 2 seconds to quit a jump at any time. Pressing the Digital Crown also exits.

WITHOUT HAND TRACKING
If hand tracking is not allowed, the game uses system pinch gestures instead: pinch and hold = hold the bar, release = jump, pinch after the alarm = open the canopy, pinch with the left/right hand and pull down = pull that toggle.

SPACE AND COMFORT
- Please play seated (a swivel chair is ideal). No walking is needed; the play area is within arm's reach.
- The app contains high motion (free fall, forward flight under canopy) and is marked as such.
- By default the world never rotates around the player: steering is done by physically turning the head and body. An optional "Canopy steering: + Toggles" setting lets the toggles turn the canopy; it rotates the world, so turning it on shows a motion-sickness warning that must be confirmed. The view's edges are darkened while turning.
- A stationary helmet HUD stays fixed to the head as a frame of reference.

OTHER NOTES
- Everything except the glove model (from Apple's "Animating hand models in visionOS" sample) is generated in real time: the plane, canopy, clouds, terrain and audio synthesis. Three CC BY 4.0 sound effects are credited in the description.
- "Start at 5,000 ft" (practice) unlocks for a world after one safe landing in it. Canopies and gloves unlock by landing on a world's target or bullseye; nothing is sold.
- The app requests hand tracking only. It does not use the camera, microphone, location or eye-tracking data.
```

（备注里描述的是合并皮肤那批改动以后的版本：练习、皮肤、「伞下转向」选项名以合并后为准。上架前对着真机过一遍，按实际文字改。）
