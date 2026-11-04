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
                    featureRow(icon: "doc.on.doc", title: "重复照片", desc: "原图文件完全相同，留一张就够")
                    Divider()
                    featureRow(icon: "square.stack.3d.up", title: "相似照片", desc: "连拍、角度几乎一样的那些")
                    Divider()
                    featureRow(icon: "camera.filters", title: "模糊照片", desc: "糊掉、拍废了的")
                    Divider()
                    featureRow(icon: "rectangle.dashed", title: "截图", desc: "系统截图，通常不需要留太久")
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

                Text("扫描不改动任何照片。删除前会二次确认，删掉的照片可在「最近删除」里 30 天内恢复。")
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

            Text("照片多的话需要几分钟，别锁屏、别切走")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }
}

// MARK: - 结果

struct ResultView: View {
    let result: AnalysisResult
    let onRestart: () -> Void

    @State private var selectedCategory: PhotoCategory = .duplicate
    @State private var selectedIDs: Set<String> = []
    @State private var deletedIDs: Set<String> = []

    @State private var previewItems: [PhotoItem] = []
    @State private var previewStart: Int = 0
    @State private var showPreview = false

    @State private var showDeleteConfirm = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("分类", selection: $selectedCategory) {
                ForEach(PhotoCategory.allCases) { cat in
                    Text("\(cat.rawValue) \(count(for: cat))").tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
        }
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .onChange(of: selectedCategory) { _ in
            selectedIDs.removeAll()
        }
        .confirmationDialog(
            "删除选中的 \(selectedIDs.count) 张照片？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedIDs.count) 张", role: .destructive) {
                performDelete()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后会进入「照片」App 的「最近删除」，30 天内可以恢复。")
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .fullScreenCover(isPresented: $showPreview) {
            PhotoPreviewView(items: previewItems, startIndex: previewStart) { item in
                deleteItems([item])
            }
        }
    }

    // MARK: 过滤后的数据

    private func alive(_ group: PhotoGroup) -> PhotoGroup? {
        let items = group.items.filter { !deletedIDs.contains($0.id) }
        guard items.count > 1 else { return nil }
        return PhotoGroup(items: items, isExactDuplicate: group.isExactDuplicate)
    }

    private var dupGroups: [PhotoGroup] {
        result.duplicateGroups.compactMap { alive($0) }
    }

    private var simGroups: [PhotoGroup] {
        result.similarGroups.compactMap { alive($0) }
    }

    private var blurry: [PhotoItem] {
        result.blurryItems.filter { !deletedIDs.contains($0.id) }
    }

    private var shots: [PhotoItem] {
        result.screenshotItems.filter { !deletedIDs.contains($0.id) }
    }

    private var allVisibleItems: [PhotoItem] {
        var arr: [PhotoItem] = []
        arr.append(contentsOf: dupGroups.flatMap { $0.items })
        arr.append(contentsOf: simGroups.flatMap { $0.items })
        arr.append(contentsOf: blurry)
        arr.append(contentsOf: shots)
        return arr
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text(summaryLine)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                if selectedIDs.isEmpty {
                    Text("点缩略图可放大")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("已选 \(selectedIDs.count) 张")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                }
            }

            HStack(spacing: 10) {
                summaryItem(title: "重复组", value: "\(dupGroups.count)", color: Color(red: 0.85, green: 0.35, blue: 0.2))
                summaryItem(title: "相似组", value: "\(simGroups.count)", color: Color(red: 0.55, green: 0.35, blue: 0.85))
                summaryItem(title: "模糊", value: "\(blurry.count)", color: Color(red: 0.85, green: 0.6, blue: 0.1))
                summaryItem(title: "截图", value: "\(shots.count)", color: Color(red: 0.4, green: 0.45, blue: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var summaryLine: String {
        var s = "共 \(result.photoCount) 张照片"
        if result.videoCount > 0 {
            s += " · \(result.videoCount) 个视频"
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

    // MARK: 列表内容

    @ViewBuilder
    private var content: some View {
        switch selectedCategory {
        case .duplicate:
            if dupGroups.isEmpty {
                emptyHint("没有发现完全相同的照片")
            } else {
                ForEach(Array(dupGroups.enumerated()), id: \.element.id) { index, group in
                    groupCard(group: group, index: index + 1)
                }
            }
        case .similar:
            if simGroups.isEmpty {
                emptyHint("没有发现相似照片")
            } else {
                ForEach(Array(simGroups.enumerated()), id: \.element.id) { index, group in
                    groupCard(group: group, index: index + 1)
                }
            }
        case .blurry:
            if blurry.isEmpty {
                emptyHint("没有发现模糊照片")
            } else {
                ForEach(blurry) { item in
                    singleCard(item: item, tag: "模糊", onOpen: { open(item, in: blurry) })
                }
            }
        case .screenshot:
            if shots.isEmpty {
                emptyHint("没有发现截图")
            } else {
                ForEach(shots) { item in
                    singleCard(item: item, tag: "截图", onOpen: { open(item, in: shots) })
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

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
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                        SelectableThumb(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            size: 80,
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

    private func singleCard(item: PhotoItem, tag: String, onOpen: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SelectableThumb(
                item: item,
                isSelected: selectedIDs.contains(item.id),
                size: 66,
                onOpen: onOpen,
                onToggle: { toggle(item.id) }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    Text(item.resolutionText)
                    if !item.sizeText.isEmpty {
                        Text("·")
                        Text(item.sizeText)
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                if let s = item.sharpness {
                    Text(String(format: "清晰度 %.1f", s))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(tag)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tag == "模糊" ? Color.orange : Color.gray)
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(12)
    }

    // MARK: 底部操作栏

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
                            .background(Color(red: 0.18, green: 0.49, blue: 0.96))
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
                        showDeleteConfirm = true
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

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func open(_ item: PhotoItem, in list: [PhotoItem]) {
        guard let idx = list.firstIndex(where: { $0.id == item.id }) else { return }
        previewItems = list
        previewStart = idx
        showPreview = true
    }

    private func performDelete() {
        let items = allVisibleItems.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        deleteItems(items)
    }

    private func deleteItems(_ items: [PhotoItem]) {
        let assets = items.map { $0.asset }
        PhotoLibraryService.shared.delete(assets: assets) { success, error in
            DispatchQueue.main.async {
                if success {
                    deletedIDs.formUnion(items.map { $0.id })
                    selectedIDs.subtract(Set(items.map { $0.id }))
                    message = "已删除 \(items.count) 张照片，可在「照片 → 最近删除」里恢复。"
                } else {
                    message = "删除失败：" + (error?.localizedDescription ?? "未知原因")
                }
            }
        }
    }

    private func count(for cat: PhotoCategory) -> Int {
        switch cat {
        case .duplicate: return dupGroups.count
        case .similar: return simGroups.count
        case .blurry: return blurry.count
        case .screenshot: return shots.count
        }
    }

    private func exportText() -> String {
        var lines: [String] = []
        lines.append("相册整理清单")
        lines.append("生成时间：" + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))
        lines.append("")
        lines.append("照片总数：\(result.photoCount)")
        lines.append("重复组：\(dupGroups.count)")
        lines.append("相似组：\(simGroups.count)")
        lines.append("模糊：\(blurry.count)")
        lines.append("截图：\(shots.count)")
        lines.append("")

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

        if !blurry.isEmpty {
            lines.append("—— 模糊照片 ——")
            for item in blurry {
                lines.append("  · \(item.displayName)  \(item.resolutionText)")
            }
            lines.append("")
        }

        if !shots.isEmpty {
            lines.append("—— 截图 ——")
            for item in shots {
                lines.append("  · \(item.displayName)  \(item.resolutionText)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - 可勾选的缩略图

struct SelectableThumb: View {
    let item: PhotoItem
    let isSelected: Bool
    var size: CGFloat = 76
    let onOpen: () -> Void
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                PhotoThumbView(asset: item.asset, size: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2.5)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.red : Color.black.opacity(0.35))
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(4)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 缩略图

struct PhotoThumbView: View {
    let asset: PHAsset
    var size: CGFloat = 72

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(8)
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
