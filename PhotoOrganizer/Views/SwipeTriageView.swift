import SwiftUI
import Photos
import UIKit

// MARK: - 打开逐张过的请求（用 item 驱动 sheet，避免快照捕获旧数据）

struct TriageRequest: Identifiable {
    let id = UUID()
    let title: String
    let items: [PhotoItem]
}

// MARK: - 统一的取图尺寸

/// 预取和显示必须用同一个尺寸，否则缓存永远打不中，划一张卡一下。
enum TriageMetrics {
    static var targetSize: CGSize {
        let w = max(1, UIScreen.main.bounds.width - 40)
        let h = max(1, UIScreen.main.bounds.height - 220)
        let scale = UIScreen.main.scale
        return CGSize(width: w * scale, height: h * scale)
    }
}

// MARK: - 图片缓存（划过的、下一张的，都提前备好）

final class TriageImageCache {
    static let shared = TriageImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 30
    }

    func image(for id: String) -> UIImage? {
        cache.object(forKey: id as NSString)
    }

    func store(_ image: UIImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }

    /// 预取后面几张。已经在缓存里的直接跳过，不会重复解码。
    func preload(_ items: [PhotoItem]) {
        let size = TriageMetrics.targetSize
        for item in items {
            let id = item.id
            if image(for: id) != nil { continue }
            let asset = item.asset
            PhotoLibraryService.shared.loadImage(for: asset, targetSize: size) { [weak self] img in
                guard let img = img else { return }
                self?.store(img, for: id)
            }
        }
    }
}

// MARK: - 卡片里的一张图

struct TriageImage: View {
    let item: PhotoItem

    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.06)
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let cached = TriageImageCache.shared.image(for: item.id) {
            image = cached
            return
        }
        guard !loading else { return }
        loading = true

        PhotoLibraryService.shared.loadImage(
            for: item.asset,
            targetSize: TriageMetrics.targetSize
        ) { img in
            DispatchQueue.main.async {
                loading = false
                guard let img = img else { return }
                TriageImageCache.shared.store(img, for: item.id)
                image = img
            }
        }
    }
}

// MARK: - 滑动逐张过（左滑删 / 右滑留）

struct SwipeTriageView: View {
    let title: String
    let items: [PhotoItem]
    let onFinish: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    @State private var drag: CGSize = .zero
    /// 非 nil 表示这一张正在飞出（或撤销时正在飞回来）
    @State private var fly: CGSize?
    /// 飞出动画期间锁住输入，防止连点/连划导致跳张
    @State private var busy = false
    @State private var history: [Decision] = []
    @State private var marks: Set<String> = []
    @State private var hint: String?

    private struct Decision {
        let id: String
        let marked: Bool
    }

    private struct StackEntry: Identifiable {
        let depth: Int
        let item: PhotoItem
        var id: String { item.id }
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if !items.isEmpty {
                    progressLine
                }

                Spacer(minLength: 6)

                if items.isEmpty {
                    Text("这一类里没有照片")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                } else if index < items.count {
                    cardStack
                } else {
                    summary
                }

                Spacer(minLength: 6)

                if !items.isEmpty {
                    if index < items.count {
                        actionButtons
                    } else {
                        finishButtons
                    }
                }
            }
            .padding(.bottom, 16)

            if let hint = hint {
                VStack {
                    Text(hint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                    Spacer()
                }
                .padding(.top, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            TriageImageCache.shared.preload(upcoming(0, 4))
        }
    }

    // MARK: 顶部

    private var topBar: some View {
        HStack {
            Button {
                finish()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .accessibilityLabel("关闭逐张过")

            Spacer()

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            Text(marks.isEmpty ? "左滑删 · 右滑留" : "已标 \(marks.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(marks.isEmpty ? Color.white.opacity(0.55) : Color(red: 1, green: 0.45, blue: 0.4))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var progressLine: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.49, blue: 0.96))
                        .frame(width: max(2, geo.size.width * CGFloat(min(index, items.count)) / CGFloat(max(items.count, 1))))
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(min(index + 1, items.count)) / \(items.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("跳过 = 保留")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: 卡片堆

    private var stackEntries: [StackEntry] {
        guard index < items.count else { return [] }
        let end = min(index + 3, items.count)
        var list: [StackEntry] = []
        list.reserveCapacity(end - index)
        for raw in index..<end {
            list.append(StackEntry(depth: raw - index, item: items[raw]))
        }
        return list
    }

    private var cardStack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                // 每张卡片用照片自己的 id 做身份：换张就是换视图，
                // 不会出现「同一个位置复用了上一张的 @State，图停在旧照片」。
                ForEach(stackEntries) { entry in
                    let isTop = entry.depth == 0
                    cardBody(entry.item, width: w)
                        .overlay(alignment: .topLeading) {
                            stamp("保留", color: Color(red: 0.25, green: 0.8, blue: 0.48))
                                .opacity(isTop ? rightProgress : 0)
                                .accessibilityHidden(true)
                        }
                        .overlay(alignment: .topTrailing) {
                            stamp("删除", color: Color(red: 0.96, green: 0.33, blue: 0.27))
                                .opacity(isTop ? leftProgress : 0)
                                .accessibilityHidden(true)
                        }
                        .offset(
                            x: isTop ? currentOffset.width : 0,
                            y: isTop ? currentOffset.height * 0.28 : CGFloat(entry.depth) * 12
                        )
                        .rotationEffect(.degrees(isTop ? currentRotation : 0))
                        .scaleEffect(isTop ? 1 : 1 - CGFloat(entry.depth) * 0.05)
                        .opacity(isTop ? 1 : (entry.depth == 1 ? 0.78 : 0.5))
                        .zIndex(Double(100 - entry.depth))
                        .gesture(dragGesture, including: isTop ? .all : .none)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 20)
    }

    private func cardBody(_ item: PhotoItem, width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            TriageImage(item: item)

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if item.isVideo {
                        Text("视频")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.25)))
                    }
                }

                HStack(spacing: 6) {
                    Text(item.resolutionText)
                    if !item.sizeText.isEmpty {
                        Text("·")
                        Text(item.sizeText)
                    }
                    if item.cleanupScore >= 0.5 {
                        Text("·")
                        Text("建议分 \(item.scorePercent)%")
                            .foregroundColor(Color(red: 1, green: 0.55, blue: 0.45))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))

                if let reason = item.cleanupReasons.first {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.45), radius: 14, y: 8)
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .heavy))
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, lineWidth: 3)
            )
            .rotationEffect(.degrees(-12))
            .padding(22)
    }

    // MARK: 位移 / 旋转 / 印章强度

    private var currentOffset: CGSize {
        fly ?? drag
    }

    private var currentRotation: Double {
        let raw = Double(currentOffset.width) / 20
        return max(-14, min(14, raw))
    }

    private var rightProgress: Double {
        max(0, min(1, Double(currentOffset.width) / 110))
    }

    private var leftProgress: Double {
        max(0, min(1, Double(-currentOffset.width) / 110))
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !busy else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !busy else { return }
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width

                // Tinder 式判定：要么拖够了，要么甩得快
                let goRight = dx > 110 || (dx > 42 && predicted > 240)
                let goLeft = dx < -110 || (dx < -42 && predicted < -240)

                if goRight {
                    commit(keep: true)
                } else if goLeft {
                    commit(keep: false)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        drag = .zero
                    }
                }
            }
    }

    // MARK: 按钮

    private var actionButtons: some View {
        HStack(spacing: 24) {
            roundButton(icon: "arrow.uturn.backward", label: "撤销", key: "undo",
                        bg: Color.white.opacity(0.14), enabled: !history.isEmpty && !busy) {
                undo()
            }
            roundButton(icon: "checkmark", label: "保留", key: "keep",
                        bg: Color(red: 0.2, green: 0.62, blue: 0.36), enabled: !busy) {
                commit(keep: true)
            }
            roundButton(icon: "trash", label: "删除", key: "delete",
                        bg: Color(red: 0.85, green: 0.24, blue: 0.2), enabled: !busy) {
                commit(keep: false)
            }
        }
        .padding(.top, 6)
    }

    private func roundButton(icon: String, label: String, key: String, bg: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(bg))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("triage-" + key)
    }

    private var finishButtons: some View {
        VStack(spacing: 10) {
            Button {
                finish()
            } label: {
                Text(marks.isEmpty ? "看完了，全部保留" : "完成，标记 \(marks.count) 张待删")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(marks.isEmpty
                                ? Color(red: 0.2, green: 0.62, blue: 0.36)
                                : Color(red: 0.85, green: 0.24, blue: 0.2))
                    .cornerRadius(12)
            }
            .accessibilityIdentifier("triage-finish")

            if !history.isEmpty {
                Button {
                    undo()
                } label: {
                    Text("返回上一张")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: 结算

    private var summary: some View {
        VStack(spacing: 12) {
            Image(systemName: marks.isEmpty ? "checkmark.seal.fill" : "trash.circle.fill")
                .font(.system(size: 54))
                .foregroundColor(marks.isEmpty
                                 ? Color(red: 0.3, green: 0.75, blue: 0.5)
                                 : Color(red: 0.95, green: 0.4, blue: 0.35))

            Text("这一批过完了")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            Text("看了 \(items.count) 张 · 标记删除 \(marks.count) 张")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))

            if !marks.isEmpty {
                Text("预计可释放 \(byteText(markedBytes))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 1, green: 0.55, blue: 0.45))
            }

            Text("标记只是暂存，回到列表点红色按钮才会真正删除")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    private var markedBytes: Int64 {
        items.filter { marks.contains($0.id) }
            .reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    // MARK: 行为

    private func upcoming(_ from: Int, _ count: Int) -> [PhotoItem] {
        guard from < items.count else { return [] }
        let end = min(from + count, items.count)
        return Array(items[from..<end])
    }

    private func commit(keep: Bool) {
        guard index < items.count, !busy else { return }
        busy = true

        let item = items[index]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        history.append(Decision(id: item.id, marked: !keep))
        if keep {
            marks.remove(item.id)
        } else {
            marks.insert(item.id)
        }

        let startHeight = drag.height
        withAnimation(.easeOut(duration: 0.22)) {
            fly = CGSize(width: keep ? 1000 : -1000, height: startHeight)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            // 换张这一步必须关掉动画：否则离场卡会在被移除前先弹回中间一帧，闪一下。
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                fly = nil
                drag = .zero
                index += 1
            }
            busy = false
            TriageImageCache.shared.preload(upcoming(index, 4))
        }
    }

    private func undo() {
        guard !busy, let last = history.popLast() else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        marks.remove(last.id)

        let target = max(0, index - 1)
        let fromLeft = last.marked          // 刚才往左飞走的，就从左边回来
        let entry = CGSize(width: fromLeft ? -320 : 320, height: 0)

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            index = target
            drag = .zero
            fly = entry
        }

        // 先让「换了哪一张」这一帧落地，再播回弹动画，
        // 否则两次状态改动挤在同一帧里，卡片会直接跳到中间，看不出是从哪边回来的。
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                fly = .zero
            }
        }

        showHint("已撤销，回到第 \(target + 1) 张")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) {
                fly = nil
            }
            busy = false
        }

        TriageImageCache.shared.preload(upcoming(target, 4))
    }

    private func showHint(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.2)) {
                if hint == text { hint = nil }
            }
        }
    }

    private func finish() {
        onFinish(marks)
        dismiss()
    }
}
