# 类型与调用契约

这份文档不列 UI 细节（去 `DESIGN.md`），只回答三件事：**有哪些公共类型、谁能调谁、调的时候要守什么规矩**。私有视图只在末尾列个清单，避免逐个 `@State` 写进来很快过期。

## 模型（`Models/PhotoItem.swift`）

### `PhotoItem`

一张照片/视频在分析流程中的载体。值类型，但持有 `PHAsset` 引用。

| 字段 | 类型 | 含义 / 不变量 |
|---|---|---|
| `id` | `String` | **等于 `asset.localIdentifier`**。全项目用它做键，禁止用数组下标 |
| `asset` | `PHAsset` | 真实资源，取图 / 删除都从这里走 |
| `creationDate` / `pixelWidth` / `pixelHeight` | | 来自 `PHAsset` |
| `isScreenshot` / `isVideo` | `Bool` | 来自 `mediaSubtypes` / `mediaType` |
| `isLivePhoto` | `Bool`（**计算属性**） | 现算 `asset.mediaSubtypes.contains(.photoLive)`。**故意不进缓存**：只是位掩码，取一次是常数开销；存进 `CachedPhoto` 反而要加字段、做可选解码、想清楚要不要升信号版本 |
| `dHash` | `UInt64?` | 64 位差分哈希。`nil` = 没算出来（视频、缩略图失败） |
| `sharpness` | `Double?` | 对比度拉伸后的拉普拉斯方差。`nil` = 没测 |
| `sharpnessScore` | `Double` | 0~100 展示分，**`-1` 表示未测**（不要当 0 用） |
| `contrastRange` | `Double` | 2%~98% 分位差，用于判断低细节 |
| `isLowDetail` | `Bool` | 近黑/近白/纯色，不参与模糊判定 |
| `fileSize` | `Int64` | 字节。`0` = 没取到，别拿它算"可释放空间" |
| `category` / `contentTags` / `ocrHits` / `faceCount` / `faceCountFine` | | 内容识别结果，阶段二才有。`faceCount` 来自 320px 小图；`faceCountFine`（Optional）来自 512px 复核，nil = 还没复核 |
| `brightness` / `edgeDensity` | `Double` | `brightness = -1` 表示未测 |
| `cleanupScore` / `cleanupReasons` / `isFavorite` | | 建议分 0~1 + 理由列表 |

计算属性：`displayName`（yyyy-MM-dd HH:mm）、`resolutionText`、`sizeText`、`scorePercent`。

### `PhotoGroup`

| 字段 | 说明 |
|---|---|
| `items: [PhotoItem]` | 组内成员。**第 0 个是默认保留张**（重复组）/ 最清晰的在 `buildScores` 里单独挑 |
| `isExactDuplicate: Bool` | 完全重复组 = true，相似组 = false |
| `id: String` | 取 `items.first?.id`，保证列表刷新不闪 |

### `AnalysisResult`

| 字段 | 说明 |
|---|---|
| `items` | 全量照片（含视频） |
| `duplicateGroups` / `similarGroups` | 分组结果 |
| `blurryItems` / `screenshotItems` | 扁平列表 |
| `videoCount` | 视频数 |
| `suggestedItems` | 按 `cleanupScore` 降序 |
| `categoryBuckets` | `[ContentCategory: [PhotoItem]]` |
| `blurReference` | 全库清晰度中位数，界面"灵敏度"按它的比例分档 |

计算属性：`photoCount`（排除视频）、`reclaimableCount`。

### 枚举

| 类型 | 取值 | 用途 |
|---|---|---|
| `ContentCategory` | 发票票据 / **二维码** / 文档 / 截图 / **单人照 / 合照** / 美食 / 风景 / 宠物 / **隐私照片 / 隐私视频** / **视频** / 其他 | 带 `icon`（SF Symbols）、`isPrivacy`（两个隐私类都算，**别再写 `== .privacy`**）、`isSoftCategory`（软结论：截图/文档/其他/**二维码**，新信号可以推翻）、`isVideo` 类目只按素材类型落桶。`fromCache(_:)` 认 1.4 的旧名「隐私」和 1.5(24) 的旧名「人物」（后者先落单人照，`apply(to:)` 再用 `faceCount` 拆开） |
| `ResultTab` | suggested / duplicate / similar / blurry / large / content(ContentCategory) | 结果页标签，带 `title` / `icon` |
| `LayoutMode` | list(1) / two(2) / three(3) | 列数，`rawValue` 直接当列数 |
| `AppPhase` | idle / scanning / done | 主容器状态 |
| `TimeWindow` | all / last7 / last30 / thisYear / lastYear / older | 空间看板筛选 |

## 服务（全部单例，禁止在 View 里 `init`）

### `PhotoLibraryService.shared` — 唯一碰 Photos 的地方

```swift
func currentStatus() -> PHAuthorizationStatus
func requestAuthorization() async -> PHAuthorizationStatus
func isLimited() -> Bool
func fetchAllAssets() -> [PHAsset]                    // 按创建时间倒序
func thumbnail(for asset: PHAsset, maxPixel: CGFloat = 256) -> UIImage?   // 同步，会阻塞
func listThumbnail(for asset: PHAsset) -> UIImage?    // 列表用，更小
func imageForOCR(for asset: PHAsset, maxPixel: CGFloat = 1024) -> UIImage?
func loadImage(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void)  // 异步，逐张过用
func originalData(of asset: PHAsset) -> Data?         // 取原图字节，判完全重复用
func sha256Hex(_ data: Data) -> String
func fileSize(of asset: PHAsset) -> Int64
func fetchUserAlbums() -> [(id: String, title: String, count: Int)]
func assetIDs(inAlbum id: String) -> Set<String>
func delete(assets: [PHAsset], completion: @escaping (Bool, Error?) -> Void)
```

**规矩**：`thumbnail` / `imageForOCR` / `originalData` 都是同步阻塞调用，只能在后台队列用。UI 层要图一律走 `loadImage`。

### `PhotoLibraryService.shared.privacyFrames`

```swift
func privacyFrames(for asset: PHAsset, maxPixel: CGFloat = 320) -> [UIImage]
```

抽 30% / 65% 两帧给隐私判定用。**同步等待，绝不能在主线程调**（内部 5 秒上限，拿不到就返回空）。
`PHAsset` 不是 `AVAsset`，先走 `PHImageManager.requestAVAsset`，再交给 `AVAssetImageGenerator`；
`appliesPreferredTrackTransform = true` 不能省，否则竖拍视频坐标差 90°。

### `AnalysisEngine.shared` — 扫描总调度

```swift
var similarDistance: Int = 8              // dHash 汉明距离
var exactCandidateDistance: Int = 3       // 判重复前的预筛

func analyze(assets: [PHAsset],
             progress: @escaping (Int, Int, String) -> Void,
             onQuickResult: ((AnalysisResult) -> Void)? = nil,
             refineProgress: ((Int, Int, String) -> Void)? = nil,
             completion: @escaping (AnalysisResult) -> Void)

func dHash(from image: UIImage) -> UInt64?
func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int
func sharpnessDetail(from image: UIImage) -> SharpnessDetail?
```

**回调线程**：`onQuickResult` / `refineProgress` / `completion` 已切回主线程；`progress` 在后台队列，调用方自己 `DispatchQueue.main.async`。

**不变量**：一次 `analyze` 只对应一次调用方会话，调用方必须用 `scanID` 之类的守卫丢弃过期回调。

### `ContentAnalyzer.shared` — Vision 封装

```swift
func stats(from image: UIImage) -> Stats                     // brightness, edgeDensity
func classify(image: UIImage, isScreenshot: Bool) -> Content // 分类 + 标签 + 人脸，不读字
func analyze(image: UIImage, isScreenshot: Bool, allowOCR: Bool = true) -> Content
func ocrOnly(image: UIImage) -> (receiptHits: [String], docKeywordHit: Bool, textLength: Int)
func scanQR(in image: UIImage) -> QRScan                 // 一次扫码：invoice(InvoiceInfo?) + payload(String?)
static func parseInvoicePayload(_ raw: String) -> InvoiceInfo?
func skinRatioOfImage(_ image: UIImage) -> Double          // 96×96 采样，亚毫秒，做隐私闸门
func privacyScore(image: UIImage, skin: Double? = nil) -> Double   // v3：含躯干闸门
static let privacyThreshold: Double                        // 0.42
static let torsoRatioFloor: Double                         // 0.32，非脸人体 ÷ 人体 的下限
static func uprightCGImage(_ image: UIImage) -> CGImage?   // 把 EXIF 方向烤进像素
```

**规矩**：全部同步、CPU 密集，只在 `AnalysisEngine` 的后台队列里调；不要在 View 里调。`stats` 是每张都跑的轻量函数，不要把 `classify` 混进去。

### `VideoCompressor.shared`

```swift
func compress(asset: PHAsset, completion: @escaping (Result<Outcome, Error>) -> Void)
// Outcome: oldSize, newSize, originalDeleted
```

**规矩**：完成回调在主线程。体积缩小不足 3% 时不替换原片（`originalDeleted = false`）。

## 视图层契约

| 规则 | 说明 |
|---|---|
| View 不直接 `import Photos` 后调 `PHImageManager` | 一律经 `PhotoLibraryService` |
| View 不直接调 `PHPhotoLibrary.performChanges` | 删除只走 `PhotoLibraryService.delete` |
| 所有列表/网格用 `item.id` 做 `ForEach` 的 id | 用下标会导致"划走一张，图不跟着换" |
| 需要弹层时用 item 驱动（`.sheet(item:)`） | 见 `DESIGN.md` 的交互纪律 |
| 高频进度用独立 `ObservableObject` 承载 | 例如 `RefineStatus`，别塞进结果页的 `@State` |
| 关键控件带 `accessibilityIdentifier` | Maestro 定位依赖它，改名 = CI 挂 |

### 可复用视图清单（只登记，不展开）

| 类型 | 文件 | 职责 |
|---|---|---|
| `HomeView` / `ScanningView` / `ResultView` | `ContentView.swift` | 首页 / 进度 / 结果主界面 |
| `RefineBanner` | `ContentView.swift` | 阶段二进度横幅 |
| `SelectableThumb` / `PhotoThumbView` | `ContentView.swift` | 可选中缩略图 / 纯展示缩略图 |
| `MainTabView` / `MainTabBar` / `MainTab` | `ContentView.swift` | 底部四 tab 容器 / 自绘 tab bar / 枚举（`key` 是 ASCII，供 Maestro） |
| `CategoryOverviewView` / `CategoryDetailView` | `ContentView.swift` | 分类总览（`NavigationStack` 根）/ 单类详情（多选、删除、大图） |
| `SettingsTabView` | `ContentView.swift` | 我的（显示与内容 / 数据与存储 / 帮助与支持 / 系统权限 / 关于） |
| `TutorialView` + 5 个 Mock | `TutorialView.swift` | 新手教程 5 页；Mock 全部假数据，不引用 `AnalysisResult` |
| `SpaceStats` | `ContentView.swift` | 体积统计单一口径（结果页与空间 tab 共用） |
| `SpaceDashboardView` / `FilterSheet` | `DashboardView.swift` | 体积看板（tab 页，不再是 sheet）/ 时间段与相册筛选 |
| `SwipeTriageView` / `TriageMedia` | `SwipeTriageView.swift` | 逐张过主界面 / 卡片媒体（照片 fit、视频可播、Live 自动播一次）。`blurred: true` 时先糊住，中央一个「点一下看原图」 |
| `TriageVideoBox` | `SwipeTriageView.swift` | 单卡片视频播放器，划走即停 |
| `TriageProgressStore` | `SwipeTriageView.swift` | 逐张过进度（判过的 id + 待删标记），按上下文 key 存 UserDefaults |
| `TriageImageCache` / `TriageMetrics` | `SwipeTriageView.swift` | 预取缓存（30 张，跳过视频）/ 统一取图尺寸 |
| `TriageEntryBar` | `ContentView.swift` | 「逐张过 N 项」入口条，清理页与分类页共用。有进度时右侧显示「已看 M · 继续」 |
| `PhotoPreviewView` / `ZoomableImageView` / `VideoPlaybackModel` | `PhotoPreviewView.swift` | 大图 / 缩放 / 视频播放 |
| `LivePhotoModel` / `LivePhotoSurface` / `LivePhotoLoader` | `PhotoPreviewView.swift` | Live 播放状态（token 驱动）/ `PHLivePhotoView` 包装（禁手势）/ 取图。`LivePhotoSurface` 也用在逐张过卡片里 |
| `LivePhotoStage` | `PhotoPreviewView.swift`（private） | 预览里的一页 Live：静帧可缩放 + 动态层叠加，只给当前页装载 |

### 单例与持久化

| 名字 | 存储 | 说明 |
|---|---|---|
| `BlurIgnoreStore.shared` | `UserDefaults["blurIgnoredIDs"]` | 手动排除的模糊照片 id，上限 5000 |
| `TriageImageCache.shared` | `NSCache`（countLimit 30） | 逐张过图片缓存；视频不走这里（封面单独取） |
| `TriageProgressStore.shared` | `UserDefaults["triageProgress.v1"]` | 逐张过进度：`key → {judged:[id], marked:[id], updatedAt}`。单上下文上限 5000 条、最多 8 个上下文、30 天过期；攒 2 秒落盘，`flush()` 兜底 |
| `ScreenAwake.shared` | 运行时 | 引用计数式屏幕常亮，`setScanning` / `setAppActive` 两个开关 |

## 新增功能的推荐改法

1. 判断逻辑写进 `AnalysisEngine` 或 `ContentAnalyzer`，**不要写进 View**。
2. 新字段加到 `PhotoItem`，给一个能表示"没测"的默认值（参考 `-1` / `nil`）。
3. 新阈值写进 `architecture.md` 的表，再落代码。
4. 新页面拆独立文件，并在 `project.pbxproj` 补四处引用。
5. 公共签名变了就回来改这份文档。
