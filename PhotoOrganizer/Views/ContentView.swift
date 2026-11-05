import SwiftUI
import Photos
import UIKit

// MARK: - 主容器

enum AppPhase {
    case idle
    case scanning
    case done
}

struct ContentView: View {
    @State private var phase: AppPhase = .idle
    @State private var result: AnalysisResult?
    @State private var progressValue: Double = 0
    @State private var progressText: String = ""
    @State private var processed: Int = 0
    @State private var total: Int = 0
    @State private var errorMessage: String?

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
                        ResultView(result: result, onRestart: reset)
                    } else {
                        HomeView(onStart: startScan)
                    }
                }
            }
            .navigationTitle("相册整理")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reset() {
        result = nil
        phase = .idle
        progressValue = 0
        progressText = ""
        processed = 0
        total = 0
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

            AnalysisEngine.shared.analyze(assets: assets) { done, all, text in
                DispatchQueue.main.async {
                    processed = done
                    total = all
                    progressText = text
                    progressValue = all > 0 ? Double(done) / Double(all) : 0
                }
            } completion: { res in
                result = res
                phase = .done
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
                    featureRow(icon: "person.fill", title: "内容分类", desc: "人物 / 美食 / 风景 / 宠物 / 截图 自动归类")
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

                Text("扫描不改动任何照片。删除一步生效，删掉的照片可在「最近删除」里 30 天内恢复。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
            }
            .padding(20)
        }
        .onAppear(perform: loadInfo)
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

            Text("这次多了一步「内容识别」，照片多的话会比之前慢一些\n别锁屏、别切走")
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
    let onRestart: () -> Void

    /// 全量 id → 照片。跨分类选中、跨分类删除都靠它，保证「切分类不丢选中」。
    private let itemIndex: [String: PhotoItem]
    /// 按体积从大到小预排好，避免每次刷新都重排几万张
    private let sortedBySize: [PhotoItem]

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    @State private var tab: ResultTab = .suggested
    @State private var selectedIDs: Set<String> = []
    @State private var deletedIDs: Set<String> = []

    /// 用「要预览的对象」来控制弹出，而不是 Bool + 三个并列状态。
    /// 后者在第一次弹出时会拿到尚未更新的空数组（SwiftUI 的呈现内容按快照捕获），
    /// 表现就是「第一次点开照片永远是空白页」。
    @State private var previewTarget: PreviewTarget?

    @State private var message: String?
    @State private var toast: String?

    // 筛选（时间段 / 相册）
    @State private var period: TimeWindow = .all
    @State private var albumChoice: AlbumOption?
    @State private var albumIDs: Set<String>?
    @State private var albumOptions: [AlbumOption] = []
    @State private var showFilter = false

    // 附加面板
    @State private var showDashboard = false
    @State private var triage: TriageRequest?

    // 视频压缩
    @State private var compressingID: String?
    @State private var confirmCompress: PhotoItem?

    // 布局 / 模糊灵敏度 / 手动排除
    @AppStorage("resultLayoutMode") private var layoutRaw: Int = 3
    @AppStorage("blurSensitivity") private var blurLevel: Int = 1
    @State private var ignoredBlurIDs: Set<String> = BlurIgnoreStore.shared.all()
    @State private var lastLongPressAt: Date = .distantPast

    init(result: AnalysisResult, onRestart: @escaping () -> Void) {
        self.result = result
        self.onRestart = onRestart
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
            toolbar

            ScrollView {
                scrollContent
            }
        }
        .overlay(alignment: .bottom) {
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
        .sheet(isPresented: $showDashboard) {
            SpaceDashboardView(
                totalBytes: totalBytes,
                photoBytes: photoBytes,
                videoBytes: videoBytes,
                suggestedBytes: suggestedBytes,
                duplicateWasteBytes: duplicateWasteBytes,
                freedBytes: freedBytes,
                deletedCount: deletedIDs.count,
                categoryRows: categoryRows,
                onGoLarge: { tab = .large }
            )
        }
        .sheet(item: $triage) { request in
            SwipeTriageView(title: request.title, items: request.items) { marks in
                guard !marks.isEmpty else { return }
                selectedIDs.formUnion(marks)
                showToast("已标记 \(marks.count) 张，点下面红色按钮统一删除")
            }
        }
        .onAppear(perform: loadAlbums)
        .animation(.easeInOut(duration: 0.2), value: toast)
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
        result.suggestedItems.filter { !deletedIDs.contains($0.id) && passes($0) }
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

    private var receiptCount: Int {
        (result.categoryBuckets[.receipt] ?? []).filter { !deletedIDs.contains($0.id) && passes($0) }.count
    }

    private func contentItems(_ category: ContentCategory) -> [PhotoItem] {
        (result.categoryBuckets[category] ?? []).filter { !deletedIDs.contains($0.id) && passes($0) }
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

    private var totalBytes: Int64 {
        result.items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    private var photoBytes: Int64 {
        result.items.filter { !$0.isVideo }.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    private var videoBytes: Int64 {
        result.items.filter { $0.isVideo }.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    private var suggestedBytes: Int64 {
        suggested.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    private var duplicateWasteBytes: Int64 {
        dupGroups.reduce(Int64(0)) { partial, group in
            let total = group.items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            let keep = group.items.first.map { max(0, $0.fileSize) } ?? 0
            return partial + max(0, total - keep)
        }
    }

    private var freedBytes: Int64 {
        deletedIDs.reduce(Int64(0)) { partial, id in
            partial + max(0, itemIndex[id]?.fileSize ?? 0)
        }
    }

    private var categoryRows: [CatRow] {
        var bytes: [ContentCategory: Int64] = [:]
        var counts: [ContentCategory: Int] = [:]
        for item in result.items where !item.isVideo && !deletedIDs.contains(item.id) {
            bytes[item.category, default: 0] += max(0, item.fileSize)
            counts[item.category, default: 0] += 1
        }
        var rows: [CatRow] = bytes.map { key, value in
            CatRow(id: key.rawValue, title: key.rawValue, bytes: value, count: counts[key] ?? 0)
        }
        rows.sort { $0.bytes > $1.bytes }
        var out = Array(rows.prefix(6))
        if videoBytes > 0 {
            out.insert(CatRow(id: "video", title: "视频", bytes: videoBytes, count: result.videoCount), at: 0)
        }
        return out
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(summaryLine)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                headerButton(icon: "chart.pie.fill", text: "空间") { showDashboard = true }
                headerButton(icon: "line.3.horizontal.decrease", text: "筛选") { showFilter = true }
                headerButton(icon: "hand.draw.fill", text: "逐张过") { startTriage() }
            }

            HStack(spacing: 8) {
                summaryItem(title: "建议清理", value: "\(suggested.count)", color: Color(red: 0.85, green: 0.25, blue: 0.2))
                summaryItem(title: "重复组", value: "\(dupGroups.count)", color: Color(red: 0.85, green: 0.45, blue: 0.15))
                summaryItem(title: "发票", value: "\(receiptCount)", color: Color(red: 0.2, green: 0.55, blue: 0.4))
                summaryItem(title: "截图", value: "\(shots.count)", color: Color(red: 0.4, green: 0.45, blue: 0.5))
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
                        Text("清空")
                            .font(.system(size: 11, weight: .medium))
                    }
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

    private func headerButton(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
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
                 ? "原图文件字节完全一致（已逐张核对）"
                 : "内容接近但不完全相同")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.items) { item in
                        SelectableThumb(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            size: 96,
                            onOpen: { open(item, in: group.items) },
                            onToggle: { toggle(item.id) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button {
                    selectedIDs.formUnion(group.items.dropFirst().map { $0.id })
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
            thumb(item, size: 78, selected: selected)

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

            previewButton(item, in: list)
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
            PhotoThumbView(asset: item.asset)

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
                .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selected {
                checkBadge
                    .padding(5)
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
            PhotoThumbView(asset: item.asset, size: size)

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

    private func previewButton(_ item: PhotoItem, in list: [PhotoItem]) -> some View {
        Button {
            open(item, in: list)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
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

    private var bottomArea: some View {
        VStack(spacing: 0) {
            if let toast = toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 10)
            }
            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            if selectedIDs.isEmpty {
                HStack(spacing: 12) {
                    Button(action: onRestart) {
                        Text("重新扫描")
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(10)
                    }

                    ShareLink(item: exportText()) {
                        Text("导出清单")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(blue)
                            .cornerRadius(10)
                    }
                }
                .padding(16)
            } else {
                HStack(spacing: 12) {
                    Button {
                        selectedIDs.removeAll()
                    } label: {
                        Text("取消")
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(10)
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
        } else {
            selectedIDs.formUnion(ids)
            showToast("已选中本类 \(ids.count) 张")
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
    private func performDelete() {
        var chosen: [PhotoItem] = []
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
        triage = TriageRequest(title: tab.title, items: list)
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

    private func exportText() -> String {
        var lines: [String] = []
        lines.append("相册整理清单")
        lines.append("生成时间：" + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))
        lines.append("")
        lines.append("照片总数：\(result.photoCount)")
        lines.append("建议清理：\(suggested.count)")
        lines.append("重复组：\(dupGroups.count)")
        lines.append("相似组：\(simGroups.count)")
        lines.append("模糊：\(blurry.count)")
        lines.append("截图：\(shots.count)")

        for category in ContentCategory.allCases where category != .other {
            let n = contentItems(category).count
            if n > 0 {
                lines.append("\(category.rawValue)：\(n)")
            }
        }
        lines.append("")

        if !suggested.isEmpty {
            lines.append("—— 建议清理（按可能性排序）——")
            for item in suggested {
                let reason = item.cleanupReasons.prefix(2).joined(separator: "；")
                lines.append("  · \(item.displayName)  \(item.scorePercent)%  \(reason)")
            }
            lines.append("")
        }

        if !dupGroups.isEmpty {
            lines.append("—— 重复组（原图文件完全相同）——")
            for (i, g) in dupGroups.enumerated() {
                lines.append("组 \(i + 1)（\(g.items.count) 张）")
                for item in g.items {
                    lines.append("  · \(item.displayName)  \(item.resolutionText)  \(item.sizeText)")
                }
            }
            lines.append("")
        }

        if !simGroups.isEmpty {
            lines.append("—— 相似组（内容接近，不完全相同）——")
            for (i, g) in simGroups.enumerated() {
                lines.append("组 \(i + 1)（\(g.items.count) 张）")
                for item in g.items {
                    lines.append("  · \(item.displayName)  \(item.resolutionText)")
                }
            }
            lines.append("")
        }

        let receipts = contentItems(.receipt)
        if !receipts.isEmpty {
            lines.append("—— 发票票据 ——")
            for item in receipts {
                let hit = item.ocrHits.prefix(3).joined(separator: "/")
                lines.append("  · \(item.displayName)  \(hit)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - 分组里的可勾选缩略图

struct SelectableThumb: View {
    let item: PhotoItem
    let isSelected: Bool
    var size: CGFloat = 96
    let onOpen: () -> Void
    let onToggle: () -> Void

    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PhotoThumbView(asset: item.asset, size: size)

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

struct PhotoThumbView: View {
    let asset: PHAsset
    /// nil 表示铺满父容器（网格用）
    var size: CGFloat? = nil

    @State private var image: UIImage?

    private var isVideo: Bool { asset.mediaType == .video }

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
