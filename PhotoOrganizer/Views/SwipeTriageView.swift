import SwiftUI
import Photos
import UIKit
import AVFoundation
import Combine

// MARK: - 打开逐张过的请求（用 item 驱动 sheet，避免快照捕获旧数据）

struct TriageRequest: Identifiable {
    let id = UUID()
    let title: String
    let items: [PhotoItem]
    /// 这份列表的「进度身份」。同一个 tab / 同一个分类共用一份进度，
    /// 所以清理页的「截图」和分类页的「截图」是同一份——判过的不会再问一遍。
    let progressKey: String
    /// 隐私组：卡片先糊住，点一下才看原图。别处一律 false。
    var blurred: Bool = false
    /// 隐私组：底部多给一颗「隐藏」（单张）。
    /// **不能拿 `blurred` 代替**——用户在设置里关掉打码后 `blurred` 是 false，
    /// 但这里仍然是隐私组，隐藏按钮该在还得在。
    var isPrivacy: Bool = false
}

// MARK: - 逐张过的进度（判过的 id + 待删标记，落盘）

/// 记住「哪些已经判断过」，而不是「看到第几张」。
///
/// 为什么不能存 index：列表是会变的——删了照片会缩、按时间排序会从最前面
/// 插进新照片、切了筛选会换一整套。存 index 下次就落到一张完全不相干的照片上。
/// 存 id 集合之后这三种变化都自然正确：判过的（无论保留还是待删）永远不再出现，
/// 新照片一定没被判断过，所以一定排在最前面。
///
/// **待删标记必须一起存**：只存 judged 的话，一张标了待删的照片重启后会变成
/// 「判过了但标记没了」——既不会重看，也不会被删，等于彻底漏掉。
///
/// **必须是 `ObservableObject`**：入口那条「已看 N · 继续」（`TriageEntryBar`）读的是
/// `judgedCount`，它是个普通 getter，没有发布机制。1.5(28) 之前这里少了一层通知，
/// 于是「从头再筛一遍」清空进度、退出后入口还挂着旧的「已看 7」——用户看到的就是
/// 「刚重置过怎么还是 7」。`revision` 只在写操作里 +1，视图订阅它就够了。
final class TriageProgressStore: ObservableObject {
    static let shared = TriageProgressStore()

    /// 任何会影响「已看多少 / 标了哪些」的改动都 +1，让订阅方重算。
    @Published private(set) var revision = 0

    private struct Entry: Codable {
        var judged: [String]
        var marked: [String]
        var updatedAt: Date
    }

    private let storageKey = "triageProgress.v1"
    /// 最多留 8 个上下文，超了丢最久没动的
    private let maxContexts = 8
    /// 单个上下文最多记 5000 条。实际只会装你真划过的那几百条，
    /// 这个上限是防「把一万张截图全滑一遍」时 UserDefaults 无限膨胀。
    private let maxIDs = 5000
    private let maxAge: TimeInterval = 30 * 24 * 3600

    private var entries: [String: Entry]
    private var pendingSave: DispatchWorkItem?

    private init() {
        entries = [:]
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries = decoded.filter { $0.value.updatedAt > cutoff }
    }

    // MARK: 读

    func judgedSet(for key: String) -> Set<String> {
        Set(entries[key]?.judged ?? [])
    }

    func markedSet(for key: String) -> Set<String> {
        Set(entries[key]?.marked ?? [])
    }

    func judgedCount(for key: String) -> Int {
        entries[key]?.judged.count ?? 0
    }

    // MARK: 写

    func record(key: String, judgedID: String, marked: Bool) {
        var entry = entries[key] ?? Entry(judged: [], marked: [], updatedAt: Date())
        if !entry.judged.contains(judgedID) {
            entry.judged.append(judgedID)
        }
        if marked {
            if !entry.marked.contains(judgedID) {
                entry.marked.append(judgedID)
            }
        } else {
            entry.marked.removeAll { $0 == judgedID }
        }
        if entry.judged.count > maxIDs {
            entry.judged.removeFirst(entry.judged.count - maxIDs)
            let kept = Set(entry.judged)
            entry.marked.removeAll { !kept.contains($0) }
        }
        entry.updatedAt = Date()
        entries[key] = entry
        scheduleSave()
        revision &+= 1
    }

    /// 照片真删掉了，进度里也别留着它们的 id
    func remove(key: String, ids: [String]) {
        guard !ids.isEmpty, var entry = entries[key] else { return }
        let gone = Set(ids)
        entry.judged.removeAll { gone.contains($0) }
        entry.marked.removeAll { gone.contains($0) }
        entry.updatedAt = Date()
        entries[key] = entry
        scheduleSave()
        revision &+= 1
    }

    /// 撤销：这一张要重新判断。只删标记不够，还得把「判过」的记录退回去，
    /// 否则下次进来它会当成已看过的直接跳过，用户再也没机会改主意。
    func forget(key: String, id: String) {
        guard var entry = entries[key] else { return }
        entry.judged.removeAll { $0 == id }
        entry.marked.removeAll { $0 == id }
        entry.updatedAt = Date()
        entries[key] = entry
        scheduleSave()
        revision &+= 1
    }

    func clear(key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        scheduleSave()
        revision &+= 1
    }

    // MARK: 落盘

    /// 每划一张就写一次 UserDefaults 太浪费，攒 2 秒；退出时 `flush()` 兜底。
    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func save() {
        if entries.count > maxContexts {
            let keep = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxContexts)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
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
            // 视频的封面由 TriageMedia 自己取：走同一个缓存会让「划到视频」
            // 命中一张静态帧，看起来像视频卡住了。
            if item.isVideo { continue }
            let asset = item.asset
            PhotoLibraryService.shared.loadImage(for: asset, targetSize: size) { [weak self] img in
                guard let img = img else { return }
                self?.store(img, for: id)
            }
        }
    }
}

// MARK: - 视频播放器（卡片内直接放，不跳出去）

/// AVPlayerLayer 的宿主。没有系统控制条——有控制条就会把左右划的手势抢走。
private final class TriagePlayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct TriagePlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TriagePlayerHost {
        let view = TriagePlayerHost()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: TriagePlayerHost, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// 一张卡片一个播放器。只有最上面那张会真的装载，划走就立刻停。
final class TriageVideoBox: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published var isMuted = true

    private var token = UUID()
    private var endObserver: NSObjectProtocol?

    func load(_ asset: PHAsset) {
        guard player == nil, !loading else { return }
        loading = true
        failed = false

        let current = UUID()
        token = current

        let options = PHVideoRequestOptions()
        // 只存在 iCloud 上的视频，这里会触发下载；不打开的话用户看到的是永远转圈
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
            DispatchQueue.main.async {
                guard let self = self, self.token == current else { return }
                self.loading = false

                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }

                guard let item = item else {
                    self.failed = true
                    return
                }

                let p = AVPlayer(playerItem: item)
                p.actionAtItemEnd = .pause
                p.isMuted = self.isMuted
                self.attach(p)
                self.player = p
                p.play()
                self.isPlaying = true
            }
        }
    }

    func toggle() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func stop() {
        token = UUID()
        player?.pause()
        player = nil
        isPlaying = false
        loading = false
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func attach(_ player: AVPlayer) {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }
}

// MARK: - 卡片里的一张图 / 一段视频

/// 照片 `scaledToFit`（完整显示，不裁切），视频给封面 + 点一下播。
///
/// 为什么照片不能 `scaledToFill`：左右滑是用来判断「这张该不该删」的，
/// 填满容器会把画面四周裁掉——人只剩半张脸、发票只剩中间一截，用户据此点删除就是误删。
/// 宁可上下留黑边，也要看到整张。
struct TriageMedia: View {
    let item: PhotoItem
    let isActive: Bool
    /// 隐私组：先糊住，点一下才看原图。
    /// 逐张过里没有缩略图那一层的遮挡，不自己糊就等于绕过了「隐私打码」这个设置。
    var blurred: Bool = false

    @StateObject private var video = TriageVideoBox()
    @StateObject private var live = LivePhotoModel()
    @State private var image: UIImage?
    @State private var poster: UIImage?
    @State private var loading = false
    @State private var revealed = false

    @State private var livePhoto: PHLivePhoto?
    @State private var liveLoading = false
    @State private var liveToken = UUID()

    private var hid: Bool { blurred && !revealed }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92)

                Group {
                    if item.isVideo {
                        videoLayer(geo: geo)
                    } else if item.isLivePhoto {
                        liveLayer(geo: geo)
                    } else {
                        imageLayer(geo: geo)
                    }
                }
                .blur(radius: hid ? 18 : 0)
                .animation(.easeOut(duration: 0.18), value: hid)

                if hid {
                    // 用 Button 而不是 tap 手势：卡片本身挂着拖拽手势，
                    // 手势叠在一起时 tap 会被吞掉（视频那层踩过这个坑）。
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        revealed = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 26))
                            Text("已打码 · 点一下看原图")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("triage-reveal")
                }
            }
            .clipped()
            .onAppear {
                load()
                if isActive { startLiveIfNeeded() }
            }
            .onChange(of: isActive) { active in
                // 划走就把播放器停掉：不停的话后台有好几个视频在同时解码
                if active {
                    startLiveIfNeeded()
                } else {
                    video.stop()
                    stopLive()
                }
            }
            .onChange(of: revealed) { _ in
                // 打码状态下不自动播（糊着动起来只会让人以为卡了），
                // 点了「看原图」才补上那一次播放。
                if isActive { startLiveIfNeeded() }
            }
        }
    }

    // MARK: 照片

    @ViewBuilder
    private func imageLayer(geo: GeometryProxy) -> some View {
        if let image = image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
        } else {
            ProgressView().tint(.white)
        }
    }

    // MARK: Live 照片

    /// 静帧照常显示，动态层叠上去、只在播放的那几秒可见。
    /// 播放规则和全屏预览完全一致：进场自动播一次、静音、播完停、
    /// 点右上角 LIVE 重播一次。
    @ViewBuilder
    private func liveLayer(geo: GeometryProxy) -> some View {
        ZStack {
            imageLayer(geo: geo)

            if let livePhoto = livePhoto {
                LivePhotoSurface(photo: livePhoto, model: live)
                    .opacity(live.isPlaying ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.14), value: live.isPlaying)
            }

            if live.isReady {
                // 位置对齐全屏预览：左下角、和「重播」挨着、给一颗同样大的静音键。
                // 之前挂在右上角只有 9pt 字、4pt 内边距，真机上按十次中三次（1.5(29) 反馈）。
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Button {
                            live.playOnce()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "livephoto")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("LIVE")
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .tracking(0.6)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("重播 Live 照片")
                        .accessibilityIdentifier("triage-live-replay")

                        Button {
                            live.toggleMute()
                        } label: {
                            Image(systemName: live.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(live.isMuted ? "取消静音" : "静音")
                        .accessibilityIdentifier("triage-live-mute")

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func startLiveIfNeeded() {
        guard !item.isVideo, item.isLivePhoto else { return }
        // 还糊着就别播：一段糊掉的画面在动，看起来更像卡住了
        guard !hid else { return }
        live.stop()
        live.markReady(false)
        guard livePhoto == nil, !liveLoading else {
            if livePhoto != nil {
                live.markReady(true)
                live.playOnce()
            }
            return
        }
        liveLoading = true
        let myToken = UUID()
        liveToken = myToken

        LivePhotoLoader.load(asset: item.asset) { loaded in
            guard liveToken == myToken else { return }
            liveLoading = false
            guard let loaded = loaded else { return }
            livePhoto = loaded
            live.markReady(true)
            // 取图要几秒（iCloud）时用户可能已经划走，别在别的卡片上突然动起来
            guard isActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                live.playOnce()
            }
        }
    }

    private func stopLive() {
        live.reset()
        liveToken = UUID()
        liveLoading = false
        // 放掉视频轨，不然划过的每一张 Live 都会一直占着内存
        livePhoto = nil
    }

    // MARK: 视频

    @ViewBuilder
    private func videoLayer(geo: GeometryProxy) -> some View {
        ZStack {
            // 可点区域：封面 / 播放器 + 播放角标。播放/暂停的 tap 只挂在这一层，
            // 这样右上角喇叭按钮（下面的独立覆盖层）被点的时候不会再触发播放/暂停。
            ZStack {
                if let player = video.player {
                    TriagePlayerSurface(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let poster = poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if video.failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24))
                        Text("这段视频读不出来（可能只存在 iCloud 上）")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 24)
                } else {
                    ProgressView().tint(.white)
                }

                if video.player == nil {
                    // 封面上的播放角标：明确告诉用户「这是视频，可以点」
                    VStack(spacing: 6) {
                        if video.loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.45), radius: 10)
                            Text(video.failed ? "重试播放" : "点一下播放")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                } else if !video.isPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.45), radius: 10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // 用 simultaneousGesture 而不是 onTapGesture：卡片本身挂着拖拽手势，
            // 两个独立手势叠在一起时 tap 会被拖拽吞掉（要拖 6pt 才成立，tap 就永远不触发）。
            .simultaneousGesture(
                TapGesture().onEnded {
                    if video.player == nil {
                        video.load(item.asset)
                    } else {
                        video.toggle()
                    }
                }
            )

            // 静音开关单独一个角标，避免「怎么没声音」的疑问。
            // 它是「可点区域」之外的独立覆盖层：Button 自己吃掉这次 tap，
            // 不会再同时触发上面那层的播放/暂停（否则点喇叭会先静音→又暂停）。
            // 位置和 Live 一样挪到左下角，尺寸从 32 放到 40（真机好按）。
            if video.player != nil {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Button {
                            video.toggleMute()
                        } label: {
                            Image(systemName: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(video.isMuted ? "取消静音" : "静音")
                        .accessibilityIdentifier("triage-video-mute")
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: 加载

    private func load() {
        if item.isVideo {
            loadPoster()
            return
        }
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

    /// 视频封面单独取一张，不走 TriageImageCache（那是给可点选的静态图用的）
    private func loadPoster() {
        guard poster == nil else { return }
        PhotoLibraryService.shared.loadImage(
            for: item.asset,
            targetSize: TriageMetrics.targetSize
        ) { img in
            DispatchQueue.main.async {
                poster = img
            }
        }
    }
}

// MARK: - 滑动逐张过（左滑待删 / 右滑保留）

struct SwipeTriageView: View {
    let title: String
    /// 这份列表的进度身份。同一个 tab / 同一个分类共用一份进度。
    let progressKey: String
    /// 隐私组：卡片先糊住，点一下才看原图
    let blurred: Bool
    /// 隐私组：底部多给一颗「隐藏」。只作用于**当前这一张**，
    /// 不是把所有待删的一起藏——那是两个完全不同的动作。
    let isPrivacy: Bool
    let onFinish: (Set<String>) -> Void
    /// 批量真删所有已标记的。列表那边负责落到系统相册并更新已删集合。
    let onDeleteMany: ([PhotoItem]) -> Void
    /// 单张隐藏成功。列表那边负责把 id 加进 `hiddenIDs`，让网格立刻消失。
    let onHide: ((PhotoItem) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// 进场时给的那一份是快照；删除会改变长度，所以这里维护一份可变的。
    @State private var list: [PhotoItem]

    @State private var index: Int
    @State private var drag: CGSize = .zero
    /// 非 nil 表示这一张正在飞出（或撤销时正在飞回来）
    @State private var fly: CGSize?
    /// 飞出动画期间锁住输入，防止连点/连划导致跳张
    @State private var busy = false
    @State private var history: [Decision] = []
    @State private var marks: Set<String>
    @State private var hint: String?
    @State private var confirmBatchDelete = false
    @State private var confirmReset = false
    /// 进场时跳到的位置。>0 说明这次是「继续上次」
    @State private var resumeFrom: Int
    /// 是否已经走过 `finish()`。用来避免「点 X 退出」和「下滑关掉」两条路径重复回调。
    @State private var finished = false

    private struct Decision {
        let id: String
        let marked: Bool
    }

    private struct StackEntry: Identifiable {
        let depth: Int
        let item: PhotoItem
        var id: String { item.id }
    }

    init(
        title: String,
        progressKey: String,
        items: [PhotoItem],
        blurred: Bool = false,
        isPrivacy: Bool = false,
        onFinish: @escaping (Set<String>) -> Void,
        onDeleteMany: @escaping ([PhotoItem]) -> Void,
        onHide: ((PhotoItem) -> Void)? = nil
    ) {
        self.title = title
        self.progressKey = progressKey
        self.blurred = blurred
        self.isPrivacy = isPrivacy
        self.onFinish = onFinish
        self.onDeleteMany = onDeleteMany
        self.onHide = onHide
        _list = State(initialValue: items)

        // 进场位置不是 0，而是「第一张还没判断过的」。
        // 这样新照片插到最前面会从它开始（它没判过），
        // 中间删了几张也不会错位（判过的 id 不在列表里自然跳过）。
        let judged = TriageProgressStore.shared.judgedSet(for: progressKey)
        let start = items.firstIndex { !judged.contains($0.id) } ?? items.count
        _index = State(initialValue: start)
        _resumeFrom = State(initialValue: start)

        // 待删标记也一起恢复：只恢复「判过」而不恢复「待删」的话，
        // 一张标了待删的照片重启后会变成「判过了但标记没了」——既不会重看也不会被删。
        let validIDs = Set(items.map { $0.id })
        let restored = TriageProgressStore.shared.markedSet(for: progressKey)
            .intersection(validIDs)
        _marks = State(initialValue: restored)
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if !list.isEmpty {
                    progressLine
                }

                Spacer(minLength: 6)

                if list.isEmpty {
                    Text("这一类里没有照片")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                } else if index < list.count {
                    cardStack
                } else {
                    summary
                }

                Spacer(minLength: 6)

                // 注意这里不套 `if !list.isEmpty`：删到最后一张时数组会空，
                // 套上的话底部按钮整块消失，用户就退不出去了。
                if index < list.count {
                    actionButtons
                } else {
                    finishButtons
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
            // 从「第一张没判过的」开始，所以预取也要从这儿起，
            // 不能固定从 0 开始——那是好几千张之前的事，白读一堆图。
            TriageImageCache.shared.preload(upcoming(index, 4))
            if resumeFrom > 0 {
                showHint("已看 \(resumeFrom) 张，从第 \(resumeFrom + 1) 张继续")
            }
        }
        .onDisappear {
            // 下滑关掉 sheet 不走 `finish()`，标记会整批丢掉（用户看到的就是
            // 「明明标了 3 张，回到列表一张都没选上，也没提示」）。补一条同样的收尾，
            // 让两条退出路径等价。`finished` 保证不会重复回调。
            guard !finished else { return }
            finished = true
            TriageProgressStore.shared.flush()
            let snapshot = marks
            DispatchQueue.main.async { onFinish(snapshot) }
        }
        .confirmationDialog(
            "删除已标记的 \(marks.count) 张？",
            isPresented: $confirmBatchDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(marks.count) 张", role: .destructive) {
                deleteMany()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("直接从相册删除。30 天内在「最近删除」里可以恢复，但在这里没法撤销。")
        }
        .confirmationDialog(
            "从头再筛一遍？",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("从头开始", role: .destructive) { resetToStart() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("已经看过的 \(TriageProgressStore.shared.judgedCount(for: progressKey)) 张会回到开头，待删标记也会清掉。照片本身不受影响。")
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

            // 只有真有过进度才给这个按钮：一张都没划过时它没有意义。
            if TriageProgressStore.shared.judgedCount(for: progressKey) > 0 {
                Button {
                    confirmReset = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .accessibilityLabel("从头再筛一遍")
                .accessibilityIdentifier("triage-reset")
            }

            Spacer()

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            Text(marks.isEmpty ? "左滑待删 · 右滑保留" : "待删 \(marks.count)")
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
                        .frame(width: max(2, geo.size.width * CGFloat(min(index, list.count)) / CGFloat(max(list.count, 1))))
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(min(index + 1, list.count)) / \(list.count)")
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
        guard index < list.count else { return [] }
        let end = min(index + 3, list.count)
        var out: [StackEntry] = []
        out.reserveCapacity(end - index)
        for raw in index..<end {
            out.append(StackEntry(depth: raw - index, item: list[raw]))
        }
        return out
    }

    private var cardStack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                // 每张卡片用照片自己的 id 做身份：换张就是换视图，
                // 不会出现「同一个位置复用了上一张的 @State，图停在旧照片」。
                ForEach(stackEntries) { entry in
                    let isTop = entry.depth == 0
                    cardBody(entry.item, width: w, isActive: isTop)
                        .overlay(alignment: .topLeading) {
                            stamp("保留", color: Color(red: 0.25, green: 0.8, blue: 0.48))
                                .opacity(isTop ? rightProgress : 0)
                                .accessibilityHidden(true)
                        }
                        .overlay(alignment: .topTrailing) {
                            stamp("待删", color: Color(red: 0.96, green: 0.33, blue: 0.27))
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

    private func cardBody(_ item: PhotoItem, width: CGFloat, isActive: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            TriageMedia(item: item, isActive: isActive, blurred: blurred)

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

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
                    } else if item.isLivePhoto {
                        Text("LIVE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.4)
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
            .padding(.horizontal, 16)
            .padding(.top, 16)
            // Live / 视频的下半部分让给左下角那排「LIVE + 静音」：
            // 不留这 44pt，文件名会正好压在按钮上。普通照片保持原来的 16。
            .padding(.bottom, (item.isLivePhoto || item.isVideo) ? 60 : 16)
            .allowsHitTesting(false)
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
        // 隐私组多一颗「隐藏」，一共五颗。间距从 14 收到 10：
        // 五颗 52 的圆 + 四个 10 的间距 = 300，iPhone SE（375）也放得下。
        HStack(spacing: 10) {
            roundButton(icon: "arrow.uturn.backward", label: "撤销", key: "undo",
                        bg: Color.white.opacity(0.14), enabled: !history.isEmpty && !busy) {
                undo()
            }
            roundButton(icon: "flag.fill", label: "待删", key: "mark",
                        bg: Color(red: 0.9, green: 0.5, blue: 0.15), enabled: !busy) {
                commit(keep: false)
            }
            roundButton(icon: "checkmark", label: "保留", key: "keep",
                        bg: Color(red: 0.2, green: 0.62, blue: 0.36), enabled: !busy) {
                commit(keep: true)
            }
            // 隐藏和「待删」是两码事：待删是**攒着一起删**，隐藏是**这一张立刻挪走**。
            // 所以它单独一颗、只作用于当前这张，不读 marks。
            if isPrivacy {
                roundButton(icon: "eye.slash.fill", label: "隐藏", key: "hide-one",
                            bg: Color.white.opacity(0.18), enabled: !busy) {
                    hideCurrent()
                }
            }
            // 删除 = 一次性真删所有已标「待删」的，不可撤销，单独一次确认。
            // 动态显示张数，一张都没标时置灰。
            roundButton(icon: "trash.fill",
                        label: marks.isEmpty ? "删除" : "删除 \(marks.count) 张",
                        key: "delete-many",
                        bg: Color(red: 0.72, green: 0.14, blue: 0.16),
                        enabled: !marks.isEmpty && !busy) {
                confirmBatchDelete = true
            }
        }
        .padding(.top, 6)
    }

    private func roundButton(icon: String, label: String, key: String, bg: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(bg))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.72))
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
                Text(list.isEmpty
                     ? "完成"
                     : (marks.isEmpty ? "看完了，全部保留" : "完成，待删 \(marks.count) 张"))
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

            Text("看了 \(list.count) 张 · 待删 \(marks.count) 张")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))

            if !marks.isEmpty {
                Text("预计可释放 \(byteText(markedBytes))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 1, green: 0.55, blue: 0.45))
            }

            Text("中途随时点「删除 N 张」直接删；不删的话，点「完成」会把它们带回列表")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    private var markedBytes: Int64 {
        list.filter { marks.contains($0.id) }
            .reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
    }

    // MARK: 行为

    private func upcoming(_ from: Int, _ count: Int) -> [PhotoItem] {
        guard from < list.count else { return [] }
        let end = min(from + count, list.count)
        return Array(list[from..<end])
    }

    private func commit(keep: Bool) {
        guard index < list.count, !busy else { return }
        busy = true

        let item = list[index]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        history.append(Decision(id: item.id, marked: !keep))
        if keep {
            marks.remove(item.id)
        } else {
            marks.insert(item.id)
        }
        // 判过就落盘。「记 id 不记下标」的全部意义都在这一行：
        // 下次进来按 id 找第一张没判过的，列表怎么变都不会错位。
        TriageProgressStore.shared.record(key: progressKey, judgedID: item.id, marked: !keep)

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

    /// 批量真删所有已标记的。删完从数组里拿掉这些张，index 回退到正确位置。
    private func deleteMany() {
        guard !marks.isEmpty, !busy else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let toDelete = list.filter { marks.contains($0.id) }
        let removed = toDelete.count
        onDeleteMany(toDelete)
        // 照片已经不在相册里了，进度里留着这些 id 只会越积越长
        TriageProgressStore.shared.remove(key: progressKey, ids: toDelete.map { $0.id })

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            let ids = Set(toDelete.map { $0.id })
            list.removeAll { ids.contains($0.id) }
            marks.removeAll()
            // 所有被删的都已经滑过去了（待删只能来自已经过目的张），
            // 直接往回退 removed 位。
            index = max(0, index - removed)
            // 下标全错位，撤销只对「标记」有意义，清空避免撤销把已删的「飞回来」。
            history.removeAll()
            fly = nil
            drag = .zero
            if index >= list.count { index = list.count }
        }

        busy = false
        showHint("已删除 \(removed) 张 · 30 天内可在「最近删除」恢复")
        TriageImageCache.shared.preload(upcoming(index, 4))
    }

    /// 隐藏**当前这一张**。和「待删」完全无关：待删是攒着一起删，这个是立刻挪走。
    ///
    /// 走系统的 `isHidden`：照片进「照片」App 的「已隐藏」相簿，有 Face ID 保护。
    /// 代价是 iOS 16 起第三方 App 读不回那个相簿，所以这里**不做撤销**——
    /// 撤销了也拿不回来（`PHAssetChangeRequest` 需要先拿到 asset，而它已经读不到了）。
    /// 提示里直接告诉用户去哪儿取消，比给一个假的撤销按钮诚实。
    private func hideCurrent() {
        guard index < list.count, !busy else { return }
        let item = list[index]
        guard let asset = PhotoLibraryService.shared.asset(withID: item.id) else {
            showHint("读不到这张，可能刚被系统清理")
            return
        }
        busy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        PhotoLibraryService.shared.setHidden(true, assets: [asset]) { ok, err in
            DispatchQueue.main.async {
                busy = false
                guard ok else {
                    showHint("隐藏失败：" + friendlyPhotoError(err))
                    return
                }

                // 从进度里摘掉而不是记成「判过」：它已经从相册里消失，
                // 留在 judged 里只是垃圾；万一用户以后在系统相册取消隐藏，
                // 重新扫回来时它应该重新出现、重新被问一次。
                TriageProgressStore.shared.remove(key: progressKey, ids: [item.id])
                marks.remove(item.id)
                noteHiddenCount(1)
                onHide?(item)

                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    list.removeAll { $0.id == item.id }
                    // 撤销链跨过被移除的项会整体错位，直接清空。
                    history.removeAll()
                    fly = nil
                    drag = .zero
                    if index >= list.count { index = list.count }
                }
                showHint("已隐藏 · 去「照片」App 的「已隐藏」可取消")
                TriageImageCache.shared.preload(upcoming(index, 4))
            }
        }
    }

    private func undo() {
        guard !busy, let last = history.popLast() else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        marks.remove(last.id)
        TriageProgressStore.shared.forget(key: progressKey, id: last.id)

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.2)) {
                if hint == text { hint = nil }
            }
        }
    }

    private func finish() {
        // 退出时兜底落盘：攒 2 秒的那一批可能还没写，用户手快关掉就丢了
        guard !finished else { return }
        finished = true
        TriageProgressStore.shared.flush()
        onFinish(marks)
        dismiss()
    }

    /// 清掉这份进度，从第一张重新看。照片本身一张不动，只是忘掉「看过哪几张」。
    private func resetToStart() {
        TriageProgressStore.shared.clear(key: progressKey)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            index = 0
            marks.removeAll()
            history.removeAll()
            fly = nil
            drag = .zero
            resumeFrom = 0
        }
        showHint("已从头开始")
        TriageImageCache.shared.preload(upcoming(0, 4))
    }
}
