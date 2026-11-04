import SwiftUI
import Photos
import UIKit

// MARK: - 卡片里的图

struct TriageImage: View {
    let asset: PHAsset

    @State private var image: UIImage?

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
                    ProgressView()
                }
            }
            .onAppear { load(geo.size) }
        }
    }

    private func load(_ size: CGSize) {
        guard image == nil, size.width > 1 else { return }
        let scale = UIScreen.main.scale
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        PhotoLibraryService.shared.loadImage(for: asset, targetSize: target) { img in
            DispatchQueue.main.async {
                if let img = img { self.image = img }
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
    @State private var history: [Decision] = []
    @State private var marks: Set<String> = []

    private struct Decision {
        let id: String
        let marked: Bool
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
        }
        .statusBarHidden(true)
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

    // MARK: 卡片

    private var cardStack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                if index + 2 < items.count {
                    cardBody(items[index + 2], width: w)
                        .scaleEffect(0.90)
                        .offset(y: 26)
                        .opacity(0.45)
                }
                if index + 1 < items.count {
                    cardBody(items[index + 1], width: w)
                        .scaleEffect(0.95)
                        .offset(y: 13)
                        .opacity(0.75)
                }
                cardBody(items[index], width: w)
                    .overlay(alignment: .topLeading) {
                        stamp("保留", color: Color(red: 0.25, green: 0.75, blue: 0.45), show: drag.width > 26)
                    }
                    .overlay(alignment: .topTrailing) {
                        stamp("删除", color: Color(red: 0.95, green: 0.3, blue: 0.25), show: drag.width < -26)
                    }
                    .offset(x: drag.width, y: drag.height * 0.28)
                    .rotationEffect(.degrees(Double(drag.width) / 26))
                    .gesture(dragGesture)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 20)
    }

    private func cardBody(_ item: PhotoItem, width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            TriageImage(asset: item.asset)

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

    private func stamp(_ text: String, color: Color, show: Bool) -> some View {
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
            .opacity(show ? 1 : 0)
            .padding(22)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                drag = value.translation
            }
            .onEnded { value in
                if value.translation.width > 100 {
                    commit(keep: true)
                } else if value.translation.width < -100 {
                    commit(keep: false)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        drag = .zero
                    }
                }
            }
    }

    // MARK: 按钮

    private var actionButtons: some View {
        HStack(spacing: 24) {
            roundButton(icon: "arrow.uturn.backward", label: "撤销",
                        bg: Color.white.opacity(0.14), enabled: !history.isEmpty) {
                undo()
            }
            roundButton(icon: "checkmark", label: "保留",
                        bg: Color(red: 0.2, green: 0.62, blue: 0.36), enabled: true) {
                commit(keep: true)
            }
            roundButton(icon: "trash", label: "删除",
                        bg: Color(red: 0.85, green: 0.24, blue: 0.2), enabled: true) {
                commit(keep: false)
            }
        }
        .padding(.top, 6)
    }

    private func roundButton(icon: String, label: String, bg: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
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

    private func commit(keep: Bool) {
        guard index < items.count else { return }
        let item = items[index]
        let marked = !keep

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        history.append(Decision(id: item.id, marked: marked))
        if marked {
            marks.insert(item.id)
        } else {
            marks.remove(item.id)
        }

        withAnimation(.easeOut(duration: 0.22)) {
            drag = CGSize(width: keep ? 900 : -900, height: drag.height)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            drag = .zero
            index += 1
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        marks.remove(last.id)
        drag = .zero
        index = max(0, index - 1)
    }

    private func finish() {
        onFinish(marks)
        dismiss()
    }
}
