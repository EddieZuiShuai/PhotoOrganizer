import SwiftUI
import Photos
import UIKit

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

// MARK: - 全屏浏览（左右滑动 + 双指放大 + 双击放大 + 删除）

struct PhotoPreviewView: View {
    let items: [PhotoItem]
    let onDelete: (PhotoItem) -> Void

    @State private var index: Int

    @Environment(\.dismiss) private var dismiss

    init(items: [PhotoItem], startIndex: Int, onDelete: @escaping (PhotoItem) -> Void) {
        self.items = items
        self._index = State(initialValue: max(0, min(startIndex, max(0, items.count - 1))))
        self.onDelete = onDelete
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
                        ZoomableImageView(asset: item.asset)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                bottomInfo
            }
        }
        .statusBarHidden(true)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }

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

            // 一步删除：点一下直接交给系统，不再问第二遍
            Button {
                guard index >= 0, index < items.count else { return }
                let item = items[index]
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onDelete(item)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.red.opacity(0.8)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var bottomInfo: some View {
        if index >= 0, index < items.count {
            let item = items[index]
            VStack(spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(item.resolutionText)
                    if !item.sizeText.isEmpty {
                        Text("·")
                        Text(item.sizeText)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            }
            .foregroundColor(.white)
            .padding(.bottom, 28)
        }
    }
}
