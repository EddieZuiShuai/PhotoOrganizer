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
                    featureRow(icon: "doc.on.doc", title: "重复照片", desc: "内容完全相同，留一张就够")
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

                Text("第一版只做分析和清单，不会删你任何照片。")
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

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

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
                .padding(.bottom, 100)
            }
        }
        .overlay(alignment: .bottom) {
            bottomBar
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 10) {
            summaryItem(title: "照片", value: "\(result.photoCount)", color: Color(red: 0.18, green: 0.49, blue: 0.96))
            summaryItem(title: "重复组", value: "\(result.duplicateGroups.count)", color: Color(red: 0.85, green: 0.35, blue: 0.2))
            summaryItem(title: "模糊", value: "\(result.blurryItems.count)", color: Color(red: 0.85, green: 0.6, blue: 0.1))
            summaryItem(title: "截图", value: "\(result.screenshotItems.count)", color: Color(red: 0.4, green: 0.45, blue: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    @ViewBuilder
    private var content: some View {
        switch selectedCategory {
        case .duplicate:
            if result.duplicateGroups.isEmpty {
                emptyHint("没有发现内容完全相同的照片")
            } else {
                ForEach(Array(result.duplicateGroups.enumerated()), id: \.element.id) { index, group in
                    groupCard(group: group, index: index + 1)
                }
            }
        case .similar:
            if result.similarGroups.isEmpty {
                emptyHint("没有发现相似照片")
            } else {
                ForEach(Array(result.similarGroups.enumerated()), id: \.element.id) { index, group in
                    groupCard(group: group, index: index + 1)
                }
            }
        case .blurry:
            if result.blurryItems.isEmpty {
                emptyHint("没有发现模糊照片")
            } else {
                ForEach(result.blurryItems) { item in
                    singleCard(item: item, tag: "模糊")
                }
            }
        case .screenshot:
            if result.screenshotItems.isEmpty {
                emptyHint("没有发现截图")
            } else {
                ForEach(result.screenshotItems) { item in
                    singleCard(item: item, tag: "截图")
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.items) { item in
                        PhotoThumbView(asset: item.asset, size: 76)
                    }
                }
            }

            if let first = group.items.first {
                Text(first.displayName + " · " + first.resolutionText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(12)
    }

    private func singleCard(item: PhotoItem, tag: String) -> some View {
        HStack(spacing: 12) {
            PhotoThumbView(asset: item.asset, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text(item.resolutionText)
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

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
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
            .background(Color.white)
        }
    }

    private func count(for cat: PhotoCategory) -> Int {
        switch cat {
        case .duplicate: return result.duplicateGroups.count
        case .similar: return result.similarGroups.count
        case .blurry: return result.blurryItems.count
        case .screenshot: return result.screenshotItems.count
        }
    }

    private func exportText() -> String {
        var lines: [String] = []
        lines.append("相册整理清单")
        lines.append("生成时间：" + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))
        lines.append("")
        lines.append("照片总数：\(result.photoCount)")
        lines.append("重复组：\(result.duplicateGroups.count)")
        lines.append("相似组：\(result.similarGroups.count)")
        lines.append("模糊：\(result.blurryItems.count)")
        lines.append("截图：\(result.screenshotItems.count)")
        lines.append("")

        if !result.duplicateGroups.isEmpty {
            lines.append("—— 重复组 ——")
            for (i, g) in result.duplicateGroups.enumerated() {
                lines.append("组 \(i + 1)（\(g.items.count) 张）")
                for item in g.items {
                    lines.append("  · \(item.displayName)  \(item.resolutionText)")
                }
            }
            lines.append("")
        }

        if !result.blurryItems.isEmpty {
            lines.append("—— 模糊照片 ——")
            for item in result.blurryItems {
                lines.append("  · \(item.displayName)  \(item.resolutionText)")
            }
            lines.append("")
        }

        if !result.screenshotItems.isEmpty {
            lines.append("—— 截图 ——")
            for item in result.screenshotItems {
                lines.append("  · \(item.displayName)  \(item.resolutionText)")
            }
        }

        return lines.joined(separator: "\n")
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
