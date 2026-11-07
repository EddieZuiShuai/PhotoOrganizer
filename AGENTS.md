# AGENTS.md

给"下一个接手这个项目的 AI"看的入口。读完这一份就能开工；其余细节在 `docs/`，按下面的路由表去取，不要一次性全读。

## 一句话

「相册整理」是一个只跑在 iPhone 本地的相册清理工具：扫相册 → 算特征 → 给出重复 / 相似 / 模糊 / 大文件 / 内容分类清单 → 用户自己决定删哪几张。**照片永远不出手机。**

## 30 秒速览

| 项 | 值 |
|---|---|
| 平台 | iOS 16.0+，仅 iPhone，仅竖屏，固定浅色 |
| 技术栈 | SwiftUI + Photos + Vision，少量 UIKit；**无第三方依赖、无 SPM** |
| 规模 | 11 个 Swift 文件约 8.1k 行；最大是 `Views/ContentView.swift`（约 3.1k 行） |
| Bundle ID | `com.eddie.photoorganizer` |
| 版本号唯一来源 | `PhotoOrganizer/Info.plist` → `CFBundleShortVersionString` / `CFBundleVersion`（当前 **1.5 / 27**）。`project.pbxproj` 里的 `MARKETING_VERSION = 1.0` 是无效残留，改它不生效。首页底部会显示这两个号，方便用户自查 |
| 怎么编译 | **没有 Mac。** push 到 `main` → GitHub Actions `build.yml` → 下载 ipa → Windows 上用 Sideloadly 签名安装 |
| 怎么测 | Maestro 云端 UI 用例 11 条（`maestro/flows/`），手动触发 `ui-test.yml`，本机用 `_ci_check.py` 取回结论 |

## 铁律（违反即回退，不接受"顺手优化"）

1. **照片不出手机。** 不引入任何网络请求、上传、埋点、第三方分析 SDK。所有判断只在 `AnalysisEngine` / `ContentAnalyzer` 里做。
   唯一的"联网"是 `PHImageRequestOptions.isNetworkAccessAllowed = true`——让 **iOS 系统相册**从 iCloud 把源文件取回本地。这不是我们发的请求，照片仍然只落在本机、去向不是我们的服务器。**一旦自己写 `URLSession`，这个 App 的立身之本就没了。**
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
| 改分类枚举 / 加内容类别 | `docs/component-api.md` 的枚举表、`docs/architecture.md` 的判定口径 | `docs/DESIGN.md` |
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
- **隐私有照片和视频两个类** → `ContentCategory` 现在是 `.privacy` + `.privacyVideo`。所有特判必须走 `category.isPrivacy`，写 `== .privacy` 会漏掉视频那一半（1.5 收口了 5 处）
- **`PHAsset` 不是 `AVAsset`** → `AVAssetImageGenerator(asset:)` 不收 `PHAsset`，要先 `PHImageManager.requestAVAsset` 拿（异步）。抽帧方法内部用信号量同步等，**绝不能在主线程调**
- **扫二维码别扫两遍** → `ContentAnalyzer.scanQR` 一次扫码同时返回「发票信息」+「任意 payload」（`QRScan`），旧的 `invoiceQR` 已删。要加新的二维码用途就在 `QRScan` 里扩字段，别再写第二个 `VNDetectBarcodes`
- **逐张过批量删除的下标回退** → 待删只能来自已经滑过去的张，所以 `deleteMany` 直接 `index -= removed`，不用逐张算下标；同时清空 `history`（撤销链已乱）
- **改隐私公式要作废旧结论** → 缓存里 `contentDone = true` 的条目会整段跳过内容识别。只改算法不作废缓存 = 用户永远看不到修复。作废走 `privacyModelVersion` + `ScanCache.resetPrivacyJudgements()`，**不要动 `ScanCache.version`**（那会作废整库，用户要重扫十几分钟）
- **`git push` 报 schannel / TLS 错** → 环境里有 `http_proxy=127.0.0.1:5804`，git 走它必然握手失败。可靠写法是**行内清空四个变量**：`http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= git push`（`env -u` 在本机 Bash 里会静默失败，别用）
- **取缩略图别用 `.fastFormat`** → 在 iOS 18 模拟器上它会返回 `PHPhotosError 3303`（`image=nil`），导致整轮扫描缩略图全 nil、结果页每类都是 0、连「逐张过」入口都不显示（Maestro 9 条 flow 全卡在 `逐张过不可见`）。取图一律 `.opportunistic`（优先快、拿不到回退高质量）；`po-diag.txt` 里三种 deliveryMode 的对比能一眼看出这坑
- **加新分类要按「软/硬结论」想清楚** → 强结论（发票/单人照/合照/美食/风景/宠物/隐私/视频）永不被新信号推翻，缓存命中直接用；弱结论（截图/文档/其他/**二维码**）只是兜底，加新信号必须重判。要重判就把 `ScanCache.currentSignalVersion` +1，**别动 `ScanCache.version`**（那是整库作废）。别给单个分类写「补扫函数」——下次加分类又得写一遍
- **二维码是弱结论，不是强结论** → 它的判据只有「扫到码」一条，而优先级是「发票 > 二维码 > 截图 > 文档」，能被更强证据推翻。错把它当强结论的代价：一张印刷发票被通用码抢判成二维码之后，`contentDone` 已经是 true，**修好优先级也永远轮不到它重判**，用户只能删缓存重扫。1.5(25) 把它移进弱结论 + 版本号 +1 才把老数据救回来
- **320px 上数不出合照** → 十人合影缩到 320px 后每张脸只剩十几像素，`VNDetectFaceRectangles` 一个都认不出来，整张会被判成「单人照」。所以内容识别收尾要跑一轮 `refineFacesPass`：只对人物类、用 **512px** 重数一次（1024px 解码时间翻倍，能多救回的只是极小的脸），结果写 `faceCountFine`（Optional）并立刻落缓存，下次一条都不重算
- **分类卡上的「0」必须能区分「真没有」和「还没算」** → 补扫时用 `RefineStatus.backfill` 把数字换成百分比，人脸复核时用 `RefineStatus.isFaceRefine` 显示「复核中」。两个池子的分母不一样，进度条会从 100% 掉回 0%，不分开标会被当成卡死。1.5(23) 用户就是被这个「0」骗去清缓存重扫的
- **`CachedPhoto` 加字段一律 Optional** → 合成 Codable 对非 Optional 字段缺失会抛错，`try?` 一吞整份缓存变空，**正好触发想避免的全量重扫**。`signalVersion` 声明成 `Int?`，nil 当 0 处理
- **分类卡上的「0」必须能区分「真没有」和「还没算」** → 补扫时用 `RefineStatus.backfill` 把数字换成百分比。1.5(23) 用户就是被这个「0」骗去清缓存重扫的
- **`PHLivePhotoView` 会吃掉翻页和缩放手势** → 它自带 `playbackGestureRecognizer`，直接叠在 TabView 里会让左右翻页和双指缩放全部失灵（这页就只剩「长按照片」一个手势）。必须同时做两件事：`isUserInteractionEnabled = false` **和** `playbackGestureRecognizer.isEnabled = false`。播放一律走 `startPlayback(with: .full)` 主动下指令，`didEndPlaybackWith` 里把 `isPlaying` 置回 false（`.full` 播完本来就停，不会循环）
- **给 UIViewRepresentable 下「播一次」的指令不要直接存 view 引用** → SwiftUI 每次重建都换实例，存下来的引用翻页后指向一个已经不在屏幕上的 view。用 `playToken` / `stopToken` 两个计数器，`updateUIView` 里比对后执行；**先处理 stop 再处理 play**，否则「上一页 stop + 这一页 play」落在同一帧会变成刚播就停
- **逐张过的进度别存下标** → 列表会缩（删照片）、会有新照片按时间插到最前、会换筛选，存 `index` 下次就落到一张完全不相干的照片上。存**判过的 id 集合**，进场取「第一个不在集合里的位置」。`TriageProgressStore` 同时存 `marked`：只存 judged 的话，一张标了待删的照片重启后会变成「判过了但标记没了」——既不会重看也不会被删。撤销要 `forget` 掉 judged，否则这张永远回不来
- **隐私组的逐张过要自己糊** → 网格里的缩略图有 `blurPrivacyThumbnails` 打码，但 `TriageMedia` 是另一套渲染，不显式传 `blurred` 就等于绕过了那个设置。1.5(26) 传了，中央给一个「已打码 · 点一下看原图」的按钮（用 Button 不用 tap 手势，卡片挂着拖拽手势会把 tap 吞掉）
- **`maestro test <目录>` 不按文件名顺序跑** → 实测 11 条的完成顺序是 04/08/06/09/01/07/00/10/05/02/03。任何"我这条叫 00，肯定第一个跑"的假设都会翻车：首启用例断言弹窗可见时，弹窗早被别的 flow 里 `scan.yaml` 的 optional 点击关掉、`cloudNoticeSeenVersion` 都写上了。依赖初始状态的用例要么用启动参数强制（`-ForceCloudNotice`，只在 DEBUG 生效），要么拆到独立目录单独跑一次
- **iOS 没有「网络权限」可以申请** → 不要去找什么 `NSNetworkUsageDescription`（不存在），也别指望提前触发系统那个「允许使用无线局域网与蜂窝网络」——它是 App 首次**真正联网**时由系统弹的，不能预触发、不能改文案、不能拦。要让用户知道"为什么联网"，只能自己做一层说明（`CloudNoticeCard` + 键 `cloudNoticeSeenVersion`）
- **`PHImageResultIsInCloudKey == true` 是「没有返回图」，不是「图比较糊」** → 官方语义是 *no image was provided, because the asset data must be downloaded from iCloud*。所以在 `isNetworkAccessAllowed = false` 下取 iCloud 专属照片，`image` 是 nil；`thumbnail()` 现在直接 `return`，那张就停在默认分类「其他」里——数字上看不出来，实际根本没识别。修法见 `TODO.md` 的 1.5(27) B，**别图省事直接打开 `isNetworkAccessAllowed`**：两万张会把首扫拖成几小时，还烧用户流量

## 当前版本

`1.5 (27)`：把「为什么要联网」和「iCloud 优化存储」一次说清——
1. **首启联网说明**：`CloudNoticeCard`（在 `TutorialView.swift` 里，不新增文件）。三句话——下载不是上传 / 整理不用先下载 / 识别全在本机；底部写明断网也能用。遮罩吞点击不关闭，必须点「我知道了」。
2. **常驻入口**：我的 › 关于 › 网络与 iCloud，复用同一张卡。设置页在 tab 里，所以这里用 sheet，不能用 overlay。
3. **事实**：iOS 没有「网络权限」可申请。不要按"申请权限"的思路写代码，这里做的是"提前解释"。
4. **没改的**：iCloud 云端专属照片仍然会漏识别（见 `TODO.md` 1.5(27) B）。弹窗文案已经刻意没写「完全不联网」，别把它改成绝对句。

`1.5 (22)`：在 21 基础上再迭代一轮——
1. **逐张过按钮重排** `撤销 / 待删 / 保留 / 删除`：「标记」改名「待删」（`flag` 图标），删除从「立即删当前张」改成**批量删所有已标记**（动态「删除 N 张」、没标置灰、二次确认）。
2. **通用二维码分类** `ContentCategory.qrCode`「二维码」：`scanQR` 一次扫码同时给出发票信息 + 任意 payload，非发票二维码只在截图/文档/其他弱分类上生效（优先级 发票 > 二维码 > 截图 > 文档）。
3. **首页首启提示卡**：`tutorialSeenVersion` 驱动，放「开始扫描」下方，看完自动消失（补上了 21 一直缺的「新用户看不到教程入口」）。
4. **我的 → 帮助与支持**：补「邮件反馈」（`eddie.wu@qq.com`）+「常见问题」5 条。
5. **清理页瘦身**：删顶部「空间」按钮（和底部 tab 重复）、发票数字换成「相似组」、「正在识别发票与分类」→「正在识别分类」、导出清单按钮及 `exportText` 移除、筛选按钮放大。

`1.5 (26)`：三项浏览体验，一套交互模型——
1. **Live 照片真的会动**：`PHLivePhotoView`（`LivePhotoSurface`）+ `requestLivePhoto`。进场自动播一次、**默认静音**、播完停在定格不循环、点 `LIVE` 胶囊从头重播一次。两个手势隔离必须做：`isUserInteractionEnabled = false` **和** `playbackGestureRecognizer.isEnabled = false`，否则它会把 TabView 翻页和双指缩放全吃掉。只给当前页装载，翻走就释放（视频轨 2~5MB）。
2. **静音状态跨素材共用**：视频和 Live 各有一个 model，静音用两个 `onChange` 互为镜像，值相同不写，所以不震荡。在视频里开过声音，翻到 Live 也有声。
3. **Live 标志**：缩略图左下角（`PhotoThumbView`，全 App 只有这一个缩略图组件，改一处全生效）、预览底部信息行、逐张过卡片类型标签。
4. **逐张过进度记忆**：`TriageProgressStore` 存**判过的 id 集合**，不存下标——列表会缩、会有新照片插到最前、会换筛选，存下标会落到别人身上。`marked` 必须一起存，否则「判过但标记丢了」的照片既不会重看也不会被删。攒 2 秒落盘 + 退出 `flush()`。
5. **分类页逐张过**：`TriageEntryBar` 抽成共用组件，清理页和分类详情页同一份实现。分类页传 `alive`（视频分类带当前体积筛选）。
6. **隐私组的逐张过先糊住**：`TriageMedia.blurred`，中央一个「已打码 · 点一下看原图」按钮。逐张过里没有缩略图那层遮挡，不自己糊就等于绕过「隐私打码」这个设置。

`1.5 (25)`：四个用户提的问题，一个数字对账——
1. **「人物」拆成「单人照 / 合照」**：系统没有「这是谁」的接口（Vision 只有检测框，`VNGenerateFaceFeaturePrintRequest` 不存在），按人聚类做不了；人脸数量是唯一便宜且准确的替代。拆分后两类仍然互斥（一张照片的人脸数要么 1、要么 ≥2）。
2. **人脸精细复核** `refineFacesPass`：`completion` 回调之后再跑（不挡分类页），只对人物类重取 512px 再数一次脸，把远景合影从单人照里挑出来；结果走 `onFaceRefined` 第二次回调刷新界面，并写 `faceCountFine` 落缓存。老缓存的「人物」由 `fromCache` + `apply(to:)` 用现成的 `faceCount` 就地拆开，不用重扫。
3. **修发票优先级**：以前 320px 上扫到任意二维码就改判并 `return`，1024px 大图的 OCR 永远轮不到——带收款码的印刷发票恒被归成「二维码」。现在只记 `sawGenericQR`，等 OCR、大图路径全跑完、分类**仍是弱分类**时才落地。截图另给 300 次专用 OCR 池，不跟文档类抢 3000 次主预算。
4. **排序统一到时间轴**：建议清理默认「由近到远」（顶部可切「建议分」）、重复/相似组间从「成员数」改成「组内最新一张的时间」，组内本来就是时间降序。大文件、分类 › 视频仍然是体积降序（这是功能，不是顺序问题）。
5. **分类页对账行**：显示「合计 N 项，和相册里的 M 项完全对上」。互斥性以前只能靠用户按计算器，对不上还会以为漏了照片——实际最常见的差额是隐私两张卡被设置开关藏着（默认就是关的）。

`1.5 (24)`：把「新分类永远没数据」这件事从根上解决——
1. **结论分软硬 + 增量补扫**：`CachedPhoto.signalVersion`（Optional）+ `ScanCache.currentSignalVersion`。新增信号只重判弱结论（截图/文档/其他，约一万条，8~15 分钟），强结论两万条照常命中。以后加分类只要把版本号 +1。
2. **补扫进度可见**：分类卡在补扫期间显示「62%」而不是「0」；`RefineBanner` 补扫时文案换成「新版本多了识别信号，只重判截图/文档/其他」。
3. **`ContentCategory.video`**：视频不再被分类 tab 丢掉（以前只判隐私就 `continue`）。详情页按体积倒序 + 分段筛选（全部 / ≥100MB / <100MB）；**不拆「大视频/小视频」两张卡**，否则互斥性就破了。
4. **隐私「隐藏」**：`PHAssetChangeRequest.isHidden` → 系统「已隐藏」相簿（iOS 16 起要 Face ID）。入口在隐私详情页底部 + 清理页隐私页签；找回走「我的 › 已隐藏的照片」。`hiddenIDs` 和 `deletedIDs` 分开记——隐藏不释放空间。
5. **视频预览默认静音**：和逐张过对齐；静音时不再无谓激活音频会话（以前会掐掉正在听的音乐）。

`1.5 (23)`：修缩略图取图 `.fastFormat` → `.opportunistic`（iOS 18 模拟器返回 3303 导致扫描全 0，UI 回归 9 条全挂）；UI 回归 9/9 通过后升号出包。

`1.5 (21)`：隐私视频、隐私拆两张卡、隐私 v3、分类就地 NavigationStack 下钻、逐张过挪到列表上方、新手教程 5 页；隐私开关默认「不显示 + 模糊显示」；修点喇叭顺带暂停的 bug。
