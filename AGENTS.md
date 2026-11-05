# AGENTS.md

给"下一个接手这个项目的 AI"看的入口。读完这一份就能开工；其余细节在 `docs/`，按下面的路由表去取，不要一次性全读。

## 一句话

「相册整理」是一个只跑在 iPhone 本地的相册清理工具：扫相册 → 算特征 → 给出重复 / 相似 / 模糊 / 大文件 / 内容分类清单 → 用户自己决定删哪几张。**照片永远不出手机。**

## 30 秒速览

| 项 | 值 |
|---|---|
| 平台 | iOS 16.0+，仅 iPhone，仅竖屏，固定浅色 |
| 技术栈 | SwiftUI + Photos + Vision，少量 UIKit；**无第三方依赖、无 SPM** |
| 规模 | 10 个 Swift 文件约 6.4k 行；最大是 `Views/ContentView.swift`（约 2.3k 行） |
| Bundle ID | `com.eddie.photoorganizer` |
| 版本号唯一来源 | `PhotoOrganizer/Info.plist` → `CFBundleShortVersionString` / `CFBundleVersion`（当前 **1.4 / 20**）。`project.pbxproj` 里的 `MARKETING_VERSION = 1.0` 是无效残留，改它不生效。首页底部会显示这两个号，方便用户自查 |
| 怎么编译 | **没有 Mac。** push 到 `main` → GitHub Actions `build.yml` → 下载 ipa → Windows 上用 Sideloadly 签名安装 |
| 怎么测 | Maestro 云端 UI 用例 8 条（`maestro/flows/`），手动触发 `ui-test.yml`，本机用 `_ci_check.py` 取回结论 |

## 铁律（违反即回退，不接受"顺手优化"）

1. **照片不出手机。** 不引入任何网络请求、上传、埋点、第三方分析 SDK。所有判断只在 `AnalysisEngine` / `ContentAnalyzer` 里做。
2. **不改判定口径。** 重复 / 相似 / 模糊 / 建议分的阈值是长时间踩坑调出来的，见 `docs/architecture.md` 的「判定口径」表。要改先改文档、说明旧口径错在哪，再改代码。注意 `AnalysisEngine.blurThreshold` 是**死代码**（无引用），真正的绝对阈值硬编码在 `buildScores` 里（180 / 290）。
3. **不给 `photos-add` 授权。** CI 里 `simctl privacy grant photos-add` 会把权限记成"仅添加"，iOS 启动就弹「请求额外访问」框挡住整个界面（已踩过，见提交 `fbe8e75`）。
4. **扫描期间屏幕常亮不能删。** `ScreenAwake` 跟 `phase` / `isRefining` 联动；去掉后一锁屏系统就掐断解码与 Vision 请求，用户只能从头再扫。
5. **一次选中 / 删除超过 500 张必须二次确认。** `bulkConfirmThreshold = 500`，别调高也别绕过。
6. **新增 Swift 文件必须同时改 `project.pbxproj`。** 工程是老式文件引用（objectVersion 56），不是同步文件夹：要加 `PBXBuildFile` + `PBXFileReference` + 分组 children + Sources 阶段四处，否则 CI 编译报"找不到符号"。
7. **删照片只走 `PHAssetChangeRequest.deleteAssets`。** 不自己删文件、不动 iCloud、不给"永久删除"。
8. **改完必须更新 `docs/TODO.md`**，并在 `docs/` 里同步受影响的那一份（见下方同步义务）。

## 文档路由（别全读，按任务取）

| 你要做的事 | 必读 | 选读 |
|---|---|---|
| 第一次进项目 | 本文件、`docs/project-overview.md` | `docs/user-guide.md` |
| 改界面 / 加页面 | `docs/DESIGN.md`、`docs/component-api.md` | `docs/architecture.md` |
| 改扫描、判定、性能、内存 | `docs/architecture.md` | `docs/component-api.md` |
| 改构建、跑测试、发版 | `docs/development.md` | — |
| 接需求、排优先级、判断"做不做" | `docs/TODO.md`、`docs/user-guide.md` | `docs/project-overview.md` |
| 做新手引导 / 教程 / 首启引导 | `docs/onboarding-spec.md` | `docs/DESIGN.md`、`docs/user-guide.md` |
| 回答"这功能怎么用 / 这个数字什么意思" | `docs/user-guide.md` | `docs/project-overview.md` |

## 事实归属（一条事实只写一处，别处只能链过去）

| 事实 | 唯一出处 |
|---|---|
| 项目是什么、不做什么、版本怎么演进 | `docs/project-overview.md` |
| 命令、CI、发版、回归清单、故障对照 | `docs/development.md` |
| 数据流、判定阈值、线程与内存策略 | `docs/architecture.md` |
| 公共类型 / 函数签名 / 调用边界 / 不变量 | `docs/component-api.md` |
| 颜色、字号、圆角、交互纪律、文案语气 | `docs/DESIGN.md` |
| 新手教程讲什么、怎么翻页、状态键叫什么 | `docs/onboarding-spec.md` |
| 用户怎么用、数字怎么读、误判怎么办 | `docs/user-guide.md` |
| 现在做什么、做到哪、下一步做什么 | `docs/TODO.md` |
| 入口、铁律、路由 | 本文件 |

## 改完代码的同步义务

| 你改了什么 | 必须同步 |
|---|---|
| 阈值 / 算法 / 扫描阶段 | `docs/architecture.md` + `docs/TODO.md` |
| 公共类型或函数签名 | `docs/component-api.md` |
| 颜色 / 字号 / 交互行为 | `docs/DESIGN.md` |
| 工作流 / 脚本 / 命令 / 版本号 | `docs/development.md` |
| 用户看得见的行为 | `docs/user-guide.md` + `README.md` |
| **用户可见的按钮/标签文案** | **同一次提交内改 `maestro/flows/`**；新按钮一律给 `accessibilityIdentifier`，用例按 id 点，不按文字点 |
| 版本号 | `PhotoOrganizer/Info.plist`（两处）+ `docs/development.md` 的版本表 |

## 高频踩坑（细节在 `docs/development.md`）

- 模拟器没给相册权限 → 结果页全是 0（顺序：先 `addmedia`，启动过一次，再 `grant photos`）
- 两万张库扫到一半闪退 → jetsam（必须逐张 `autoreleasepool` + 220 MB 内存探针）
- 发票恒为 0 → 320px 缩略图上字只有 3~6 像素高，要 1024px 补读
- 首次点开照片是空白 → sheet 必须用 item 驱动，不能用 `isPresented` + 并列状态
- 结果页卡顿 → 高频进度不要放 `@State`，用 `RefineStatus` 单独订阅
- **改按钮文案导致 UI 用例整批失败** → Maestro 的 `tapOn: "文字"` 是全字匹配；「取消」改成「取消选中 N 张」后 4 条 flow 全挂。新按钮给 `accessibilityIdentifier`，用例写 `tapOn: { id: ... }`
- **增量扫描很"快"但后台烧 CPU** → `flush()` 无条件全量编码（5.5 MB × 28 次）；只编码 dirty、增量日志追加，全命中时一次都不写
- **底部 tab 不能用系统 `TabView`** → 切走就销毁页面，`selectedIDs`/滚动位置/筛选全丢。用四页常驻 + `opacity`；`bottomArea` 必须是 `safeAreaInset` 不是 `overlay`，否则压在 tab bar 上
- **隐私判定先排除人脸再算密度** → 旧公式「肤色 × 人体」在自拍上必然过线；且肤色统计要先用 `uprightCGImage` 把 EXIF 方向烤进像素，否则竖拍照片的「排除人脸」会排到画面边上

## 当前版本

`1.4 (20)`：底部四 tab（清理/分类/空间/我的）、左右滑完整显示 + 内置视频播放 + 标记与删除拆开、隐私判定 v2（排除人脸 + 裸露密度）、宠物专用模型。19 修了缓存落盘的 CPU 写放大，并临时关掉隐私缩略图打码以便校准误报（20 仍关闭）。

**下个版本 `1.5 (21)` 已排定**：主题是「第一次用的人不困惑」，第一项是新手教程（`docs/onboarding-spec.md` 已写完，代码未动）。做之前先读那份 spec，别自己重新设计一遍呈现方式——里面每一条"不做"都有踩过的理由。
