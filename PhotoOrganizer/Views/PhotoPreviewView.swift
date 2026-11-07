import SwiftUI
import Photos
import PhotosUI
import UIKit
import AVFoundation
import Combine

// MARK: - 可缩放的单张大图

struct ZoomableImageView: View {
    let asset: PHAsset
    /// Live 播放的那几秒把缩放手势关掉：动态层不跟着缩放，
    /// 这时候还允许捏合，会看到「画面在动但尺寸不对」的错位。
    var interactionEnabled: Bool = true

    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let image = image {
                    imageLayer(image: image, geo: geo)
                } else if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 26))
                        Text("这张照片读取失败（可能只存在 iCloud 上）")
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white.opacity(0.65))
                    .padding(30)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { load(size: geo.size) }
            .allowsHitTesting(interactionEnabled)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func imageLayer(image: UIImage, geo: GeometryProxy) -> some View {
        if scale > 1.01 {
            baseImage(image).simultaneousGesture(pan(geo: geo))
        } else {
            baseImage(image)
        }
    }

    private func baseImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify)
            .onTapGesture(count: 2) { toggleZoom() }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 6)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { reset() }
            }
    }

    private func pan(geo: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                let maxX = geo.size.width * (scale - 1) / 2 + 30
                let maxY = geo.size.height * (scale - 1) / 2 + 30
                let nx = min(max(lastOffset.width + value.translation.width, -maxX), maxX)
                let ny = min(max(lastOffset.height + value.translation.height, -maxY), maxY)
                offset = CGSize(width: nx, height: ny)
            }
            .onEnded { _ in
                if scale > 1.01 {
                    lastOffset = offset
                } else {
                    offset = .zero
                    lastOffset = .zero
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1.01 {
                reset()
            } else {
                scale = 2.5
                lastScale = 2.5
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func load(size: CGSize) {
        guard image == nil else { return }
        let screenScale = UIScreen.main.scale
        let target = CGSize(width: max(size.width, 1) * screenScale,
                            height: max(size.height, 1) * screenScale)
        PhotoLibraryService.shared.loadImage(for: asset, targetSize: target) { img in
            DispatchQueue.main.async {
                if let img = img {
                    self.image = img
                } else {
                    self.failed = true
                }
            }
        }
    }
}

// MARK: - 视频播放（自己画播放器，不用系统控制条，避免抢走左右翻页手势）

/// AVPlayerLayer 的宿主视图：没有系统控制条，所以左右滑动仍然能翻页
private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

// MARK: - Live 照片（PHLivePhotoView 封装）

/// Live 照片的播放状态。
///
/// 和视频共用同一套心智：进场自动播一次、默认静音、播完停在定格不循环、
/// 点按钮重播一次。区别只有两点：Live 没有进度条（一共三秒），
/// 以及「重播」长成一个 LIVE 胶囊。
///
/// 指令用 token 传，不直接持有 UIView：SwiftUI 每次重建都换实例，
/// 存引用会在翻页后指向一个已经不在屏幕上的 view。token 是纯数据，
/// 谁挂上去谁执行，翻页和重建都不会错位。
final class LivePhotoModel: ObservableObject {
    /// 静音在**一次预览会话内共享**：视频里开过声音，翻到 Live 也有声。
    @Published var isMuted = true
    @Published private(set) var isPlaying = false
    /// 当前页的动态部分有没有装上。没装上（iCloud 没下来 / 只有静帧）就不显示 LIVE 按钮。
    @Published private(set) var isReady = false

    /// 每 +1 = 「播一次」。UIViewRepresentable 在 updateUIView 里比对这两个数。
    @Published fileprivate(set) var playToken = 0
    /// 每 +1 = 「停下并释放」
    @Published fileprivate(set) var stopToken = 0

    func playOnce() {
        guard isReady else { return }
        playToken &+= 1
    }

    func stop() {
        stopToken &+= 1
        isPlaying = false
    }

    func reset() {
        stop()
        isReady = false
    }

    func markReady(_ ready: Bool) {
        isReady = ready
        if !ready { isPlaying = false }
    }

    fileprivate func setPlaying(_ value: Bool) {
        if isPlaying != value { isPlaying = value }
    }

    func toggleMute() {
        isMuted.toggle()
    }
}

/// PHLivePhotoView 的 SwiftUI 包装。
///
/// ⚠️ 两个必须做的手势隔离：
/// 1. `isUserInteractionEnabled = false` —— PHLivePhotoView 自带一个
///    `playbackGestureRecognizer`，留着它会把 TabView 的翻页和双指缩放全吃掉。
/// 2. `playbackGestureRecognizer.isEnabled = false` —— 兜底，有些系统版本上
///    只关交互它仍然会参与手势仲裁。
/// 播放一律由我们主动下指令，不依赖用户手势。
struct LivePhotoSurface: UIViewRepresentable {
    let photo: PHLivePhoto
    @ObservedObject var model: LivePhotoModel

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.isMuted = model.isMuted
        view.isUserInteractionEnabled = false
        view.playbackGestureRecognizer.isEnabled = false
        view.delegate = context.coordinator
        view.livePhoto = photo
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let c = context.coordinator

        if view.livePhoto !== photo {
            view.livePhoto = photo
            // 换了一条 Live：把游标对齐到当前 token，
            // 否则上一页残留的 playToken 会把这新的一条立刻播起来。
            c.lastPlay = model.playToken
            c.lastStop = model.stopToken
        }

        if view.isMuted != model.isMuted {
            view.isMuted = model.isMuted
        }

        // 先 stop 再 play。从一张 Live 划到另一张时，上一页的 stop
        // 和这一页的 play 可能落在同一帧里，顺序反了就变成「刚播就停」。
        if c.lastStop != model.stopToken {
            c.lastStop = model.stopToken
            view.stopPlayback(animated: false)
        }

        if c.lastPlay != model.playToken {
            c.lastPlay = model.playToken
            // 先 stop 归零：不加这句，播放中再点会「接着播」而不是从头重播。
            view.stopPlayback(animated: false)
            view.startPlayback(with: .full)
            DispatchQueue.main.async {
                self.model.setPlaying(true)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        private let model: LivePhotoModel
        fileprivate var lastPlay = 0
        fileprivate var lastStop = 0

        init(model: LivePhotoModel) {
            self.model = model
        }

        /// `.full` 播完就停，不会循环；这里只负责把按钮状态改回来。
        func livePhotoView(
            _ livePhotoView: PHLivePhotoView,
            didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle,
            animated: Bool
        ) {
            DispatchQueue.main.async {
                self.model.setPlaying(false)
            }
        }
    }
}

/// 取一段 Live 的动态部分。
///
/// 尺寸给「屏幕点 × scale」：给小了发糊，给大了首帧明显变慢。
/// `isNetworkAccessAllowed` 必须开——只存在 iCloud 上的 Live 才会自动下载，
/// 否则用户看到的永远是定格，还以为是 App 坏了。
enum LivePhotoLoader {
    static func load(asset: PHAsset, completion: @escaping (PHLivePhoto?) -> Void) {
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let target = CGSize(width: max(screen.width, 1) * scale,
                            height: max(screen.height, 1) * scale)
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { photo, _ in
            DispatchQueue.main.async {
                completion(photo)
            }
        }
    }
}

/// 全屏预览里的一页 Live：静帧照常可缩放，动态层叠在上面，只在播放的那几秒显示。
///
/// 只给「当前这一页」装载：一段 Live 的视频轨 2~5MB，一排全装必爆内存。
private struct LivePhotoStage: View {
    let asset: PHAsset
    let isActive: Bool
    @ObservedObject var model: LivePhotoModel

    @State private var photo: PHLivePhoto?
    @State private var loading = false
    /// 加载是异步的，翻页后回来的结果必须丢掉
    @State private var token = UUID()

    var body: some View {
        ZStack {
            ZoomableImageView(asset: asset, interactionEnabled: !model.isPlaying)

            if let photo = photo {
                LivePhotoSurface(photo: photo, model: model)
                    .opacity(model.isPlaying ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.14), value: model.isPlaying)
            }
        }
        .onAppear {
            if isActive { start() }
        }
        .onChange(of: isActive) { active in
            if active { start() } else { teardown() }
        }
    }

    private func start() {
        model.stop()
        model.markReady(false)
        guard photo == nil, !loading else {
            // 已经装好了（比如划走又划回来），直接补一次播放
            if photo != nil {
                model.markReady(true)
                model.playOnce()
            }
            return
        }
        loading = true
        let myToken = UUID()
        token = myToken

        LivePhotoLoader.load(asset: asset) { loaded in
            guard token == myToken else { return }
            loading = false
            guard let loaded = loaded else { return }   // 只有静帧：静默降级成普通照片
            photo = loaded
            model.markReady(true)
            // 取图可能要几秒（iCloud）。用户早划走了就别突然动起来。
            guard isActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                model.playOnce()
            }
        }
    }

    private func teardown() {
        model.reset()
        token = UUID()
        loading = false
        // 释放视频轨。不置 nil 的话，划过的每一张 Live 都会一直占着内存。
        photo = nil
    }
}

/// 只维护「当前这一页」的一个播放器：翻页时把上一段的播放器换掉，不会同时开好几个。
final class VideoPlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loadedAssetID: String?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var failed = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 默认静音。全屏预览的语义是「看一眼这张是什么」，不是「我要听」；
    /// 而且这个页面在清理、分类、大文件三个入口共用，突然外放很尴尬。
    /// 与逐张过（`TriageVideoBox`）对齐成同一套心智：静音进场，想听再点喇叭。
    ///
    /// 注意这里只在**本次预览会话内**记住用户的选择：手动开过声音后翻到下一段
    /// 仍然有声（`stop()` 不清这个值），关掉重开才回到静音默认。
    @Published var isMuted = true

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var token = UUID()

    // MARK: 装载

    func load(asset: PHAsset) {
        guard loadedAssetID != asset.localIdentifier else { return }

        stop()
        loadedAssetID = asset.localIdentifier
        let current = UUID()
        token = current
        isLoading = true
        failed = false
        duration = asset.duration
        currentTime = 0

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true      // 存在 iCloud 上的视频会自动下载
        options.deliveryMode = .automatic

        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
            DispatchQueue.main.async {
                // 已经被后来的翻页请求取代，丢弃这次结果
                guard self.token == current else { return }
                self.isLoading = false

                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }

                guard let item = item else {
                    self.failed = true
                    return
                }

                let player = AVPlayer(playerItem: item)
                player.actionAtItemEnd = .pause
                let seconds = CMTimeGetSeconds(item.asset.duration)
                if seconds.isFinite && seconds > 0 {
                    self.duration = seconds
                }
                self.attach(player)
                self.play()
            }
        }
    }

    /// 离开这一页 / 关掉预览时调用
    func stop() {
        pause()
        detachObservers()
        player = nil
        loadedAssetID = nil
        currentTime = 0
        duration = 0
        isLoading = false
        failed = false
    }

    // MARK: 播放控制

    func play() {
        guard let player = player else { return }
        // 静音时不去激活音频会话：`.playback` 一旦 setActive 就会掐掉用户
        // 正在听的音乐/播客。默认就是静音，白白打断别人不合理。
        if !isMuted { activateAudioSession() }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            // 播完了再点播，从头开始
            if duration > 0, currentTime >= duration - 0.15 {
                player?.seek(to: .zero)
                currentTime = 0
            }
            play()
        }
    }

    func seek(to seconds: Double) {
        guard let player = player, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        // 只有「正在播 + 刚切到有声」才抢音频会话。
        // 暂停状态下开声音不该打断别人的背景音乐——等按播放时 play() 再去激活。
        if !isMuted && isPlaying { activateAudioSession() }
    }

    // MARK: 内部

    private func attach(_ player: AVPlayer) {
        detachObservers()
        self.player = player
        player.isMuted = isMuted

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = self?.duration ?? 0
        }
    }

    private func detachObservers() {
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    /// 视频要出声，就不能用 ambient（会被静音拨片吞掉）
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }
}

/// 单个视频页：没轮到它时只显示封面，轮到才把播放器挂上去
private struct VideoStage: View {
    let asset: PHAsset
    let isActive: Bool
    @ObservedObject var model: VideoPlaybackModel

    @State private var poster: UIImage?
    @State private var posterFailed = false

    private var player: AVPlayer? {
        model.loadedAssetID == asset.localIdentifier ? model.player : nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let player = player {
                    PlayerSurface(player: player)
                } else if let poster = poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(
                            // 封面上的播放角标，提示这是视频不是照片
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 46))
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.4), radius: 8)
                        )
                } else if posterFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 26))
                        Text("这段视频读取失败（可能只存在 iCloud 上）")
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white.opacity(0.65))
                    .padding(30)
                } else {
                    ProgressView().tint(.white)
                }

                if model.isLoading && isActive {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .task { loadPoster() }
    }

    private func loadPoster() {
        guard poster == nil else { return }
        let size = UIScreen.main.bounds.size
        let target = CGSize(width: size.width * UIScreen.main.scale,
                            height: size.height * UIScreen.main.scale)
        PhotoLibraryService.shared.loadImage(for: asset, targetSize: target) { img in
            DispatchQueue.main.async {
                if let img = img {
                    poster = img
                } else {
                    posterFailed = true
                }
            }
        }
    }
}

// MARK: - 全屏浏览（左右滑 + 双指放大 + 双击放大 + 视频播放 + 标记/删除）

struct PhotoPreviewView: View {
    let items: [PhotoItem]
    @Binding var selectedIDs: Set<String>
    let onDelete: (PhotoItem) -> Void

    @State private var index: Int
    @StateObject private var video = VideoPlaybackModel()
    @StateObject private var live = LivePhotoModel()

    @Environment(\.dismiss) private var dismiss

    init(items: [PhotoItem], startIndex: Int, selectedIDs: Binding<Set<String>>, onDelete: @escaping (PhotoItem) -> Void) {
        self.items = items
        self._selectedIDs = selectedIDs
        self._index = State(initialValue: max(0, min(startIndex, max(0, items.count - 1))))
        self.onDelete = onDelete
    }

    private var current: PhotoItem? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    private var marked: Bool {
        guard let item = current else { return false }
        return selectedIDs.contains(item.id)
    }

    private var isVideoPage: Bool {
        current?.isVideo ?? false
    }

    private var isLivePage: Bool {
        guard let item = current else { return false }
        return !item.isVideo && item.isLivePhoto
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if items.isEmpty {
                Text("没有可显示的照片")
                    .foregroundColor(.white.opacity(0.7))
            } else {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        if item.isVideo {
                            VideoStage(asset: item.asset, isActive: idx == index, model: video)
                                .tag(idx)
                        } else if item.isLivePhoto {
                            LivePhotoStage(asset: item.asset, isActive: idx == index, model: live)
                                .tag(idx)
                        } else {
                            ZoomableImageView(asset: item.asset)
                                .tag(idx)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                if isVideoPage {
                    videoControls
                } else if isLivePage {
                    liveControls
                }
                bottomInfo
                actionBar
            }
        }
        .statusBarHidden(true)
        .onAppear { syncVideo() }
        .onChange(of: index) { _ in syncVideo() }
        // 静音是「这次预览」的偏好，不是某一段视频的：视频里开过声音，
        // 翻到 Live 也该有声，反过来也一样。两边互为镜像，值相同就不再写，
        // 所以不会来回震荡。
        .onChange(of: video.isMuted) { value in
            if live.isMuted != value { live.isMuted = value }
        }
        .onChange(of: live.isMuted) { value in
            if video.isMuted != value { video.isMuted = value }
        }
        .onDisappear {
            video.stop()
            live.reset()
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button {
                video.stop()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("preview-close")

            Spacer()

            if !items.isEmpty {
                Text("\(index + 1) / \(items.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }

            Spacer()

            Text(selectedIDs.isEmpty ? "—" : "已选 \(selectedIDs.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(selectedIDs.isEmpty ? .white.opacity(0.5) : Color(red: 1, green: 0.55, blue: 0.5))
                .frame(width: 58, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: 视频控制条（只在当前页是视频时出现）

    private var videoControls: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text(timeText(video.currentTime))
                    .frame(width: 40, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { video.duration > 0 ? min(video.currentTime, video.duration) : 0 },
                        set: { video.seek(to: $0) }
                    ),
                    in: 0...max(video.duration, 0.1)
                )
                .tint(.white)
                .accessibilityLabel("视频进度")

                Text(timeText(video.duration))
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.8))

            HStack(spacing: 16) {
                Button {
                    video.togglePlay()
                } label: {
                    Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .accessibilityLabel(video.isPlaying ? "暂停" : "播放")

                Button {
                    video.toggleMute()
                } label: {
                    Image(systemName: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .accessibilityLabel(video.isMuted ? "取消静音" : "静音")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Live 控制条（只在当前页是 Live 照片时出现）

    /// 没有进度条：Live 一共三秒，给个滑块只会挡画面。
    /// 只留「重播」和「喇叭」，位置和视频那颗播放键对齐，切页时不会跳。
    private var liveControls: some View {
        HStack(spacing: 16) {
            Button {
                // 播放中再点也是「从头再播」——这个按钮的语义是重播，不是暂停。
                live.playOnce()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "livephoto")
                        .font(.system(size: 14, weight: .semibold))
                    Text("LIVE")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(live.isPlaying ? 0.30 : 0.16)))
                .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(!live.isReady)
            .opacity(live.isReady ? 1 : 0.45)
            .accessibilityLabel("重播 Live 照片")
            .accessibilityIdentifier("live-replay")

            Button {
                live.toggleMute()
            } label: {
                Image(systemName: live.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live.isMuted ? "取消静音" : "静音")
            .accessibilityIdentifier("live-mute")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: 底部信息

    @ViewBuilder
    private var bottomInfo: some View {
        if let item = current {
            VStack(spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if item.isVideo {
                        Text("视频 " + timeText(item.asset.duration))
                    } else {
                        Text(item.resolutionText)
                        if item.isLivePhoto {
                            Text("·")
                            Text("LIVE")
                                .fontWeight(.semibold)
                        }
                    }
                    if !item.sizeText.isEmpty {
                        Text("·")
                        Text(item.sizeText)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))

                if marked {
                    Text("已标记待删")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(.top, 4)
                }
            }
            .foregroundColor(.white)
            .padding(.bottom, 12)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                toggleMark()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                    Text(marked ? "取消标记" : "标记待删")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(marked ? Color.white.opacity(0.28) : Color.white.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .accessibilityLabel(marked ? "取消标记待删" : "标记待删")
            .accessibilityIdentifier("preview-mark")

            Button {
                deleteNow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                    Text("立即删除")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.red.opacity(0.9))
                )
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .accessibilityLabel("立即删除")
            .accessibilityIdentifier("preview-delete")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
        .padding(.top, 4)
    }

    // MARK: 行为

    /// 翻到哪一页就只保留那一段视频的播放器，别的页一律释放
    private func syncVideo() {
        guard let item = current, item.isVideo else {
            video.stop()
            return
        }
        video.load(asset: item.asset)
    }

    private func toggleMark() {
        guard let item = current else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// 一步删除：点一下交给系统，只剩 iOS 自己那一次确认
    private func deleteNow() {
        guard let item = current else { return }
        video.stop()
        selectedIDs.remove(item.id)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDelete(item)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
