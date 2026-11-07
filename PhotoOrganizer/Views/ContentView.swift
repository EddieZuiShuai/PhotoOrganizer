import SwiftUI
import Photos
import UIKit

// MARK: - 主容器

enum AppPhase {
    case idle
    case scanning
    case done
}

/// 第二阶段（内容识别）的进度。
///
/// 单独做成 ObservableObject 是有原因的：这个数字每几十毫秒变一次，
/// 如果它放在 ContentView 的 @State 里，每变一次整个结果页（两万多条）都要重建一遍，
/// 滚动会明显卡。让那一条横幅自己订阅，就只重画横幅本身。
final class RefineStatus: ObservableObject {
    @Published var done: Int = 0
    @Published var total: Int = 0
    @Published var phaseText: String = ""
    /// 这一轮是在「补扫」而不是首次识别：只有弱结论（截图/文档/其他）重判。
    /// 分类卡要靠它决定显示「补扫中 62%」还是「0」——两者长得一样的话，
    /// 用户只能靠猜，猜完就跑去清缓存重扫（1.5(23) 的真实反馈）。
    @Published var backfill: Bool = false
    /// 内容识别跑完之后，还会接着跑一轮「人脸精细复核」（只针对单人照/合照）。
    /// 复核的池子只有几千张，和内容识别的分母不一样，进度条会从 100% 掉回 0%——
    /// 不单独标出来的话用户会以为卡死了。
    @Published var isFaceRefine: Bool = false

    var percent: Int {
        guard total > 0 else { return 0 }
        return min(100, Int(Double(done) / Double(total) * 100))
    }

    func reset(to total: Int) {
        done = 0
        self.total = total
        phaseText = ""
    }
}

struct ContentView: View {
    @State private var phase: AppPhase = .idle
    @State private var result: AnalysisResult?
    @State private var progressValue: Double = 0
    @State private var progressText: String = ""
    @State private var processed: Int = 0
    @State private var total: Int = 0
    @State private var errorMessage: String?
    /// 第一阶段的结果已经到了、内容识别还在后台跑
    @State private var isRefining = false
    /// 人脸复核阶段（内容识别之后、只针对单人照/合照）。
    /// 和 `isRefining` 分开：这一阶段分类已经可用，横幅要留着但不能说「正在识别分类」。
    @State private var isFaceRefining = false
    @StateObject private var refine = RefineStatus()
    /// 每一次重新扫描 +1。后台回调回来先对号：防止「已经重开一局了，
    /// 上一局的结果页又自己弹回来」。
    @State private var scanID = 0
    @Environment(\.scenePhase) private var scenePhase

    /// 首启「为什么需要联网」说明。
    /// 存**版本号**而不是 Bool：以后这段文案大改，把 `CFBundleShortVersionString` 一升
    /// 就会自然再弹一次，不用清缓存也不用加新键。和 `tutorialSeenVersion` 同一套口径。
    @AppStorage("cloudNoticeSeenVersion") private var cloudNoticeSeen: String = ""
    @State private var showCloudNotice = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.96, green: 0.96, blue: 0.97).ignoresSafeArea()

                switch phase {
                case .idle:
                    HomeView(onStart: startScan)
                case .scanning:
                    ScanningView(
                        progress: progressValue,
                        title: progressText,
                        processed: processed,
                        total: total
                    )
                case .done:
                    if let result = result {
                        MainTabView(
                            result: result,
                            isRefining: isRefining,
                            isFaceRefining: isFaceRefining,
                            refineStatus: refine,
                            onRestart: reset
                        )
                    } else {
                        HomeView(onStart: startScan)
                    }
                }
            }
            .navigationTitle("相册整理")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 首启说明挂在 NavigationStack **外面**，不是放在它的 ZStack 里：
        // 导航栏是容器的 chrome，ZStack 里的遮罩盖不住它（顶部会露出一条「相册整理」）。
        // 挂外面还能保证 phase 切到扫描页时它依然在最上层。
        .overlay {
            if showCloudNotice {
                CloudNoticeOverlay {
                    cloudNoticeSeen = appShortVersion()
                    withAnimation(.easeOut(duration: 0.18)) { showCloudNotice = false }
                }
                .transition(.opacity)
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // 扫描期间禁止自动锁屏。
        // 锁屏 = 应用被挂起，正在解码的图和排队的 Vision 请求会被系统掐断；
        // 用户解锁回来往往只能从头再扫一遍。这里跟着 phase 开关，进出后台也会重新算。
        .onChange(of: phase) { _ in
            syncScreenAwake()
        }
        .onChange(of: isRefining) { _ in
            syncScreenAwake()
        }
        .onChange(of: scenePhase) { newPhase in
            ScreenAwake.shared.setAppActive(newPhase == .active)
        }
        .onAppear {
            ScreenAwake.shared.setAppActive(scenePhase == .active)
            #if DEBUG
            // UI 用例专用：`maestro test <目录>` **不是按文件名顺序跑**的。
            // 实测 11 条 flow 的完成顺序是 04/08/06/09/01/07/00/10/05/02/03 ——
            // 等 00 跑到时，别的 flow 已经用 `scan.yaml` 里的 optional 点击把弹窗关掉、
            // 把 cloudNoticeSeenVersion 写上了，断言必然失败。
            // 带这个参数启动就无视标记强制弹一次，用例不再依赖执行顺序。
            if ProcessInfo.processInfo.arguments.contains("-ForceCloudNotice") {
                showCloudNotice = true
                return
            }
            #endif
            // 首启（含从旧版本升上来第一次）说明一次。
            // 不做延时：onAppear 时首页已经布局完，直接出现不会闪白；
            // 加延迟反而会让 CI 里的 optional 点击和截图对不上时序。
            if cloudNoticeSeen != appShortVersion() {
                showCloudNotice = true
            }
        }
        .onDisappear {
            ScreenAwake.shared.setScanning(false)
        }
    }

    private func reset() {
        scanID += 1
        result = nil
        phase = .idle
        isRefining = false
        isFaceRefining = false
        refine.reset(to: 0)
        refine.backfill = false
        refine.isFaceRefine = false
        progressValue = 0
        progressText = ""
        processed = 0
        total = 0
    }

    /// 屏幕常亮的条件：正在扫，或者结果页已经出来了但后台还在识别。
    /// 后台识别同样怕锁屏——一锁屏应用就被挂起，进度停在那儿，解锁回来还得接着等。
    private func syncScreenAwake() {
        ScreenAwake.shared.setScanning(phase == .scanning || isRefining)
    }

    private func startScan() {
        Task {
            let status = await PhotoLibraryService.shared.requestAuthorization()
            guard status == .authorized || status == .limited else {
                errorMessage = "没有相册访问权限。请到「设置 → 相册整理 → 照片」里打开权限，然后回来重试。"
                return
            }

            let assets = PhotoLibraryService.shared.fetchAllAssets()
            guard !assets.isEmpty else {
                errorMessage = "相册里没有找到照片。如果你刚才选了「部分照片」，请改成「所有照片」。"
                return
            }

            total = assets.count
            processed = 0
            progressValue = 0
            progressText = "准备开始…"
            phase = .scanning

            let myID = scanID

            AnalysisEngine.shared.analyze(assets: assets) { done, all, text in
                DispatchQueue.main.async {
                    guard scanID == myID else { return }
                    processed = done
                    total = all
                    progressText = text
                    progressValue = all > 0 ? Double(done) / Double(all) : 0
                }
            } onQuickResult: { quick in
                // 这一步已经回到主线程（引擎里做了 async）
                guard scanID == myID else { return }
                result = quick
                refine.reset(to: assets.count)
                isRefining = true
                phase = .done
            } refineProgress: { done, all, text in
                DispatchQueue.main.async {
                    guard scanID == myID else { return }
                    refine.done = done
                    refine.total = all
                    refine.phaseText = text
                    refine.backfill = text.contains("补扫")
                    // 人脸复核的池子和内容识别不是一批人，进度得分开标，
                    // 否则百分比从 100% 掉回 0% 会被当成卡死。
                    refine.isFaceRefine = text.contains("复核")
                }
            } onFaceRefined: { res in
                // 人脸复核跑完的第二次回调：只换结果、关掉横幅。
                guard scanID == myID else { return }
                result = res
                isRefining = false
                isFaceRefining = false
                refine.isFaceRefine = false
            } completion: { res in
                guard scanID == myID else { return }
                result = res
                isRefining = false
                refine.backfill = false
                // 复核紧接着就开始（引擎在 completion 之后才跑），横幅不能断。
                isFaceRefining = true
            }
        }
    }
}

// MARK: - 结果页标签

enum ResultTab: Hashable, Identifiable {
    case suggested
    case duplicate
    case similar
    case blurry
    case large
    case content(ContentCategory)

    var id: String {
        switch self {
        case .suggested: return "suggested"
        case .duplicate: return "duplicate"
        case .similar: return "similar"
        case .blurry: return "blurry"
        case .large: return "large"
        case .content(let c): return "c-" + c.rawValue
        }
    }

    var title: String {
        switch self {
        case .suggested: return "建议清理"
        case .duplicate: return "重复"
        case .similar: return "相似"
        case .blurry: return "模糊"
        case .large: return "大文件"
        case .content(let c): return c.rawValue
        }
    }

    var icon: String {
        switch self {
        case .suggested: return "sparkles"
        case .duplicate: return "doc.on.doc"
        case .similar: return "square.stack.3d.up"
        case .blurry: return "camera.filters"
        case .large: return "internaldrive"
        case .content(let c): return c.icon
        }
    }
}

// MARK: - 首页

struct HomeView: View {
    let onStart: () -> Void

    @State private var photoCount: Int = 0
    @State private var videoCount: Int = 0
    @State private var permissionText: String = "未授权"
    @State private var permissionOK: Bool = false

    /// 第一次用的人看不到教程入口（底部 tab 要扫描完才出现），
    /// 所以在首页「开始扫描」下方补一张卡。看完教程后 seenVersion 会写，
    /// 这张卡自动消失；X 只是本次会话隐藏，下次启动还会再出现，直到真的看一遍。
    @AppStorage("tutorialSeenVersion") private var seenVersion: String = ""
    @State private var showTutorial = false
    @State private var hintCardHidden = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("先在手机上把相册理清楚")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("全部在手机本地分析，照片不会上传到任何服务器。")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.white)
                .cornerRadius(14)

                HStack(spacing: 12) {
                    statBox(title: "照片", value: "\(photoCount)")
                    statBox(title: "视频", value: "\(videoCount)")
                }

                VStack(alignment: .leading, spacing: 14) {
                    featureRow(icon: "sparkles", title: "智能建议", desc: "综合判断哪些照片你可能想删，并说明理由")
                    Divider()
                    featureRow(icon: "doc.on.doc", title: "重复照片", desc: "原图文件完全相同，留一张就够")
                    Divider()
                    featureRow(icon: "square.stack.3d.up", title: "相似照片", desc: "连拍、角度几乎一样的那些")
                    Divider()
                    featureRow(icon: "camera.filters", title: "模糊照片", desc: "糊掉、拍废了的")
                    Divider()
                    featureRow(icon: "doc.text.fill", title: "发票票据", desc: "自动认出发票、收据、小票，可按类整批处理")
                    Divider()
                    featureRow(icon: "person.3.fill", title: "内容分类", desc: "单人照 / 合照 / 美食 / 风景 / 宠物 / 截图 自动归类")
                }
                .padding(18)
                .background(Color.white)
                .cornerRadius(14)

                HStack(spacing: 8) {
                    Circle()
                        .fill(permissionOK ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("相册权限：\(permissionText)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Button(action: onStart) {
                    Text("开始扫描")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color(red: 0.18, green: 0.49, blue: 0.96))
                        .cornerRadius(12)
                }

                if !hintCardHidden && seenVersion != shortVersion {
                    tutorialHintCard
                }

                Text("扫描不改动任何照片。删除一步生效，删掉的照片可在「最近删除」里 30 天内恢复。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // 版本号写在首页最底下：装完想确认「我到底装的是哪一版」，
                // 不用去设置里翻三层。构建号就在括号里。
                Text(appVersionText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .padding(.bottom, 20)
            }
            .padding(20)
        }
        .onAppear(perform: loadInfo)
        .sheet(isPresented: $showTutorial) {
            TutorialView(hasScanned: photoCount > 0)
        }
    }

    /// "版本 1.4（构建号 17）"——首页底部那行小字的数据源
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(short)（构建号 \(build)）"
    }

    /// 教程状态用的是版本号（不是 Bool），这里只取短版本号来比对
    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5"
    }

    /// 首页第一次用的提示卡，放在「开始扫描」下方而不是上方——
    /// 放上面会推动按钮位置，8 条 UI 用例的首屏步骤全要改。
    private var tutorialHintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第一次用？")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    hintCardHidden = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            Text("90 秒看懂：怎么扫、怎么删、左滑是什么意思。不挡扫描，随时能重看。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showTutorial = true
            } label: {
                Text("查看教程")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.18, green: 0.49, blue: 0.96))
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tutorial-home-card")
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(14)
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.primary)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white)
        .cornerRadius(14)
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.18, green: 0.49, blue: 0.96))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func loadInfo() {
        let status = PhotoLibraryService.shared.currentStatus()
        switch status {
        case .authorized:
            permissionText = "已允许全部"
            permissionOK = true
        case .limited:
            permissionText = "仅部分照片（建议改成全部）"
            permissionOK = false
        case .denied, .restricted:
            permissionText = "已拒绝，请去设置里打开"
            permissionOK = false
        case .notDetermined:
            permissionText = "还没授权，点下面按钮会弹窗"
            permissionOK = false
        @unknown default:
            permissionText = "未知"
            permissionOK = false
        }

        guard status == .authorized || status == .limited else { return }

        let assets = PhotoLibraryService.shared.fetchAllAssets()
        photoCount = assets.filter { $0.mediaType == .image }.count
        videoCount = assets.filter { $0.mediaType == .video }.count
    }
}

// MARK: - 扫描进度

struct ScanningView: View {
    let progress: Double
    let title: String
    let processed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 10)
                    .frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: max(0.01, progress))
                    .stroke(Color(red: 0.18, green: 0.49, blue: 0.96), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 22, weight: .semibold))
            }

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.primary)

            Text("\(processed) / \(total)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("先算重复和模糊，很快就能出结果\n内容分类会在结果页后台继续，不耽误先看")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }
}

// MARK: - 结果

/// 预览要呈现的一组照片。
/// 每次打开都生成新的 id，保证覆盖层拿到的是「这一次」的数据和起始位置，
/// 不会复用上一次的快照。
struct PreviewTarget: Identifiable {
    let id = UUID()
    let items: [PhotoItem]
    let startIndex: Int
}

/// 列表布局：单列 / 两列 / 三列
enum LayoutMode: Int, CaseIterable, Identifiable {
    case list = 1
    case two = 2
    case three = 3

    var id: Int { rawValue }
    var columns: Int { rawValue }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .two: return "square.grid.2x2"
        case .three: return "square.grid.3x3"
        }
    }

    var title: String {
        switch self {
        case .list: return "单列"
        case .two: return "两列"
        case .three: return "三列"
        }
    }
}

/// 「这张其实挺清晰」的黑名单：用户手动否掉的，以后不再算模糊
final class BlurIgnoreStore {
    static let shared = BlurIgnoreStore()
    private let key = "blurIgnoredIDs"
    private let defaults = UserDefaults.standard

    func all() -> Set<String> {
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    func add(_ id: String) {
        var list = defaults.stringArray(forKey: key) ?? []
        if !list.contains(id) {
            list.append(id)
            if list.count > 5000 {
                list.removeFirst(list.count - 5000)
            }
            defaults.set(list, forKey: key)
        }
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
    }
}

struct ResultView: View {
    let result: AnalysisResult
    /// 内容识别还在后台跑（内容分类还没出来）
    let isRefining: Bool
    /// 人脸复核阶段。内容识别已经结束（分类可用），只是合照数字还会再刷一次
    let isFaceRefining: Bool
    let refineStatus: RefineStatus
    let onRestart: () -> Void

    /// 已删的照片。提到 MainTabView 里是因为「空间」tab 也要读它算释放量；
    /// 放在这里的话，切一次 tab 就丢了。
    @Binding var deletedIDs: Set<String>
    /// 刚被隐藏的条目。和 deletedIDs 分开：隐藏不释放空间，不能算进「已释放」。
    @Binding var hiddenIDs: Set<String>

    /// 从「分类」tab 点某张卡片跳过来时，指定要打开哪个标签。
    @Binding var requestedTab: ResultTab?

    /// 全量 id → 照片。跨分类选中、跨分类删除都靠它，保证「切分类不丢选中」。
    private let itemIndex: [String: PhotoItem]
    /// 按体积从大到小预排好，避免每次刷新都重排几万张
    private let sortedBySize: [PhotoItem]

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    @State private var tab: ResultTab = .suggested
    @State private var selectedIDs: Set<String> = []

    /// 「建议清理」的排序：默认按时间（由近到远），可以切回按建议分。
    ///
    /// 为什么不一刀切改成时间：这一页唯一的价值就是「最该删的排前面」。
    /// 但用户找照片的习惯是按时间翻（1.5(25) 的反馈），两个诉求都要留。
    /// 存 @AppStorage，切过一次以后一直按他选的来。
    @AppStorage("suggestedSortByScore") private var suggestedSortByScore: Bool = false

    /// 用「要预览的对象」来控制弹出，而不是 Bool + 三个并列状态。
    /// 后者在第一次弹出时会拿到尚未更新的空数组（SwiftUI 的呈现内容按快照捕获），
    /// 表现就是「第一次点开照片永远是空白页」。
    @State private var previewTarget: PreviewTarget?

    @State private var message: String?
    @State private var toast: String?

    /// 一次选中太多张时先问一句。
    /// 起因：建议清理页右上角点一下「全选 2779」，底部按钮立刻变成「删除 2779 张」，
    /// 中间没有任何缓冲；而建议里本来就混着误判，点错的代价太大。
    @State private var bulkConfirm: BulkConfirm?
    /// 隐私页签里点「隐藏」的二次确认。隐藏会让人找不着照片，值得多问一句。
    @State private var confirmHide = false
    /// 超过这个数量才拦。几十张的批量操作不值得多弹一次框。
    private let bulkConfirmThreshold = 500

    /// 批量操作的二次确认
    private enum BulkConfirm: Identifiable {
        case select(ids: Set<String>)
        case delete

        var id: String {
            switch self {
            case .select(let ids): return "select-\(ids.count)"
            case .delete: return "delete"
            }
        }
    }

    // 筛选（时间段 / 相册）
    @State private var period: TimeWindow = .all
    @State private var albumChoice: AlbumOption?
    @State private var albumIDs: Set<String>?
    @State private var albumOptions: [AlbumOption] = []
    @State private var showFilter = false

    // 附加面板
    @State private var triage: TriageRequest?

    // 视频压缩
    @State private var compressingID: String?
    @State private var confirmCompress: PhotoItem?

    // 布局 / 模糊灵敏度 / 手动排除
    @AppStorage("resultLayoutMode") private var layoutRaw: Int = 3
    @AppStorage("blurSensitivity") private var blurLevel: Int = 1
    /// 设置页里的两个开关。放在这里是因为「清理」页要用它们决定
    /// 是否显示隐私页签、缩略图要不要糊；用 @AppStorage 才能跟着开关即时重绘。
    @AppStorage("showPrivacyCategory") private var showPrivacyCategory: Bool = false
    @AppStorage("blurPrivacyThumbnails") private var blurPrivacyThumbnails: Bool = true
    @State private var ignoredBlurIDs: Set<String> = BlurIgnoreStore.shared.all()
    @State private var lastLongPressAt: Date = .distantPast

    init(
        result: AnalysisResult,
        isRefining: Bool = false,
        isFaceRefining: Bool = false,
        refineStatus: RefineStatus = RefineStatus(),
        deletedIDs: Binding<Set<String>>,
        hiddenIDs: Binding<Set<String>>,
        requestedTab: Binding<ResultTab?>,
        onRestart: @escaping () -> Void
    ) {
        self.result = result
        self.isRefining = isRefining
        self.isFaceRefining = isFaceRefining
        self.refineStatus = refineStatus
        self.onRestart = onRestart
        self._deletedIDs = deletedIDs
        self._hiddenIDs = hiddenIDs
        self._requestedTab = requestedTab
        var map: [String: PhotoItem] = [:]
        map.reserveCapacity(result.items.count)
        for item in result.items {
            map[item.id] = item
        }
        self.itemIndex = map
        self.sortedBySize = result.items
            .filter { $0.fileSize > 0 }
            .sorted { $0.fileSize > $1.fileSize }
    }

    private var layout: LayoutMode {
        return LayoutMode(rawValue: layoutRaw) ?? .three
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            filterBar
            triageBar
            toolbar

            ScrollView {
                scrollContent
            }
            // 切页签时把滚动位置一起重置。
            // 不加这句的话，ScrollView 是同一个实例、只换内容：从「建议清理 2807 张」
            // 滚到第 800 屏再点「重复」，新内容只有五张卡片，滚动位置还停在原处，
            // 于是整片空白——这正是「切到别的页签再回来内容变空」的真正原因。
            .id(tab)
            // 挂在 ScrollView 上而不是外层链路上：外层已经有一个「压缩确认」，
            // 两个 confirmationDialog 叠在同一个视图上容易只生效一个。
            .confirmationDialog(
                bulkConfirmTitle,
                isPresented: Binding(
                    get: { bulkConfirm != nil },
                    set: { if !$0 { bulkConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pending = bulkConfirm {
                    switch pending {
                    case .select(let ids):
                        Button("选中这 \(ids.count) 张") {
                            selectedIDs.formUnion(ids)
                            showToast("已选中 \(ids.count) 张")
                            bulkConfirm = nil
                        }
                    case .delete:
                        Button("删除 \(selectedIDs.count) 张", role: .destructive) {
                            reallyDelete()
                            bulkConfirm = nil
                        }
                    }
                }
                Button("取消", role: .cancel) { bulkConfirm = nil }
            } message: {
                Text(bulkConfirmMessage)
            }
        }
        // safeAreaInset 而不是 overlay：底部多了一条 tab bar 之后，
        // overlay 会直接压在 tab 上（两个都贴底），safeAreaInset 会把内容区先让出来。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomArea
        }
        .overlay {
            compressingOverlay
        }
        .alert("出错了", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("隐藏这 \(selectedIDs.count) 项？", isPresented: $confirmHide) {
            Button("取消", role: .cancel) {}
            Button("隐藏") { hideSelected() }
        } message: {
            Text("它们会被移到系统「已隐藏」相簿，并从本 App 里消失，打开要 Face ID。注意：iOS 16 起 App 读不到那个相簿，**取消隐藏只能去「照片」App 手动操作**。")
        }
        .confirmationDialog(
            "压缩这段视频？",
            isPresented: Binding(
                get: { confirmCompress != nil },
                set: { if !$0 { confirmCompress = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("开始压缩") {
                if let item = confirmCompress {
                    confirmCompress = nil
                    startCompress(item)
                }
            }
            Button("取消", role: .cancel) { confirmCompress = nil }
        } message: {
            Text("转成 720p 后存成相册里的新视频；紧接着系统会再问一次「是否删除原片」，点「删除」才算替换完成。大视频要几分钟，期间别锁屏。")
        }
        .onChange(of: albumChoice) { choice in
            reloadAlbumIDs(choice)
        }
        .fullScreenCover(item: $previewTarget) { target in
            PhotoPreviewView(
                items: target.items,
                startIndex: target.startIndex,
                selectedIDs: $selectedIDs
            ) { item in
                deleteItems([item])
            }
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet(period: $period, album: $albumChoice, albums: albumOptions)
        }
        .sheet(item: $triage) { request in
            SwipeTriageView(
                title: request.title,
                progressKey: request.progressKey,
                items: request.items,
                blurred: request.blurred,
                isPrivacy: request.isPrivacy,
                onFinish: { marks in
                    guard !marks.isEmpty else { return }
                    selectedIDs.formUnion(marks)
                    showToast("已选 \(marks.count) 张 · 可以删除，也可以隐藏")
                },
                onDeleteMany: { items in
                    // 逐张过里点「删除 N 张」= 批量真删。这里只负责落到相册，
                    // 卡片自己会从列表里拿掉，不需要再回到结果页刷新。
                    deleteItems(items)
                },
                onHide: { item in
                    // 逐张过里单张隐藏成功。网格要立刻少一格，选中集合也要摘掉。
                    hiddenIDs.insert(item.id)
                    selectedIDs.remove(item.id)
                    showToast("已隐藏 1 张 · 去「照片」App 的「已隐藏」可取消")
                }
            )
        }
        .onChange(of: showPrivacyCategory) { show in
            // 关掉开关时如果正好停在某个隐私页，退回到「建议清理」，
            // 否则用户会看到一个已经从页签列表里消失的分类内容。
            // 1.5 起隐私有两页（照片 / 视频），两个都要退。
            if !show {
                if case .content(let c) = tab, c.isPrivacy {
                    tab = .suggested
                }
            }
        }
        .onChange(of: requestedTab) { value in
            guard let value = value else { return }
            tab = value
            // 清空要延后一帧：在 onChange 里直接写回 binding 会触发
            // 「Modifying state during view update」的紫条警告。
            DispatchQueue.main.async {
                requestedTab = nil
            }
        }
        .onAppear(perform: loadAlbums)
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    // MARK: - 批量确认

    private var bulkConfirmTitle: String {
        guard let pending = bulkConfirm else { return "" }
        switch pending {
        case .select(let ids):
            return "一次选中 \(ids.count) 张？"
        case .delete:
            return "删除 \(selectedIDs.count) 张照片？"
        }
    }

    private var bulkConfirmMessage: String {
        guard let pending = bulkConfirm else { return "" }
        switch pending {
        case .select(let ids):
            let total = selectedIDs.union(ids).count
            return "选中的照片马上会进入待删除状态，底部红色按钮会变成「删除 \(total) 张」。建议先翻一眼再决定。"
        case .delete:
            return "会一次性删掉 \(selectedIDs.count) 张，删掉的照片在「最近删除」里可以放 30 天。"
        }
    }

    // MARK: - 数据

    private func passes(_ item: PhotoItem) -> Bool {
        guard period.contains(item.creationDate) else { return false }
        if let ids = albumIDs {
            return ids.contains(item.id)
        }
        return true
    }

    private func alive(_ group: PhotoGroup) -> PhotoGroup? {
        let items = group.items.filter { !deletedIDs.contains($0.id) && passes($0) }
        guard items.count > 1 else { return nil }
        return PhotoGroup(items: items, isExactDuplicate: group.isExactDuplicate)
    }

    private var dupGroups: [PhotoGroup] {
        result.duplicateGroups.compactMap { alive($0) }
    }

    private var simGroups: [PhotoGroup] {
        result.similarGroups.compactMap { alive($0) }
    }

    private var suggested: [PhotoItem] {
        let base = result.suggestedItems.filter { !deletedIDs.contains($0.id) && passes($0) }
        // 引擎给的就是时间降序（fetchAssets 的 creationDate desc）。
        // 只有用户主动切成「按建议分」时才重排——两万条排一次几十毫秒，不亏。
        guard suggestedSortByScore else { return base }
        return base.sorted { $0.cleanupScore > $1.cleanupScore }
    }

    /// 模糊参考值：整个相册的中位清晰度。低于它的比例越小越可能是糊片。
    private var blurReference: Double {
        return max(1, result.blurReference)
    }

    /// 模糊列表：三档灵敏度，另外扣掉用户手动否掉的
    private var blurry: [PhotoItem] {
        let level = min(max(blurLevel, 0), 2)
        let caps = [110.0, 180.0, 290.0]
        let limits = [0.30, 0.45, 0.68]
        let cap = caps[level]
        let limit = limits[level]
        let ref = blurReference

        return result.blurryItems.filter { item in
            guard !deletedIDs.contains(item.id), passes(item) else { return false }
            guard !ignoredBlurIDs.contains(item.id) else { return false }
            guard let s = item.sharpness else { return false }
            return s < cap && s / ref < limit
        }
    }

    private var shots: [PhotoItem] {
        result.screenshotItems.filter { !deletedIDs.contains($0.id) && passes($0) }
    }

    private func contentItems(_ category: ContentCategory) -> [PhotoItem] {
        (result.categoryBuckets[category] ?? []).filter {
            !deletedIDs.contains($0.id) && !hiddenIDs.contains($0.id) && passes($0)
        }
    }

    /// 大文件：优先 ≥10MB，按体积从大到小；都不够 10MB 时至少给出前 60 个
    private var largeItems: [PhotoItem] {
        let all = sortedBySize.filter { !deletedIDs.contains($0.id) && passes($0) }
        let big = all.filter { $0.fileSize >= 10 * 1024 * 1024 }
        return big.isEmpty ? Array(all.prefix(60)) : Array(big.prefix(400))
    }

    private var tabs: [ResultTab] {
        var list: [ResultTab] = [.suggested, .duplicate, .similar, .blurry]
        if !largeItems.isEmpty {
            list.append(.large)
        }
        for category in ContentCategory.allCases where category != .other {
            // 设置里关掉「显示隐私分类」之后，两个隐私页签（照片 / 视频）整个不出现。
            // 注意只影响展示：文件本身还在相册里，也没被动过。
            if category.isPrivacy && !showPrivacyCategory { continue }
            let arr = contentItems(category)
            if !arr.isEmpty {
                list.append(.content(category))
            }
        }
        return list
    }

    private func count(for target: ResultTab) -> Int {
        switch target {
        case .suggested: return suggested.count
        case .duplicate: return dupGroups.reduce(0) { $0 + $1.items.count }
        case .similar: return simGroups.reduce(0) { $0 + $1.items.count }
        case .blurry: return blurry.count
        case .large: return largeItems.count
        case .content(let c): return contentItems(c).count
        }
    }

    private func currentList() -> [PhotoItem] {
        switch tab {
        case .suggested: return suggested
        case .duplicate: return dupGroups.flatMap { $0.items }
        case .similar: return simGroups.flatMap { $0.items }
        case .blurry: return blurry
        case .large: return largeItems
        case .content(let c): return contentItems(c)
        }
    }

    private var isGroupTab: Bool {
        return tab == .duplicate || tab == .similar
    }

    /// 当前标签下「按行/格子铺开」的照片（分组标签返回空）
    private var flatItems: [PhotoItem] {
        switch tab {
        case .suggested: return suggested
        case .blurry: return blurry
        case .large: return largeItems
        case .content(let c): return contentItems(c)
        case .duplicate, .similar: return []
        }
    }

    private var currentTag: String? {
        switch tab {
        case .blurry: return "模糊"
        case .content(let c): return c.rawValue
        default: return nil
        }
    }

    private var emptyTextForCurrentTab: String {
        switch tab {
        case .suggested: return "没有需要特别提醒的照片"
        case .blurry: return "这一档灵敏度下没有模糊照片"
        case .large: return "没有找到大文件"
        case .content: return "这一类没有照片"
        default: return "没有内容"
        }
    }

    // MARK: 体积统计（空间看板用）
    // 口径统一放在 SpaceStats 里：底部多了「空间」tab 之后，这块数据有两个读者
    // （结果页的 sheet、独立的 tab），逻辑留两份迟早会算出两个数。

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(summaryLine)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                filterButton
            }

            HStack(spacing: 8) {
                summaryItem(title: "建议清理", value: "\(suggested.count)", color: Color(red: 0.85, green: 0.25, blue: 0.2))
                summaryItem(title: "重复组", value: "\(dupGroups.count)", color: Color(red: 0.85, green: 0.45, blue: 0.15))
                summaryItem(title: "相似组", value: "\(simGroups.count)", color: Color(red: 0.1, green: 0.5, blue: 0.65))
                summaryItem(title: "截图", value: "\(shots.count)", color: Color(red: 0.4, green: 0.45, blue: 0.5))
            }

            if isRefining || isFaceRefining {
                RefineBanner(status: refineStatus)
            }

            if !selectedIDs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("已选 \(selectedIDs.count) 张 · 切换分类不会丢")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button {
                        selectedIDs.removeAll()
                    } label: {
                        Text("取消选中 \(selectedIDs.count) 张")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .accessibilityIdentifier("chip-clear-selection")
                }
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.08)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 筛选入口。原来和「空间」挤在一个 11 号字的小胶囊里，太不起眼；
    /// 1.5 把「空间」拿掉（和底部 tab 重复），筛选单独放大成一颗整按钮。
    private var filterButton: some View {
        Button {
            showFilter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .semibold))
                Text("筛选")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(blue)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-filter")
    }

    @ViewBuilder
    private var filterBar: some View {
        if period != .all || albumChoice != nil {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 11))
                Text(filterSummary)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    period = .all
                    albumChoice = nil
                    albumIDs = nil
                } label: {
                    Text("清除筛选")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(blue.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    /// 逐张过：从右上角工具栏挪到列表上方，变成一条带张数的主入口。
    ///
    /// 为什么不做成第五个 tab（1.5 评估结论）：
    /// 1. 它不是一个「栏目」，而是**对当前这份列表的动作**。放进 tab 之后，
    ///    用户还得在 tab 里再选一次「过哪一类」，等于把刚选好的上下文扔掉重来。
    /// 2. 底部 tab 的语义是「平级的几个世界」。逐张过和「清理」共用同一份数据、
    ///    同一套筛选，它是清理的一种视图，不是第二个世界。
    /// 3. 张数是这个入口最重要的信息（「过 3 张」和「过 800 张」是两件事），
    ///    tab 图标放不下数字。
    /// 所以保留在清理页，但升级成整行、带张数、带一行说明——从「隐藏小按钮」变成主路径。
    ///
    /// 1.5(26) 起这整行抽成 `TriageEntryBar`，和分类详情页共用同一份实现：
    /// 两个入口的一致性靠「同一份代码」保证，而不是靠两处手抄得一样。
    @ViewBuilder
    private var triageBar: some View {
        let list = currentList()
        if !list.isEmpty {
            TriageEntryBar(
                count: list.count,
                judgedCount: TriageProgressStore.shared.judgedCount(for: triageKey)
            ) {
                startTriage()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    /// 进度身份。只按「哪个 tab」分，不把时间段 / 相册拼进来：
    /// 进度存的是 id 集合，跟筛选条件无关——你切到「近一年」时，
    /// 已经判过的照片本来就不该再问一遍。清理页和分类页的同一个内容分类
    /// 也故意共用一把 key，两边判过的进度是同一份。
    private var triageKey: String {
        switch tab {
        case .suggested: return "clean.suggested"
        case .duplicate: return "clean.duplicate"
        case .similar: return "clean.similar"
        case .blurry: return "clean.blurry"
        case .large: return "clean.large"
        case .content(let c): return "cat." + c.rawValue
        }
    }

    private var filterSummary: String {
        let albumName = albumChoice?.title ?? "全部相册"
        return period.rawValue + " · " + albumName
    }

    private var largeTotalBytes: Int64 {
        largeItems.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    private var summaryLine: String {
        var s = "\(result.photoCount) 张照片"
        if result.videoCount > 0 {
            s += " · \(result.videoCount) 视频"
        }
        if !deletedIDs.isEmpty {
            s += " · 已删 \(deletedIDs.count)"
        }
        return s
    }

    private func summaryItem(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white)
        .cornerRadius(10)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11))
                            Text("\(item.title) \(count(for: item))")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(tab == item ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                tab == item
                                ? blue
                                : Color.white
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: 工具条（提示 + 全选 + 布局 + 模糊灵敏度）

    private var toolbar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(selectedIDs.isEmpty
                     ? "点一下选中 · 长按放大"
                     : "已选 \(selectedIDs.count) 张 · 再点取消")
                    .font(.system(size: 11))
                    .foregroundColor(selectedIDs.isEmpty ? .secondary : .red)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !isGroupTab && !flatItems.isEmpty {
                    Button {
                        toggleSelectAll(flatItems)
                    } label: {
                        Text(allSelected(flatItems) ? "取消全选" : "全选 \(flatItems.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(blue.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }

                if !isGroupTab {
                    layoutButtons
                }
            }

            if tab == .blurry {
                blurLevelBar
            }
            if tab == .suggested {
                suggestedSortBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 5)
    }

    private var layoutButtons: some View {
        HStack(spacing: 2) {
            ForEach(LayoutMode.allCases) { mode in
                Button {
                    layoutRaw = mode.rawValue
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(layoutRaw == mode.rawValue ? .white : .secondary)
                        .frame(width: 27, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(layoutRaw == mode.rawValue ? blue : Color.black.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
    }

    /// 「建议清理」的排序切换。默认「由近到远」，和模糊/分类/重复一条时间轴；
    /// 想按「最该删的在前」看，切右边那个。
    private var suggestedSortBar: some View {
        HStack(spacing: 6) {
            Text("排序")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                ForEach([false, true], id: \.self) { byScore in
                    Button {
                        suggestedSortByScore = byScore
                    } label: {
                        Text(byScore ? "建议分" : "由近到远")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(suggestedSortByScore == byScore ? .white : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    suggestedSortByScore == byScore ? blue : Color.black.opacity(0.05)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(byScore ? "suggested-sort-score" : "suggested-sort-time")
                }
            }

            Spacer(minLength: 4)
        }
    }

    private var blurLevelBar: some View {
        HStack(spacing: 6) {
            Text("模糊判定")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Button {
                        blurLevel = i
                    } label: {
                        Text(["宽松", "标准", "严格"][i])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(blurLevel == i ? .white : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(blurLevel == i ? blue : Color.black.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            if !ignoredBlurIDs.isEmpty {
                Button {
                    BlurIgnoreStore.shared.removeAll()
                    ignoredBlurIDs = []
                    showToast("已恢复被排除的照片")
                } label: {
                    Text("恢复 \(ignoredBlurIDs.count) 张")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(blurry.count) 张")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: 列表

    private var gridColumns: [GridItem] {
        return Array(repeating: GridItem(.fixed(cellSide), spacing: 6), count: layout.columns)
    }

    /// 格子边长：用屏幕宽度算死，避免 aspectRatio 在 LazyVGrid 里高度塌成 0
    private var cellSide: CGFloat {
        let w = UIScreen.main.bounds.width
        let n = CGFloat(max(1, layout.columns))
        let padding: CGFloat = 24 + (n - 1) * 6
        return max(60, (w - padding) / n)
    }

    @ViewBuilder
    private var scrollContent: some View {
        if isGroupTab {
            LazyVStack(spacing: 10) {
                if tab == .duplicate {
                    if dupGroups.isEmpty {
                        emptyHint("没有发现完全相同的照片", icon: "checkmark.circle")
                    } else {
                        ForEach(Array(dupGroups.enumerated()), id: \.element.id) { index, group in
                            groupCard(group: group, index: index + 1)
                        }
                    }
                } else {
                    if simGroups.isEmpty {
                        emptyHint("没有发现相似照片", icon: "checkmark.circle")
                    } else {
                        ForEach(Array(simGroups.enumerated()), id: \.element.id) { index, group in
                            groupCard(group: group, index: index + 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 140)

        } else if flatItems.isEmpty {
            emptyHint(emptyTextForCurrentTab, icon: "checkmark.circle")
                .padding(.top, 30)

        } else if layout == .list {
            flatListBody(flatItems)

        } else {
            gridBody(flatItems)
        }
    }

    /// 列表：一次算好数组再往下传，避免每一行都重新过滤几万张
    private func flatListBody(_ list: [PhotoItem]) -> some View {
        return LazyVStack(spacing: 8) {
            if tab == .large {
                HStack {
                    Text("按体积从大到小 · 共 " + byteText(largeTotalBytes))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 2)
            }

            ForEach(list) { item in
                itemRow(item, tag: currentTag, list: list)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 140)
    }

    private func gridBody(_ list: [PhotoItem]) -> some View {
        return LazyVGrid(columns: gridColumns, spacing: 6) {
            ForEach(list) { item in
                gridCell(item, tag: currentTag, list: list)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 140)
    }

    private func emptyHint(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            if tab == .blurry {
                Text("觉得判得不准，就切上面的「宽松」，或者点「算清晰」把某张排除掉")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: 分组卡片（重复 / 相似）

    private func groupCard(group: PhotoGroup, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.isExactDuplicate ? "重复组 \(index)" : "相似组 \(index)")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text("\(group.items.count) 张")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text(group.isExactDuplicate
                 ? "原图文件字节完全一致（已逐张核对）· 点图选中，右上角 ⤢ 放大"
                 : "内容接近但不完全相同 · 点图选中，右上角 ⤢ 放大")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.items) { item in
                        SelectableThumb(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            size: 96,
                            showsZoomBadge: true,
                            blurred: blurPrivacyThumbnails && item.category.isPrivacy,
                            onOpen: { open(item, in: group.items) },
                            onToggle: { toggle(item.id) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            // 横向 ScrollView 嵌在 LazyVStack 里时，高度在首帧可能测不出来（返回 0），
            // 整张卡片就塌成一条线。给死高度，别让系统去猜。
            .frame(height: 104)

            HStack {
                Button {
                    selectMany(Set(group.items.dropFirst().map { $0.id }))
                } label: {
                    Text("选中其余 \(group.items.count - 1) 张")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.2))
                }

                Spacer()

                if let first = group.items.first {
                    Text(first.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(12)
    }

    // MARK: 单行（列表布局）

    private func itemRow(_ item: PhotoItem, tag: String?, list: [PhotoItem]) -> some View {
        let selected = selectedIDs.contains(item.id)
        let detail = tagText(item)

        return HStack(spacing: 12) {
            // 放大角标统一挂在缩略图右上角：列表行原来是右侧一个方形按钮，
            // 和分组卡片、网格三处三种样子，用户每换一个布局都得重新找。
            thumb(item, size: 78, selected: selected)
                .overlay(alignment: .topTrailing) {
                    zoomBadge(item, in: list, size: 22)
                        .padding(3)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    if item.cleanupScore >= 0.5 {
                        Text("\(item.scorePercent)%")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(scoreColor(item.cleanupScore)))
                    }
                }

                if tab == .blurry {
                    Text("清晰度 \(Int(item.sharpnessScore.rounded())) / 100")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if !item.cleanupReasons.isEmpty {
                    Text(item.cleanupReasons.prefix(2).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        Text(item.resolutionText)
                        if !item.sizeText.isEmpty {
                            Text("·")
                            Text(item.sizeText)
                        }
                        if item.isVideo && !durationText(item).isEmpty {
                            Text("·")
                            Text(durationText(item))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }

                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(blue)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if tab == .blurry {
                Button {
                    ignoreBlur(item)
                } label: {
                    Text("算清晰")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.15, green: 0.55, blue: 0.35))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.35).opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else if let tag = tag {
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tag == "模糊" ? Color.orange : Color.gray)
                    .cornerRadius(6)
            }

            if tab == .large && item.isVideo {
                Button {
                    confirmCompress = item
                } label: {
                    Text("720p")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(blue.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(compressingID != nil)
            }
        }
        .padding(10)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? blue.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { tapRow(item) }
        .onLongPressGesture(minimumDuration: 0.35) {
            lastLongPressAt = Date()
            open(item, in: list)
        }
    }

    // MARK: 单格（两列 / 三列布局）

    private func gridCell(_ item: PhotoItem, tag: String?, list: [PhotoItem]) -> some View {
        let selected = selectedIDs.contains(item.id)

        return ZStack {
            PhotoThumbView(asset: item.asset, blurred: blurPrivacyThumbnails && item.category.isPrivacy)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortDate(item))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(cellExtra(item))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            if selected {
                blue.opacity(0.30)
            }
        }
        .frame(width: cellSide, height: cellSide)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.white : Color.clear, lineWidth: 2.5)
        )
        .overlay(alignment: .topLeading) {
            if let tag = tag {
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tag == "模糊" ? Color.orange : Color.gray.opacity(0.85)))
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if tab == .large && item.isVideo {
                    Button {
                        confirmCompress = item
                    } label: {
                        Text("720p")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(blue.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                }
                zoomBadge(item, in: list, size: 24)
            }
            .padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            if selected {
                checkBadge
                    .padding(5)
            }
        }
        // 网格布局下的「算清晰」。
        // 1.4 的问题：这个按钮只存在于列表布局右侧，默认布局是三列，
        // 于是「这张其实挺清晰」在网格里根本没有入口，用户以为没这功能。
        // 放在左下角：右下角是选中勾，右上角是放大 + 720p，只剩这一块空着。
        .overlay(alignment: .bottomLeading) {
            if tab == .blurry {
                Button {
                    ignoreBlur(item)
                } label: {
                    Text("算清晰")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.35).opacity(0.92)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityIdentifier("cell-clear-blur-" + item.displayName)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { tapRow(item) }
        .onLongPressGesture(minimumDuration: 0.35) {
            lastLongPressAt = Date()
            open(item, in: list)
        }
        // 给自动化测试和 VoiceOver 一个稳定的名字：点它 = 选中这张
        .accessibilityElement(children: .combine)
        .accessibilityLabel("照片 " + item.displayName)
        .accessibilityIdentifier("cell-" + item.displayName)
        .accessibilityAddTraits(.isButton)
    }

    /// 方形缩略图 + 选中态（蓝底 + 白框 + 右下角勾）
    private func thumb(_ item: PhotoItem, size: CGFloat, selected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            PhotoThumbView(asset: item.asset, size: size, blurred: blurPrivacyThumbnails && item.category.isPrivacy)

            if selected {
                Rectangle()
                    .fill(blue.opacity(0.30))
                    .frame(width: size, height: size)
                checkBadge
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? blue : Color.clear, lineWidth: 2.5)
        )
        .cornerRadius(8)
    }

    private var checkBadge: some View {
        ZStack {
            Circle()
                .fill(blue)
                .frame(width: 19, height: 19)
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: 19, height: 19)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
    }

    /// 统一的「放大」角标：所有布局、所有分类都用它，位置固定右上角。
    ///
    /// 之前只有列表布局右侧有一个方形按钮，分组卡片和网格里只能长按——
    /// 长按是隐藏技能，用户根本不知道。现在改成每张缩略图右上角都挂一个，
    /// 样式只有一个来源，改一次到处生效。
    private func zoomBadge(_ item: PhotoItem, in list: [PhotoItem], size: CGFloat = 24) -> some View {
        Button {
            open(item, in: list)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("放大 " + item.displayName)
        .accessibilityIdentifier("zoom-" + item.displayName)
    }

    private func shortDate(_ item: PhotoItem) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: item.creationDate ?? Date(timeIntervalSince1970: 0))
    }

    private func cellExtra(_ item: PhotoItem) -> String {
        if tab == .blurry {
            return "清晰度 " + String(Int(item.sharpnessScore.rounded()))
        }
        if item.isVideo {
            let d = durationText(item)
            if item.sizeText.isEmpty {
                return d.isEmpty ? "视频" : d
            }
            return d.isEmpty ? item.sizeText : item.sizeText + " · " + d
        }
        if !item.sizeText.isEmpty {
            return item.sizeText
        }
        return item.resolutionText
    }

    private func durationText(_ item: PhotoItem) -> String {
        let d = Int(item.asset.duration.rounded())
        if d <= 0 { return "" }
        if d >= 3600 {
            return String(format: "%d:%02d:%02d", d / 3600, (d % 3600) / 60, d % 60)
        }
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    private func tagText(_ item: PhotoItem) -> String {
        if !item.ocrHits.isEmpty {
            return "识别到：" + item.ocrHits.prefix(3).joined(separator: " / ")
        }
        if !item.contentTags.isEmpty {
            return item.contentTags.joined(separator: " · ")
        }
        return ""
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.85 { return Color(red: 0.85, green: 0.25, blue: 0.2) }
        if score >= 0.65 { return Color(red: 0.9, green: 0.5, blue: 0.1) }
        return Color(red: 0.55, green: 0.55, blue: 0.6)
    }

    // MARK: 底部操作栏

    /// 当前页签是不是隐私类。只有它才给「隐藏」按钮——
    /// 普通分类里那颗按钮没有意义，只会增加误触。
    private var isPrivacyTab: Bool {
        if case .content(let c) = tab { return c.isPrivacy }
        return false
    }

    private var bottomArea: some View {
        // toast 用 overlay 挂在按钮区顶部，而不是和按钮一起排进 safeAreaInset：
        // safeAreaInset 是布局的一部分，toast 一出现一消失会把整页内容顶得上下跳。
        bottomBar
            .overlay(alignment: .top) {
                if let toast = toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .offset(y: -44)
                        .allowsHitTesting(false)
                }
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            if selectedIDs.isEmpty {
                Button(action: onRestart) {
                    Text("重新扫描")
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(10)
                }
                .padding(16)
            } else {
                // 隐私页签里「删除」和「隐藏」并排，先把区别写出来再让用户点。
                if isPrivacyTab {
                    Text("「删除」会进最近删除；「隐藏」只是挪进系统相簿，照片还在")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }

                HStack(spacing: 10) {
                    Button {
                        selectedIDs.removeAll()
                    } label: {
                        // 只写「取消」两个字，用户会分不清「取消本次操作」还是「取消这些选中」。
                        // 把数量写进去，按钮自己就说明了会发生什么。
                        // 隐私页签多一颗「隐藏」，横排放不下三段长文案，这里缩成「取消」。
                        Text(isPrivacyTab ? "取消" : "取消选中 \(selectedIDs.count) 张")
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(10)
                    }
                    // 文案会变（带数量），测试不能按文字点。给一个稳定标识，改文案不牵连用例。
                    .accessibilityIdentifier("action-clear-selection")

                    if isPrivacyTab {
                        Button {
                            confirmHide = true
                        } label: {
                            Text("隐藏 \(selectedIDs.count)")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.black.opacity(0.08))
                                .cornerRadius(10)
                        }
                        .accessibilityIdentifier("action-hide-selected")
                    }

                    Button {
                        performDelete()
                    } label: {
                        Text("删除 \(selectedIDs.count) 张")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                    .accessibilityIdentifier("action-delete-selected")
                }
                .padding(16)
            }
        }
        .background(Color.white)
    }

    // MARK: 行为

    private func tapRow(_ item: PhotoItem) {
        // 长按刚结束时的这次「抬手」不当作点选，避免长按看大图回来发现被勾上了
        if Date().timeIntervalSince(lastLongPressAt) < 0.6 { return }
        toggle(item.id)
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func allSelected(_ list: [PhotoItem]) -> Bool {
        guard !list.isEmpty else { return false }
        return Set(list.map { $0.id }).isSubset(of: selectedIDs)
    }

    private func toggleSelectAll(_ list: [PhotoItem]) {
        let ids = Set(list.map { $0.id })
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
            showToast("已取消本类选中")
            return
        }
        selectMany(ids)
    }

    /// 批量选中的统一入口：数量超过阈值就先确认一次，不直接落进 selectedIDs。
    private func selectMany(_ ids: Set<String>) {
        let adding = ids.subtracting(selectedIDs)
        guard !adding.isEmpty else { return }
        if adding.count > bulkConfirmThreshold {
            bulkConfirm = .select(ids: adding)
        } else {
            selectedIDs.formUnion(adding)
            showToast("已选中 \(adding.count) 张")
        }
    }

    private func ignoreBlur(_ item: PhotoItem) {
        BlurIgnoreStore.shared.add(item.id)
        ignoredBlurIDs.insert(item.id)
        selectedIDs.remove(item.id)
        showToast("这张不再算模糊，可在上方「恢复」里找回")
    }

    private func open(_ item: PhotoItem, in list: [PhotoItem]) {
        guard let idx = list.firstIndex(where: { $0.id == item.id }) else { return }
        // 列表偶尔会传进来只含这一张的数组，兜底保证预览里至少能看到它
        let payload = list.isEmpty ? [item] : list
        previewTarget = PreviewTarget(items: payload, startIndex: idx)
    }

    /// 一步删除：点一下直接调系统删除，只剩 iOS 自己那一次确认。
    /// 选中的照片可以来自不同分类 / 不同筛选，统一按 id 还原成真实对象再删。
    /// 但「一次删几百上千张」不再一步到底：先让用户确认一遍，再交给 iOS 确认。
    private func performDelete() {
        guard !selectedIDs.isEmpty else { return }
        if selectedIDs.count > bulkConfirmThreshold {
            bulkConfirm = .delete
            return
        }
        reallyDelete()
    }

    /// 隐藏选中的隐私条目。隐藏 ≠ 删除：照片还在相册里，只是进了系统「已隐藏」。
    private func hideSelected() {
        let chosen = selectedIDs.compactMap { itemIndex[$0] }
        guard !chosen.isEmpty else { return }
        PhotoLibraryService.shared.setHidden(true, assets: chosen.map { $0.asset }) { success, error in
            DispatchQueue.main.async {
                if success {
                    hiddenIDs.formUnion(chosen.map { $0.id })
                    selectedIDs.subtract(Set(chosen.map { $0.id }))
                    noteHiddenCount(chosen.count)
                    showToast("已隐藏 \(chosen.count) 张 · 取消隐藏要去「照片」App 的「已隐藏」")
                } else {
                    message = "隐藏失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }

    /// 真正执行删除（二次确认之后走这里）
    private func reallyDelete() {        var chosen: [PhotoItem] = []
        for id in selectedIDs {
            if let item = itemIndex[id] {
                chosen.append(item)
            }
        }
        guard !chosen.isEmpty else { return }
        deleteItems(chosen)
    }

    private func deleteItems(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let assets = items.map { $0.asset }
        PhotoLibraryService.shared.delete(assets: assets) { success, error in
            DispatchQueue.main.async {
                if success {
                    deletedIDs.formUnion(items.map { $0.id })
                    selectedIDs.subtract(Set(items.map { $0.id }))
                    showToast("已删除 \(items.count) 张 · 30 天内在「最近删除」可恢复")
                } else {
                    message = "删除失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toast == text {
                toast = nil
            }
        }
    }

    // MARK: 附加功能

    private func startTriage() {
        let list = currentList()
        guard !list.isEmpty else {
            showToast("「\(tab.title)」里没有照片")
            return
        }
        // 隐私组在逐张过里没有缩略图那一层遮挡，不自己糊就等于绕过了「打码」这个设置
        var isPrivacyTab = false
        if case .content(let c) = tab { isPrivacyTab = c.isPrivacy }
        triage = TriageRequest(
            title: tab.title,
            items: list,
            progressKey: triageKey,
            blurred: isPrivacyTab && blurPrivacyThumbnails,
            isPrivacy: isPrivacyTab
        )
    }

    private func loadAlbums() {
        guard albumOptions.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = PhotoLibraryService.shared.fetchUserAlbums()
            let options = list.map { AlbumOption(id: $0.id, title: $0.title, count: $0.count) }
            DispatchQueue.main.async {
                albumOptions = options
            }
        }
    }

    private func reloadAlbumIDs(_ choice: AlbumOption?) {
        guard let choice = choice else {
            albumIDs = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = PhotoLibraryService.shared.assetIDs(inAlbum: choice.id)
            DispatchQueue.main.async {
                albumIDs = ids
            }
        }
    }

    private func startCompress(_ item: PhotoItem) {
        compressingID = item.id
        VideoCompressor.shared.compress(asset: item.asset) { result in
            compressingID = nil
            switch result {
            case .success(let outcome):
                let old = outcome.oldSize
                let new = outcome.newSize
                if old <= 0 {
                    if new > 0 {
                        if outcome.originalDeleted {
                            deletedIDs.insert(item.id)
                            selectedIDs.remove(item.id)
                        }
                        showToast("已压缩到 " + byteText(new))
                    }
                } else if new <= 0 || new >= Int64(Double(old) * 0.97) {
                    showToast("这段已经很省空间了，压缩不划算，已保留原片")
                } else {
                    if outcome.originalDeleted {
                        deletedIDs.insert(item.id)
                        selectedIDs.remove(item.id)
                    }
                    let saved = Int(Double(old - new) / Double(old) * 100)
                    var text = "已压缩 " + byteText(old) + " → " + byteText(new) + "，省 \(saved)%"
                    if !outcome.originalDeleted {
                        text += "；原片没删掉，请手动删"
                    }
                    showToast(text)
                }
            case .failure(let error):
                message = "压缩失败：" + error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var compressingOverlay: some View {
        if compressingID != nil {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("正在压缩视频…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                    Text("大视频要几分钟，别锁屏、别切走")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(26)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
            }
        }
    }
}

// MARK: - 后台内容识别的进度条

/// 结果页顶上那一条「正在识别分类」。
///
/// 它自己订阅进度对象，所以百分比每变一次只重画这一行，
/// 不会把下面两万多条的列表一起刷新。
struct RefineBanner: View {
    @ObservedObject var status: RefineStatus

    private var title: String {
        if status.isFaceRefine {
            return status.total > 0
                ? "正在复核合照 \(status.percent)%（\(status.done)/\(status.total)）"
                : "正在复核合照…"
        }
        if status.total > 0 {
            return "\(status.backfill ? "正在补扫分类" : "正在识别分类") \(status.percent)%（\(status.done)/\(status.total)）"
        }
        return status.backfill ? "正在补扫分类…" : "正在识别分类…"
    }

    private var detail: String {
        if status.isFaceRefine {
            return "在更高分辨率上重数人脸，把远景合影从单人照里挑出来；其余分类已经可用"
        }
        return status.backfill
            ? "新版本多了识别信号，只重判截图/文档/其他/二维码；其余分类不受影响"
            : "重复、相似、模糊已经算完，可以先动手；识别完会自动补上内容分类"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.18, green: 0.49, blue: 0.96).opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 逐张过入口条（清理页与分类页共用）

/// 一条「逐张过 N 项」的入口。
///
/// 抽出来是为了让两个入口**长得一样、说得一样、跳得一样**。
/// 之前只有清理页有，分类页要加的时候如果复制一份，两边文案迟早会分叉。
///
/// 有进度时右侧从「左右滑快速筛」变成「已看 138 · 继续」：
/// 用户需要知道点进去不会又从第一张开始。
struct TriageEntryBar: View {
    let count: Int
    let judgedCount: Int
    let action: () -> Void

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 12))
                Text("逐张过")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count) 项")
                    .font(.system(size: 13))

                Spacer(minLength: 4)

                if judgedCount > 0 {
                    Text("已看 \(min(judgedCount, count)) · 继续")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(blue)
                } else {
                    Text("左右滑快速筛")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white)
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Maestro 按文字点，而这一行里有三个 Text。给整行一个精确的 label，
        // 用例里的 `tapOn: "逐张过"` 才能全字命中（改文案时记得同批改 flow）。
        .accessibilityLabel("逐张过")
        .accessibilityIdentifier("triage-start")
    }
}

// MARK: - 分组里的可勾选缩略图

struct SelectableThumb: View {
    let item: PhotoItem
    let isSelected: Bool
    var size: CGFloat = 96
    /// 右上角是否画一个放大角标。
    /// 分组卡片（重复 / 相似）里只有长按手势，界面上没有任何可见入口，
    /// 用户根本不知道能放大——长按是隐藏技能，不能当主入口用。
    var showsZoomBadge: Bool = false
    /// 隐私组的缩略图要不要先糊掉。由调用方算好传进来——
    /// 这个 struct 不读 UserDefaults，免得每个缩略图都去查一次。
    var blurred: Bool = false
    let onOpen: () -> Void
    let onToggle: () -> Void

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PhotoThumbView(asset: item.asset, size: size, blurred: blurred)

            if isSelected {
                Rectangle()
                    .fill(blue.opacity(0.30))
                    .frame(width: size, height: size)
                ZStack {
                    Circle().fill(blue).frame(width: 19, height: 19)
                    Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 19, height: 19)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(4)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? blue : Color.clear, lineWidth: 2.5)
        )
        .cornerRadius(8)
        .overlay(
            Group {
                if showsZoomBadge {
                    // 用 Button 而不是再挂一个 onTapGesture：手势会和下面的「点一下选中」抢，
                    // 点放大变成又选中又弹窗。
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("放大 " + item.displayName)
                    .accessibilityIdentifier("zoom-" + item.displayName)
                }
            },
            alignment: .topTrailing
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onToggle)
        .onLongPressGesture(minimumDuration: 0.35, perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("照片 " + item.displayName)
        .accessibilityIdentifier("thumb-" + item.displayName)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 缩略图

/// 隐私分组的缩略图是否默认打码。
///
/// **当前关闭**：要逐张核对「隐私」组的误报（533 张），糊着看不清就没法判断。
/// 校准完把这里改回 `true` 即可，三个调用点都不用动。
struct PhotoThumbView: View {
    let asset: PHAsset
    /// nil 表示铺满父容器（网格用）
    var size: CGFloat? = nil
    /// 隐私分组里的缩略图先糊掉，点开才看原图。
    /// 目的不是防别人，是防自己当着别人的面滑相册。
    var blurred: Bool = false

    @State private var image: UIImage?

    private var isVideo: Bool { asset.mediaType == .video }
    private var isLivePhoto: Bool { asset.mediaSubtypes.contains(.photoLive) }

    private var durationLabel: String {
        let total = Int(asset.duration.rounded())
        guard total > 0 else { return "" }
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.06)
                .overlay(
                    Group {
                        if let image = image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: blurred ? 16 : 0)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }
                    }
                )

            // 视频角标：图标 + 时长，避免只靠颜色区分
            if isVideo {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .bold))
                    Text(durationLabel.isEmpty ? "视频" : durationLabel)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(4)
            } else if isLivePhoto {
                // Live 角标和视频角标占同一个位置：一张素材不可能既是视频又是 Live，
                // 所以不会撞。放左下角是因为右上角要留给「放大」按钮、右下角留给选中勾。
                HStack(spacing: 3) {
                    Image(systemName: "livephoto")
                        .font(.system(size: 8, weight: .bold))
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.3)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(size == nil ? 0 : 8)
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let assetRef = asset
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PhotoLibraryService.shared.listThumbnail(for: assetRef)
            DispatchQueue.main.async {
                self.image = img
            }
        }
    }
}

// MARK: - 扫描期间保持屏幕常亮

/// 用 `ProcessInfo.beginActivity` 占住「屏幕别自动锁」这件事。
///
/// 为什么不是只写一句 `UIApplication.shared.isIdleTimerDisabled = true`：
/// 那是个全局开关，谁都能把它改回去，而且只要有一条退出路径漏了「关掉」这一步，
/// 扫描结束很久之后屏幕还在常亮、白耗电。beginActivity 返回一个凭证，由我们自己持有、
/// 成对释放，作用域清楚，也不怕被别处覆盖。
///
/// 生效条件是「正在扫描」且「App 在前台」两件事同时成立：切到后台就主动松开
/// （后台本来也不该占这个资源），回到前台如果还在扫则重新占上。
final class ScreenAwake {

    static let shared = ScreenAwake()

    private var token: NSObjectProtocol?
    private var wanted = false
    private var appActive = true

    private init() {}

    func setScanning(_ on: Bool) {
        runOnMain {
            self.wanted = on
            self.apply()
        }
    }

    func setAppActive(_ on: Bool) {
        runOnMain {
            self.appActive = on
            self.apply()
        }
    }

    private func apply() {
        let shouldHold = wanted && appActive

        if shouldHold, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "正在扫描相册，请不要让屏幕自动锁定"
            )
            UIApplication.shared.isIdleTimerDisabled = true
            NSLog("[PhotoOrganizer][Scan] 屏幕常亮：开")
        } else if !shouldHold, token != nil {
            releaseToken()
            NSLog("[PhotoOrganizer][Scan] 屏幕常亮：关")
        }
    }

    private func releaseToken() {
        if let token = token {
            ProcessInfo.processInfo.endActivity(token)
        }
        token = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

// MARK: - 底部 Tab（build 20）

enum MainTab: String, CaseIterable, Identifiable {
    case clean = "清理"
    case categories = "分类"
    case space = "空间"
    case me = "我的"

    var id: String { rawValue }

    /// 给 UI 用例用的稳定标识。故意用 ASCII：Maestro 里按 id 定位，
    /// 中文标签随时可能改，id 不能跟着改。
    var key: String {
        switch self {
        case .clean: return "clean"
        case .categories: return "categories"
        case .space: return "space"
        case .me: return "me"
        }
    }

    var icon: String {
        switch self {
        case .clean: return "sparkles"
        case .categories: return "square.grid.2x2"
        case .space: return "internaldrive"
        case .me: return "person.crop.circle"
        }
    }
}

/// 结果页 + 空间 + 分类 + 我的，四个页面共用一份状态。
///
/// 为什么不用系统 `TabView`：它会在切走的一瞬间销毁页面，
/// `selectedIDs` / 滚动位置 / 筛选条件全丢——而「切分类不丢选中」是这个 App 承诺过的行为。
/// 这里用 ZStack + opacity 让四个页面常驻，切换只是显隐。
struct MainTabView: View {
    let result: AnalysisResult
    let isRefining: Bool
    /// 人脸复核还在跑。单独一个 Bool 而不是直接读 `refineStatus.isFaceRefine`：
    /// ResultView 是 `let refineStatus`（不订阅），读它不会触发重画，横幅会不出现；
    /// 改成 @ObservedObject 又会让两万多条的列表跟着每次进度回调一起重画。
    let isFaceRefining: Bool
    let refineStatus: RefineStatus
    let onRestart: () -> Void

    @State private var tab: MainTab = .clean
    @State private var deletedIDs: Set<String> = []
    /// 刚被「隐藏」的照片。和 `deletedIDs` 分开记：
    /// 隐藏不释放空间，混进已删除集合会让空间页的「已释放」虚高。
    @State private var hiddenIDs: Set<String> = []
    @State private var requestedTab: ResultTab?

    var body: some View {
        ZStack {
            ResultView(
                result: result,
                isRefining: isRefining,
                isFaceRefining: isFaceRefining,
                refineStatus: refineStatus,
                deletedIDs: $deletedIDs,
                hiddenIDs: $hiddenIDs,
                requestedTab: $requestedTab,
                onRestart: onRestart
            )
            .opacity(tab == .clean ? 1 : 0)
            .allowsHitTesting(tab == .clean)
            .accessibilityHidden(tab != .clean)

            CategoryOverviewView(result: result, refineStatus: refineStatus, deletedIDs: $deletedIDs, hiddenIDs: $hiddenIDs)
                .opacity(tab == .categories ? 1 : 0)
                .allowsHitTesting(tab == .categories)
                .accessibilityHidden(tab != .categories)

            SpaceDashboardView(
                totalBytes: stats.totalBytes,
                photoBytes: stats.photoBytes,
                videoBytes: stats.videoBytes,
                suggestedBytes: stats.suggestedBytes,
                duplicateWasteBytes: stats.duplicateWasteBytes,
                freedBytes: stats.freedBytes,
                deletedCount: stats.deletedCount,
                categoryRows: stats.categoryRows,
                onGoLarge: {
                    requestedTab = .large
                    tab = .clean
                }
            )
            .opacity(tab == .space ? 1 : 0)
            .allowsHitTesting(tab == .space)
            .accessibilityHidden(tab != .space)

            SettingsTabView(onRestart: onRestart, photoCount: result.items.count)
                .opacity(tab == .me ? 1 : 0)
                .allowsHitTesting(tab == .me)
                .accessibilityHidden(tab != .me)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainTabBar(selection: $tab)
        }
    }

    private var stats: SpaceStats {
        SpaceStats(result: result, deletedIDs: deletedIDs)
    }
}

// MARK: - 底部 tab bar

struct MainTabBar: View {
    @Binding var selection: MainTab

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { item in
                Button {
                    selection = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: selection == item ? .semibold : .regular))
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(selection == item ? blue : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityIdentifier("tab-" + item.key)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 2)
        .background(
            Color.white
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black.opacity(0.07))
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - 分类总览（底部「分类」tab）

struct CategoryOverviewView: View {
    let result: AnalysisResult
    /// 用 @ObservedObject 而不是 let：补扫时百分比每变一次都要重画卡片。
    /// 传 let 进来只会拿到进页面那一刻的快照，卡片上的数字永远停在 0%。
    @ObservedObject var refineStatus: RefineStatus
    @Binding var deletedIDs: Set<String>
    @Binding var hiddenIDs: Set<String>

    /// 和「清理」页读同一个键：这边关掉，那边的两个隐私页签也一起消失
    @AppStorage("showPrivacyCategory") private var showPrivacyCategory: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按内容分类")
                            .font(.system(size: 20, weight: .semibold))
                        Text("点一张卡片，进这一类里逐张看、整批挑")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        reconcileRow
                    }
                    .padding(.top, 6)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ContentCategory.allCases.filter { !$0.isPrivacy || showPrivacyCategory }) { category in
                            let items = alive(category)
                            NavigationLink(value: category) {
                                categoryCard(
                                    category,
                                    count: items.count,
                                    bytes: items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) },
                                    refilling: refineStatus.backfill && category.isSoftCategory,
                                    verifying: refineStatus.isFaceRefine
                                        && (category == .singlePerson || category == .groupPhoto)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.96, green: 0.96, blue: 0.97))
            .toolbar(.hidden, for: .navigationBar)
            // 1.5 之前这里是「点卡片 → 切到清理 tab」。那等于把用户扔到另一个
            // 上下文里，而且回不去（分类 tab 已经不在栈上）。现在改成在这个
            // tab 里往下推一层：iOS 的惯例是每个 tab 有自己的导航栈，
            // 「返回」永远回到刚才那张卡片墙。
            .navigationDestination(for: ContentCategory.self) { category in
                CategoryDetailView(
                    category: category,
                    items: result.categoryBuckets[category] ?? [],
                    deletedIDs: $deletedIDs,
                    hiddenIDs: $hiddenIDs
                )
            }
        }
    }

    private func alive(_ category: ContentCategory) -> [PhotoItem] {
        (result.categoryBuckets[category] ?? []).filter {
            !deletedIDs.contains($0.id) && !hiddenIDs.contains($0.id)
        }
    }

    /// 当前还在相册里的素材总数（扣掉这一轮刚删的、刚隐藏的）。
    private var liveTotal: Int {
        result.items.filter {
            !deletedIDs.contains($0.id) && !hiddenIDs.contains($0.id)
        }.count
    }

    /// 界面上这些卡片的数字之和。和 `liveTotal` 对上，就说明「互斥且完整」——
    /// 每张素材只落一个桶，一张不落、一张不重。
    private var visibleSum: Int {
        ContentCategory.allCases
            .filter { !$0.isPrivacy || showPrivacyCategory }
            .reduce(0) { $0 + alive($1).count }
    }

    /// 对账行：把「加起来等不等于相册」直接写在页面上。
    ///
    /// 以前用户只能自己按计算器，对不上还会以为程序漏了照片；
    /// 实际最常见的差额是**隐私两张卡被设置开关藏起来了**（默认就是关的）。
    /// 与其写在文档里，不如挂在这里——差多少、差在哪，一眼看到。
    @ViewBuilder
    private var reconcileRow: some View {
        let total = liveTotal
        let sum = visibleSum
        let diff = total - sum

        HStack(spacing: 5) {
            Image(systemName: diff == 0 ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(diff == 0 ? Color(red: 0.2, green: 0.6, blue: 0.4) : Color(red: 0.75, green: 0.5, blue: 0.2))
            Text(reconcileText(total: total, sum: sum, diff: diff))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func reconcileText(total: Int, sum: Int, diff: Int) -> String {
        if diff == 0 {
            return "合计 \(sum) 项，和相册里的 \(total) 项完全对上"
        }
        if !showPrivacyCategory {
            return "合计 \(sum) 项，还差 \(diff) 项在隐私分类里（设置里打开「隐私分类」就能看到）"
        }
        return "合计 \(sum) 项，相册 \(total) 项，差 \(diff) 项"
    }

    private func categoryCard(
        _ category: ContentCategory,
        count: Int,
        bytes: Int64,
        refilling: Bool,
        verifying: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color(for: category))
                Spacer()
                // 补扫中就把数字换成百分比：这一类的旧结论正在被推翻重判，
                // 此时显示「0」是在撒谎——不是没有，是还没算完。
                // 人脸复核同理：数字马上会变，先别给一个会被打脸的数。
                if refilling {
                    Text("\(refineStatus.percent)%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(color(for: category))
                } else if verifying {
                    Text("复核中")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color(for: category))
                } else {
                    Text("\(count)")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(count == 0 ? Color.secondary.opacity(0.5) : .primary)
                }
            }
            Text(category.rawValue)
                .font(.system(size: 14, weight: .medium))
            Text(refilling ? "补扫中…" : (verifying ? "重数人脸…" : (count == 0 ? "暂无" : byteText(bytes))))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .cornerRadius(14)
    }

    private func color(for category: ContentCategory) -> Color {
        switch category {
        case .receipt: return Color(red: 0.2, green: 0.55, blue: 0.4)
        case .qrCode: return Color(red: 0.15, green: 0.45, blue: 0.6)
        case .document: return Color(red: 0.35, green: 0.45, blue: 0.55)
        case .screenshot: return Color(red: 0.4, green: 0.45, blue: 0.5)
        case .singlePerson: return Color(red: 0.85, green: 0.45, blue: 0.4)
        case .groupPhoto: return Color(red: 0.88, green: 0.6, blue: 0.32)
        case .food: return Color(red: 0.9, green: 0.55, blue: 0.2)
        case .scenery: return Color(red: 0.25, green: 0.6, blue: 0.5)
        case .pet: return Color(red: 0.55, green: 0.42, blue: 0.3)
        case .privacy: return Color(red: 0.6, green: 0.35, blue: 0.6)
        case .privacyVideo: return Color(red: 0.45, green: 0.35, blue: 0.62)
        case .video: return Color(red: 0.25, green: 0.42, blue: 0.68)
        case .other: return Color(red: 0.5, green: 0.5, blue: 0.55)
        }
    }
}

// MARK: - 分类详情（从分类卡片推一层进来）

/// 在「分类」tab 里就地看这一类，不再跳到「清理」。
///
/// 为什么不做成一个独立 tab、也不用 sheet：
/// - sheet 是「临时任务」，看完要关掉；用户在这里是**浏览一整类**，需要能往下滚很久；
/// - 独立 tab 会让底部变成 5 项，而这一页在语义上就是「分类」的子页，不是平级栏目。
/// 每个 tab 一个导航栈，是 iOS 从 iPhone OS 1.0 就在用的模型，返回永远回到卡片墙。
/// 视频详情页的体积筛选。
///
/// 为什么不把「大视频 / 小视频」拆成两张分类卡：那样一个视频既是「大视频」
/// 又是「视频」，互斥性就破了，后面的统计全乱。体积是类内的属性，不是分类。
enum VideoSizeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case large = "≥100MB"
    case small = "<100MB"

    var id: String { rawValue }

    func matches(_ bytes: Int64) -> Bool {
        let mb: Int64 = 1024 * 1024
        switch self {
        case .all: return true
        case .large: return bytes >= 100 * mb
        case .small: return bytes < 100 * mb
        }
    }
}

struct CategoryDetailView: View {
    let category: ContentCategory
    let items: [PhotoItem]
    @Binding var deletedIDs: Set<String>
    /// 这次运行里刚被「隐藏」的 id。隐藏不是删除，所以不能混进 `deletedIDs`
    /// （那个集合会被空间页算成已释放空间），但界面上要从列表里消失。
    @Binding var hiddenIDs: Set<String>

    @AppStorage("blurPrivacyThumbnails") private var blurPrivacyThumbnails: Bool = true

    @State private var selected: Set<String> = []
    @State private var previewTarget: PreviewTarget?
    @State private var triage: TriageRequest?
    @State private var message: String?
    @State private var toast: String?
    @State private var videoFilter: VideoSizeFilter = .all
    @State private var confirmHide = false

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    /// 3 列固定边长，和「清理」页三列布局用同一套算法，两边格子大小一致
    private var cellSide: CGFloat {
        let w = UIScreen.main.bounds.width
        return max(60, (w - 24 - 12) / 3)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSide), spacing: 6), count: 3)
    }

    private var alive: [PhotoItem] {
        var base = items.filter { !deletedIDs.contains($0.id) && !hiddenIDs.contains($0.id) }
        guard category == .video else { return base }
        base = base.filter { videoFilter.matches(max(0, $0.fileSize)) }
        // 「挑大视频」是这一页唯一的目的，默认就该大的在前，
        // 而不是按相册时间轴让人翻半天。
        return base.sorted { max(0, $0.fileSize) > max(0, $1.fileSize) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if category.isPrivacy {
                    Text(privacyNote)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .cornerRadius(10)
                }

                if category == .video && !items.isEmpty {
                    Picker("体积", selection: $videoFilter) {
                        ForEach(VideoSizeFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("video-size-filter")

                    Text("\(alive.count) 段 · \(byteText(alive.reduce(Int64(0)) { $0 + max(0, $1.fileSize) })) · 按体积从大到小")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                if alive.isEmpty {
                    Text(category == .video && videoFilter != .all
                         ? "这个体积区间里没有视频，换个筛选看看"
                         : "这一类里没有内容了")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    // 和清理页同一条入口、同一份代码。传的是 alive（已过滤的当前列表），
                    // 视频分类带着当前体积筛选——选了「≥100MB」就只过这些。
                    TriageEntryBar(
                        count: alive.count,
                        judgedCount: TriageProgressStore.shared.judgedCount(for: triageKey)
                    ) {
                        triage = TriageRequest(
                            title: category.rawValue,
                            items: alive,
                            progressKey: triageKey,
                            blurred: category.isPrivacy && blurPrivacyThumbnails,
                            isPrivacy: category.isPrivacy
                        )
                    }
                    .padding(.bottom, 2)

                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(alive) { item in
                            SelectableThumb(
                                item: item,
                                isSelected: selected.contains(item.id),
                                size: cellSide,
                                showsZoomBadge: true,
                                blurred: blurPrivacyThumbnails && category.isPrivacy,
                                onOpen: { open(item) },
                                onToggle: { toggle(item) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
        .navigationTitle(category.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selected.count == alive.count && !alive.isEmpty ? "取消全选" : "全选") {
                    if selected.count == alive.count {
                        selected.removeAll()
                    } else {
                        selected = Set(alive.map { $0.id })
                    }
                }
                .font(.system(size: 14))
                .accessibilityIdentifier("category-select-all")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty {
                deleteBar
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 22)
                    .allowsHitTesting(false)
            }
        }
        .alert("隐藏这 \(selected.count) 项？", isPresented: $confirmHide) {
            Button("取消", role: .cancel) {}
            Button("隐藏") { hideSelected() }
        } message: {
            Text("它们会被移到系统「已隐藏」相簿，并从本 App 里消失，打开要 Face ID。注意：iOS 16 起 App 读不到那个相簿，**取消隐藏只能去「照片」App 手动操作**。")
        }
        .alert("出错了", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .fullScreenCover(item: $previewTarget) { target in
            PhotoPreviewView(
                items: target.items,
                startIndex: target.startIndex,
                selectedIDs: $selected
            ) { item in
                delete([item])
            }
        }
        .sheet(item: $triage) { request in
            SwipeTriageView(
                title: request.title,
                progressKey: request.progressKey,
                items: request.items,
                blurred: request.blurred,
                isPrivacy: request.isPrivacy,
                onFinish: { marks in
                    guard !marks.isEmpty else { return }
                    selected.formUnion(marks)
                    showToast("已选 \(marks.count) 项 · 可以删除，也可以隐藏")
                },
                onDeleteMany: { items in
                    delete(items)
                },
                onHide: { item in
                    hiddenIDs.insert(item.id)
                    selected.remove(item.id)
                    showToast("已隐藏 1 项 · 去「照片」App 的「已隐藏」可取消")
                }
            )
        }
    }

    /// 和清理页的同一个内容分类共用一把 key：在清理页判过的，
    /// 到分类页不会从头再问一遍，反过来也一样。
    private var triageKey: String {
        "cat." + category.rawValue
    }

    private var privacyNote: String {
        if category == .privacyVideo {
            return "视频的判定和照片同一套口径：抽 1~3 帧，看人体区域里排除头部后还剩多少裸露皮肤。封面不含人像的视频不会补抽帧，所以片头是黑场的那种可能漏。这一组不进「建议清理」，全选也带不走。"
        }
        return "判定口径是「排除人脸之后、身体上还剩多少裸露皮肤」。只露头的照片、证件照不会进这一组。这一组不进「建议清理」，全选也带不走。"
    }

    private var deleteBar: some View {
        VStack(spacing: 0) {
            // 选中之后「删除」和「隐藏」并排，用户会问「到底是要删还是要藏」。
            // 一句话把两个动作的区别摆出来，比改按钮文案省地方。
            if category.isPrivacy {
                Text("「删除」会进最近删除；「隐藏」只是挪进系统相簿，照片还在")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button {
                    selected.removeAll()
                } label: {
                    Text("取消选中")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                // 隐藏只对隐私组出现：这里误点一次就是把照片从 App 里「弄丢」，
                // 普通分类里放这颗按钮没有意义，只会增加误触。
                if category.isPrivacy {
                    Button {
                        confirmHide = true
                    } label: {
                        Text("隐藏 \(selected.count)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.06))
                            .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("category-hide")
                }

                Button {
                    let chosen = alive.filter { selected.contains($0.id) }
                    delete(chosen)
                } label: {
                    Text("删除 \(selected.count) 项")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.85, green: 0.25, blue: 0.2))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-delete")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(
            Color.white
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: 行为

    private func toggle(_ item: PhotoItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    private func open(_ item: PhotoItem) {
        let list = alive
        guard let idx = list.firstIndex(where: { $0.id == item.id }) else { return }
        previewTarget = PreviewTarget(items: list, startIndex: idx)
    }

    private func delete(_ chosen: [PhotoItem]) {
        guard !chosen.isEmpty else { return }
        PhotoLibraryService.shared.delete(assets: chosen.map { $0.asset }) { success, error in
            DispatchQueue.main.async {
                if success {
                    deletedIDs.formUnion(chosen.map { $0.id })
                    selected.subtract(Set(chosen.map { $0.id }))
                    showToast("已删除 \(chosen.count) 项 · 30 天内在「最近删除」可恢复")
                } else {
                    message = "删除失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }

    /// 隐藏 ≠ 删除：照片还在相册里，只是进了系统「已隐藏」相簿。
    /// 所以这里记进 `hiddenIDs` 而不是 `deletedIDs`——后者会被「空间」页
    /// 当成已释放的空间算进去，那是在骗人。
    private func hideSelected() {
        let chosen = alive.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        PhotoLibraryService.shared.setHidden(true, assets: chosen.map { $0.asset }) { success, error in
            DispatchQueue.main.async {
                if success {
                    hiddenIDs.formUnion(chosen.map { $0.id })
                    selected.subtract(Set(chosen.map { $0.id }))
                    noteHiddenCount(chosen.count)
                    showToast("已隐藏 \(chosen.count) 项 · 取消隐藏要去「照片」App 的「已隐藏」")
                } else {
                    message = "隐藏失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toast == text { toast = nil }
        }
    }
}

// MARK: - 我的

struct SettingsTabView: View {
    let onRestart: () -> Void
    let photoCount: Int

    /// 两个隐私开关。用 @AppStorage 而不是本地 @State：
    /// 「清理」页也要读同一个键，否则设置改完回去不生效。
    @AppStorage("showPrivacyCategory") private var showPrivacyCategory: Bool = false
    @AppStorage("blurPrivacyThumbnails") private var blurPrivacyThumbnails: Bool = true

    @Environment(\.scenePhase) private var scenePhase

    @State private var cacheBytes: Int64 = 0
    @State private var permissionText: String = "未知"
    @State private var confirmClearCache = false
    @State private var toast: String?
    @State private var showTutorial = false
    @State private var showHidden = false
    /// 「关于 › 网络与 iCloud」里重看首启那段说明
    @State private var showCloudNotice = false

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("我的")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                // MARK: 显示与内容
                sectionTitle("显示与内容")
                card {
                    toggleRow(
                        icon: "eye.slash",
                        title: "显示隐私分类",
                        subtitle: "关掉后，隐私页签和分类卡片都不再出现。照片还在相册里，只是这里不展示。",
                        isOn: $showPrivacyCategory
                    )

                    divider

                    toggleRow(
                        icon: "eye.slash.fill",
                        title: "隐私分类模糊显示",
                        subtitle: "打开后，隐私组的缩略图先糊掉，点开大图才看清。",
                        isOn: $blurPrivacyThumbnails
                    )
                    .disabled(!showPrivacyCategory)
                    .opacity(showPrivacyCategory ? 1 : 0.4)

                    divider

                    // 隐藏只对隐私组开放，但「找回」必须全局可达：
                    // 万一误点，用户得有个地方把照片捞回来，否则等于永久弄丢。
                    Button {
                        showHidden = true
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已隐藏的照片")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text("隐藏过的都在系统「已隐藏」里；iOS 16 起 App 读不到，只能去那边取消")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-hidden")
                }

                // MARK: 数据与存储
                sectionTitle("数据与存储")
                card {
                    infoRow(title: "扫描缓存", value: byteText(cacheBytes))
                    divider
                    Button {
                        confirmClearCache = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("清除扫描缓存")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text("下次扫描会重新分析所有照片，不会删任何照片")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-clear-cache")

                    divider

                    Button {
                        onRestart()
                    } label: {
                        HStack {
                            Text("重新扫描")
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-rescan")
                }

                // MARK: 帮助与支持
                sectionTitle("帮助与支持")
                card {
                    Button {
                        showTutorial = true
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("新手教程")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text("5 页，90 秒：扫描、读数字、选中、逐张过、四个 tab")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("tutorial-open")

                    divider

                    Button {
                        openMailFeedback()
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("邮件反馈")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text("把问题和版本号一起发来，方便定位")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-feedback")
                }

                // MARK: 常见问题
                sectionTitle("常见问题")
                card {
                    faqRow(q: "扫描会上传我的照片吗？", a: "不会。所有识别都在手机本地完成：没有服务器、没有上传、没有账号。")
                    divider
                    faqRow(q: "「建议清理 80%」是什么意思？", a: "是可疑度，不是删除概率。80% 只表示同时命中了几个可疑特征，不代表八成该删。")
                    divider
                    faqRow(q: "删错了能找回吗？", a: "能。删除是删到系统「最近删除」，30 天内在照片 App 里可以恢复。")
                    divider
                    faqRow(q: "「隐藏」和「删除」有什么区别？", a: "隐藏不删照片，只是放进系统「已隐藏」相簿（有 Face ID 锁），占用空间不变。但 iOS 16 起 Apple 不让第三方 App 读那个相簿，所以取消隐藏只能去「照片」App 手动操作。删除会进「最近删除」，30 天内可恢复。")
                    divider
                    faqRow(q: "隐私分类为什么有误判？", a: "隐私是概率粗筛（排除人脸后的裸露密度），分不清泳装和内衣。它不进建议清理，全选也带不走。")
                    divider
                    faqRow(q: "第二次扫描为什么快？", a: "没改过的照片直接读上次结果（增量缓存），所以只要几十秒。")
                }

                // MARK: 系统权限
                sectionTitle("系统权限")
                card {
                    infoRow(title: "相册权限", value: permissionText)
                    divider
                    Button {
                        openSystemSettings()
                    } label: {
                        HStack {
                            Text("去系统设置里修改")
                                .font(.system(size: 15))
                                .foregroundColor(blue)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13))
                                .foregroundColor(blue)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-open-permission")
                }

                // MARK: 关于
                sectionTitle("关于")
                card {
                    infoRow(title: "版本", value: appVersionLine())
                    divider
                    infoRow(title: "这次分析", value: "\(photoCount) 项")
                    divider
                    infoRow(title: "照片处理", value: "全部在本机")
                    divider
                    // 「照片不上传」这句话只在首启说一次不够——想确认的人得能找到。
                    // 这里放常驻入口，重看同一张卡（`CloudNoticeCard`），文案只有一份。
                    Button {
                        showCloudNotice = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("网络与 iCloud")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text("为什么要联网、照片会不会被上传")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-cloud-notice")
                }

                Text("所有识别都在手机本地完成：没有服务器、没有上传、没有账号。删掉的照片进系统「最近删除」，30 天内可以恢复。\n\n判定口径：重复=原图哈希相同；相似=缩略图感知哈希接近；模糊=清晰度低于全库中位数；隐私=排除人脸后的裸露密度。误判永远会有，最终点删除的永远是你自己。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
        .onAppear(perform: refresh)
        .sheet(isPresented: $showTutorial) {
            TutorialView(hasScanned: photoCount > 0)
        }
        .sheet(isPresented: $showHidden) {
            HiddenAssetsView()
        }
        .sheet(isPresented: $showCloudNotice) {
            CloudNoticeSheet()
        }
        .onChange(of: scenePhase) { phase in
            // 从系统设置改完权限回来，数字要跟着变
            if phase == .active { refresh() }
        }
        .confirmationDialog(
            "清除扫描缓存？",
            isPresented: $confirmClearCache,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                ScanCache.shared.clear()
                refresh()
                showToast("缓存已清除")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删掉本地的分析结果，不会删任何照片。下次扫描会从头分析一遍，可能要十几分钟。")
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 4)
            .padding(.top, 10)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .cornerRadius(14)
    }

    private var divider: some View {
        Divider().padding(.leading, 38)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(blue)
        }
        .padding(.vertical, 12)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func faqRow(q: String, a: String) -> some View {
        DisclosureGroup {
            Text(a)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .padding(.trailing, 4)
        } label: {
            Text(q)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .padding(.vertical, 8)
        }
    }

    // MARK: 行为

    private func refresh() {
        cacheBytes = ScanCache.shared.diskUsage()

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized: permissionText = "全部照片"
        case .limited: permissionText = "仅选中的照片"
        case .denied: permissionText = "已拒绝"
        case .restricted: permissionText = "受限制"
        case .notDetermined: permissionText = "未询问"
        @unknown default: permissionText = "未知"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openMailFeedback() {
        let version = appVersionLine()
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "eddie.wu@qq.com"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "PhotoOrganizer 反馈（\(version)）"),
            URLQueryItem(name: "body", value: "\n\n\n——\n版本：\(version)")
        ]
        guard let url = comps.url else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            showToast("没有配置邮件账户，可直接发到 eddie.wu@qq.com")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeIn(duration: 0.2)) {
                if toast == text { toast = nil }
            }
        }
    }
}

// MARK: - 已隐藏的照片（找回通道）

/// 系统「已隐藏」相簿的只读列表 + 取消隐藏。
///
/// 这个页面存在的唯一理由：隐藏按钮一旦误点，照片就从 App 里消失了。
/// 没有这个入口，用户唯一的办法是去系统相册翻「已隐藏」再一张张取消，
/// 而那个相簿本身还要 Face ID。给一条看得见的路，比事后解释有用。
struct HiddenAssetsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?

    /// 这个 App 累计隐藏过多少张。只用来区分空态文案：
    /// 从没隐藏过 → 这篇说明可以忽略；隐藏过 → 明确告诉他去系统相册找。
    /// 不能靠 `assets.isEmpty` 判断，因为 iOS 16 起**永远是空**。
    @AppStorage("hiddenEverCount") private var hiddenEverCount: Int = 0

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    private var side: CGFloat { max(72, (UIScreen.main.bounds.width - 24 - 12) / 3) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(side), spacing: 6), count: 3)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if assets.isEmpty {
                        systemLimitState
                    } else {
                        Text("系统「已隐藏」相簿里共 \(assets.count) 项。取消隐藏后会回到系统相册，重新扫描一次就会重新出现在分类里。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                Button {
                                    toggle(asset.localIdentifier)
                                } label: {
                                    HiddenThumb(
                                        asset: asset,
                                        side: side,
                                        selected: selected.contains(asset.localIdentifier)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(red: 0.96, green: 0.96, blue: 0.97))
            .navigationTitle("已隐藏的照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .font(.system(size: 14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selected.count == assets.count && !assets.isEmpty ? "取消全选" : "全选") {
                        if selected.count == assets.count && !assets.isEmpty {
                            selected.removeAll()
                        } else {
                            selected = Set(assets.map { $0.localIdentifier })
                        }
                    }
                    .font(.system(size: 14))
                    .disabled(assets.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selected.isEmpty { unhideBar }
            }
            .alert("出错了", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("知道了", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .onAppear(perform: reload)
    }

    /// 读不到内容时**不能**说「没有已隐藏的照片」。
    ///
    /// iOS 16 起，只要用户开着「用 Face ID 查看已隐藏相簿」（默认就是开的），
    /// 系统给第三方 App 返回的就是一个**空**相簿。照片还在，只是 App 拿不到。
    /// 这里必须把这条限制讲明白，并给一条能走通的出口（跳系统相册）。
    private var systemLimitState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundColor(Color(red: 0.9, green: 0.5, blue: 0.1))
                Text("照片还在，是这个 App 读不到")
                    .font(.system(size: 16, weight: .semibold))
            }

            Text("iOS 16 起，系统把「已隐藏」相簿锁在 Face ID 后面。为了不让第三方 App 绕过这把锁，Apple 直接给 App 返回一个「空」相簿——不是这里没做，是系统不允许。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            Text(hiddenEverCount > 0
                 ? "你隐藏过的 \(hiddenEverCount) 张都在「照片」App 的「已隐藏」里。取消隐藏也只能在那边操作，取消后回来重新扫一次，它们会回到分类里。"
                 : "如果你确实没隐藏过任何照片，这段话可以忽略。以后隐藏的照片都会进「照片」App 的「已隐藏」相簿。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            Button {
                openPhotosApp()
            } label: {
                Text("打开系统「照片」App")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hidden-open-photos")

            Text("在「照片」里点底部的「相簿」，往下找到「已隐藏」，用 Face ID 打开。")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(14)
        .padding(.top, 10)
    }

    /// `photos-redirect://` 是系统相册的公开入口，`open` 不需要在
    /// Info.plist 里声明 `LSApplicationQueriesSchemes`（`canOpenURL` 才需要）。
    /// 没有直达「已隐藏」相簿的 scheme，只能落到照片 App 首页再让用户点两下。
    private func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                DispatchQueue.main.async {
                    message = "打不开「照片」App，请回到主屏幕手动打开。"
                }
            }
        }
    }

    private var unhideBar: some View {
        HStack(spacing: 10) {
            Button {
                selected.removeAll()
            } label: {
                Text("取消选中")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                unhide()
            } label: {
                Text(busy ? "处理中…" : "取消隐藏 \(selected.count) 项")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(blue.opacity(busy ? 0.5 : 1))
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier("hidden-unhide")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color.white
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func reload() {
        assets = PhotoLibraryService.shared.fetchHiddenAssets()
        selected = selected.intersection(Set(assets.map { $0.localIdentifier }))
    }

    private func unhide() {
        let chosen = assets.filter { selected.contains($0.localIdentifier) }
        guard !chosen.isEmpty, !busy else { return }
        busy = true
        PhotoLibraryService.shared.setHidden(false, assets: chosen) { success, error in
            DispatchQueue.main.async {
                busy = false
                if success {
                    let ids = Set(chosen.map { $0.localIdentifier })
                    assets.removeAll { ids.contains($0.localIdentifier) }
                    selected.removeAll()
                } else {
                    message = "取消隐藏失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }
}

private struct HiddenThumb: View {
    let asset: PHAsset
    let side: CGFloat
    let selected: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.9)
                }
            }
            .frame(width: side, height: side)
            .clipped()

            if asset.mediaType == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if selected {
                ZStack {
                    Circle().fill(Color(red: 0, green: 0.48, blue: 1))
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 20, height: 20)
                .padding(5)
            }
        }
        .frame(width: side, height: side)
        .cornerRadius(8)
        .onAppear {
            guard image == nil else { return }
            PhotoLibraryService.shared.loadImage(
                for: asset,
                targetSize: CGSize(width: side * 2, height: side * 2)
            ) { img in
                guard let img = img else { return }
                DispatchQueue.main.async { image = img }
            }
        }
    }
}

func appVersionLine() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "版本 \(short)（构建号 \(build)）"
}

/// 累计隐藏过多少张。只有一个读者：`HiddenAssetsView` 的空态文案。
///
/// 为什么需要它：iOS 16 起第三方 App 读系统「已隐藏」相簿**永远是空**，
/// 所以「读到 0 条」既可能是真的没藏过，也可能是系统锁着。这个计数
/// 让我们能分清，至少别对藏过 20 张的人说「你没有隐藏过照片」。
func noteHiddenCount(_ n: Int) {
    guard n > 0 else { return }
    let key = "hiddenEverCount"
    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + n, forKey: key)
}

// MARK: - 空间统计（一份口径，两个读者）

struct SpaceStats {
    let totalBytes: Int64
    let photoBytes: Int64
    let videoBytes: Int64
    let suggestedBytes: Int64
    let duplicateWasteBytes: Int64
    let freedBytes: Int64
    let deletedCount: Int
    let categoryRows: [CatRow]

    init(result: AnalysisResult, deletedIDs: Set<String>) {
        var sizeByID: [String: Int64] = [:]
        sizeByID.reserveCapacity(result.items.count)
        for item in result.items {
            sizeByID[item.id] = max(0, item.fileSize)
        }

        var total: Int64 = 0
        var photo: Int64 = 0
        var video: Int64 = 0
        for item in result.items {
            let size = max(0, item.fileSize)
            total += size
            if item.isVideo { video += size } else { photo += size }
        }

        var suggested: Int64 = 0
        for item in result.suggestedItems {
            suggested += max(0, item.fileSize)
        }

        var waste: Int64 = 0
        for group in result.duplicateGroups {
            let sum = group.items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            let keep = group.items.first.map { max(0, $0.fileSize) } ?? 0
            waste += max(0, sum - keep)
        }

        var freed: Int64 = 0
        for id in deletedIDs {
            freed += sizeByID[id] ?? 0
        }

        var bytes: [ContentCategory: Int64] = [:]
        var counts: [ContentCategory: Int] = [:]
        for item in result.items where !item.isVideo && !deletedIDs.contains(item.id) {
            bytes[item.category, default: 0] += max(0, item.fileSize)
            counts[item.category, default: 0] += 1
        }
        var rows = bytes.map { key, value in
            CatRow(id: key.rawValue, title: key.rawValue, bytes: value, count: counts[key] ?? 0)
        }
        rows.sort { $0.bytes > $1.bytes }
        var finalRows = Array(rows.prefix(6))
        if video > 0 {
            finalRows.insert(CatRow(id: "video", title: "视频", bytes: video, count: result.videoCount), at: 0)
        }

        self.totalBytes = total
        self.photoBytes = photo
        self.videoBytes = video
        self.suggestedBytes = suggested
        self.duplicateWasteBytes = waste
        self.freedBytes = freed
        self.deletedCount = deletedIDs.count
        self.categoryRows = finalRows
    }
}
