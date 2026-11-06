import SwiftUI
import Photos
import UIKit
import AVFoundation
import Combine

// MARK: - 可缩放的单张大图

struct ZoomableImageView: View {
    let asset: PHAsset

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
                }
                bottomInfo
                actionBar
            }
        }
        .statusBarHidden(true)
        .onAppear { syncVideo() }
        .onChange(of: index) { _ in syncVideo() }
        .onDisappear { video.stop() }
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
