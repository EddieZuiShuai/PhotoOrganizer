# 架构与数据流

一句话：**一次扫描 = 两遍缩略图 + 四段流水线**。第一遍只读 320px 缩略图算特征，立刻出货；第二遍补内容识别（Vision），回来重算一遍分数。

## 分层

```
Views/            纯展示 + 交互状态，不碰 PHImageManager
  ContentView        首页 / 扫描页 / 结果页（含筛选、选中、删除、导出）
  DashboardView      空间看板（体积分布、时间窗口、相册筛选）
  SwipeTriageView    逐张过（滑动标记，暂存不删）
  PhotoPreviewView   大图 / 缩放 / 视频播放
Services/         有状态、有队列，全部单例
  PhotoLibraryService  相册读取、缩略图、原图数据、SHA-256、删除
  AnalysisEngine       特征、分组、打分、两阶段调度
  ScanCache            增量结果缓存（按照片 ID + 修改时间），兼作断点
  ContentAnalyzer      Vision 分类 / OCR / 发票二维码 / 隐私粗筛
  VideoCompressor      转 720p 并替换原片
Models/
  PhotoItem / PhotoGroup / AnalysisResult
```

依赖方向单向：`Views → Services → Models`。`Services` 之间不互相调用（除了 `AnalysisEngine` 用 `PhotoLibraryService` 和 `ContentAnalyzer`）。

## 一次扫描的时序

```
点「开始扫描」
  │  requestAuthorization → fetchAllAssets
  ▼
[阶段 1] featurePass            global(qos: .userInitiated)
  逐张：320px 缩略图 → dHash(64bit) → 清晰度/对比度/低细节 → 亮度/边缘密度
  每 25 张回调一次进度
  ▼
[阶段 2] groupPass + assemble   （同一队列）
  候选分桶 → 完全重复（SHA-256 核对）→ 相似（星型聚类）→ 打分 → 排序
  │  此时 contentReady = false，先给用户一份可用结果
  ├──→ 主线程 onQuickResult(quick)     ← 结果页出现，横幅显示"还在识别"
  ▼
[阶段 3] contentPass            global(qos: .utility)  ← 降优先级，不跟滚动抢 CPU
  逐张：320px 分类 → 文档/截图先试二维码 → 文档类补 1024px（二维码 + OCR）
  预算：OCR 3000 张｜1024px 补读 1500 张｜小图读字兜底 200 张｜内存 < 220MB 停补读
  ▼
[阶段 4] assemble(contentReady: true)   回填分类/发票 → 重算建议分
  ▼
  主线程 completion(final)
```

关键设计：

- **增量优先**：`featurePass` 与 `contentPass` 每一步都先查 `ScanCache`。命中就整段跳过——不取缩略图、不跑 Vision。第二次扫描 1 分钟以内靠的就是这一条。
- **缓存即断点**：`ScanCache.flush()` 每 800 张落盘一次。被杀之后重启，已算过的直接命中，最多重算最后 800 张。不设单独的「继续上次」入口，避免用户要在两个按钮之间做选择。
- **只写脏数据**：`store()` 把条目同时放进 `map` 和 `dirty`；`flush()` 只编码 `dirty`，追加到 `scan-cache-v1.delta`（4 字节长度前缀 + 一批 `[CachedPhoto]`），全命中扫描时 `dirty` 为空、直接返回。base plist 只在日志超过 12 MB 时压一次。
  > 这是 1.4(19) 修 CPU 的核心。旧实现每次 `flush()` 都 `Array(map.values)` 全量编码：两万张 ≈ 5.5 MB × 28 次 = 154 MB 写盘、io 队列 90 秒 94% CPU，系统直接出 `EXC_CPU_USAGE` 报告。
- **崩溃安全**：增量日志按批追加，写到一半被杀只会留下半截记录，载入时丢弃该批；前面完整的批次仍然有效。
- **缓存失效只认时间戳**：`modificationDate` 变了（裁剪、滤镜、调色）就重算；算法口径变了就改 `ScanCache.version`，整份作废。
- **两段出货**是为了"一分钟能开始清理"，不是为了"更快"。内容识别那一段本来就要几分钟，把它挪到用户已经在翻结果页之后。
- **`scanID` 守卫**：每次重扫 `scanID += 1`，所有异步回调回来先对号。否则"重开一局后上一局结果自己弹回来"。
- **阶段 3 用 `.utility` 而不是 `.userInitiated`**：此时用户正在滚缩略图，不许抢 CPU。

## 判定口径

> 这张表是唯一事实源。改阈值必须同时改这里，并说明旧值错在哪。

| 判定 | 规则 | 代码位置 |
|---|---|---|
| 完全重复 | 原图数据 SHA-256 完全一致 + 像素尺寸一致 | `AnalysisEngine.findExactGroups` |
| 完全重复预筛 | dHash 汉明距离 ≤ `exactCandidateDistance = 3` 才去取原图核对（省 I/O） | 同上 |
| 相似 | dHash 汉明距离 ≤ `similarDistance = 8`，且不构成完全重复 | `findSimilarGroups` |
| 相似聚类 | **星型**：只和组内种子比，不做传递合并 | 同上 |
| 清晰度 | 灰度化 → 2%~98% 对比度拉伸 → 拉普拉斯方差 `lapVar` | `sharpnessDetail` |
| 模糊参考 | 全库 `lapVar` 的**中位数**（`AnalysisResult.blurReference`） | `assemble` |
| 模糊（高分） | `lapVar / 中位数 < 0.45` 且 `lapVar < 180` → +0.75 | `buildScores` |
| 模糊（提示） | `lapVar / 中位数 < 0.7` 且 `lapVar < 290` → +0.3 | 同上 |
| 模糊排除 | 低细节图、截图不参与模糊判定 | 同上 |
| 近黑 | `brightness < 0.05` → +0.7（截图走另一条 +0.55） | 同上 |
| 近白 | `brightness > 0.97` → +0.6 | 同上 |
| 纯色 | `edgeDensity < 0.012` → +0.5 | 同上 |
| 截图 | 普通截图 +0.45 | 同上 |
| 重复组非保留张 | +0.95 | 同上 |
| 相似组非最清晰张 | +0.45 | 同上 |
| 减分：发票 | -0.45（票据通常要留） | 同上 |
| 减分：有人脸 | -0.25 | 同上 |
| 文档（标签判定） | 人脸面积 ≥ 8% 或 ≥ 2 张脸 → 先判人物；否则需命中 `documentLabels` 且置信度 ≥ 0.5 | `ContentAnalyzer.category` |
| 文档（关键词覆盖） | `docKeywords` 命中 **≥ 2 个** 且人脸面积 < 8% | `ContentAnalyzer.applyKeywords` |
| 隐私粗筛 | 肤色占比 > 0.12 **且** 人体占比 > 0.10，两项相乘 × 3.2 ≥ 0.34 | `ContentAnalyzer.privacyScore` |
| 隐私不参与打分 | `category == .privacy` 直接跳过 `buildScores`，也不进 `suggestedItems` | `AnalysisEngine.buildScores` |
| 隐私缩略图打码 | **当前关闭**：`PrivacyDisplay.blurThumbnails = false`，为了逐张核对 533 张误报。改回 `true` 即恢复，三个调用点不用动 | `ContentView.PrivacyDisplay` |
| 增量命中 | `localIdentifier` 相同 **且** `abs(modificationDate 差) ≤ 1s` | `ScanCache.hit` |

`cleanupScore` 是这些加减分的累加，界面显示为百分比。它表示"综合可疑度"，不是"删除概率"。

## 内存与稳定性

| 手段 | 为什么 |
|---|---|
| 每张照片包一层 `autoreleasepool` | PHImageManager 解出的图 + CGContext 是自动释放对象；2 万张不排空会攒到几个 GB，被 jetsam 杀掉（表现为"扫到某百分比突然闪退、无崩溃日志"） |
| `PHImageManager` 缩略图 320px | 特征计算不需要更大；1024px 只在发票补读时按需取 |
| `MemoryProbe.availableMB() < 220` 停止 1024px 补读 | 大图 + Vision 是最吃内存的一步，先牺牲它保住整轮 |
| 扫描期间 `isIdleTimerDisabled` | 锁屏 = 挂起，解码与 Vision 请求被系统掐断 |
| 进度对象 `RefineStatus` 独立 `ObservableObject` | 每几十毫秒变一次；放在 `ContentView.@State` 会让两万条结果页整体重建，滚动卡死 |

## 状态所有权

| 状态 | 归谁 | 生命周期 |
|---|---|---|
| `phase` / `result` / 进度 | `ContentView` 的 `@State` | 一次会话 |
| 内容识别进度 | `RefineStatus`（`@StateObject`） | 一次扫描 |
| 布局列数 / 模糊灵敏度 | `@AppStorage("resultLayoutMode")` / `@AppStorage("blurSensitivity")` | 跨启动 |
| 手动排除的模糊照片 | `BlurIgnoreStore`（UserDefaults，上限 5000 条） | 跨启动 |
| 选中 / 已删除 | `ResultView.@State` | 结果页 |
| 逐张过的标记 | `SwipeTriageView` 内部 → `onFinish(Set<String>)` 回传 | 一次 triage |

## 边界与兜底

- **权限**：只接受 `.authorized` / `.limited`。`.limited` 时首页明确写"仅部分照片（建议改成全部）"，否则用户会以为扫漏了。
- **缩略图取不到**：`featurePass` 里所有特征都包在 `if let thumb` 内。一旦取不到，整页会"干净得像没问题"——这是历史事故（CI 里 18 张照片结果全 0）。诊断入口是 `-PODiag` 启动参数（`DebugSelfCheck`，仅 DEBUG）。
- **删除**：`PHPhotoLibrary.performChanges` → `deleteAssets`，失败回滚选中态并弹具体错误。不提供绕过「最近删除」的路径。
- **视频压缩**：720p 导出后若只小不到 3%，放弃替换原片（可能本来就是低码率）。

## 扩展点

新增一类"清理建议"需要动四处：`PhotoItem` 加字段 → `featurePass` 填值 → `buildScores` 给分 → `ResultTab` 加标签。阈值写进本文档的表，不要只留在代码里。

新增内容分类：`ContentCategory` 加 case（含 icon）→ `ContentAnalyzer.category` 映射 → 首页/结果页自动出现新标签（`ResultTab.content` 是动态生成的）。
