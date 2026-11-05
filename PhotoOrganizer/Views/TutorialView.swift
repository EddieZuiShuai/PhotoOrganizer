import SwiftUI

/// 新手教程（1.5 新增）。
///
/// 设计口径见 `docs/onboarding-spec.md`，这里只写实现。几条不能改的：
/// - 5 页，每页「动作式标题 / 假 UI 示意图 / 一句记忆句」；
/// - 示意图全部用组件现画，**不引用 `AnalysisResult`**——
///   教程必须能在「没授权、没扫描、一条数据都没有」的时候正常显示；
/// - 翻到最后一页才写 `tutorialSeenVersion`，中途关掉不算看过。
struct TutorialView: View {
    /// 没扫过的人最后一页给「开始扫描」，扫过的人给「知道了」
    var hasScanned: Bool = false
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    /// 存版本号而不是 Bool：1.6 要再引导一次，改这个值就行，不用加新键。
    @AppStorage("tutorialSeenVersion") private var seenVersion: String = ""

    @State private var page: Int = 0

    private let blue = Color(red: 0.18, green: 0.49, blue: 0.96)

    private var pages: [(title: String, body: String, memo: String)] {
        [
            (
                "先让它扫完，中途别锁屏",
                "第一段一两分钟就出结果，看到清单就能开始挑；第二段在后台补内容分类，顶部横幅「正在识别内容 x%」走完才算全部完成。这期间锁屏、切到别的 App，会掐断正在识别的那几张。",
                "第二次扫描只要几十秒——没改过的照片直接读上次结果。"
            ),
            (
                "百分比是「可疑度」，不是「该删的概率」",
                "80% 只表示这张同时命中了几个可疑特征，不代表八成该删。重复组最可信（原图字节完全一样）；相似看清晰度；模糊统一跟全库中位数比，阴天、夜景天然偏低。",
                "先看「重复」，这一组几乎不会错；再从建议清理最上面往下走。"
            ),
            (
                "点一下是选中，红色按钮才是删",
                "选中会跨标签保留——在「重复」里选几张、切到「相似」再选几张，底部数字会累加。超过 500 张会先问一次。删掉的照片在「照片」App 的最近删除里留 30 天，可以恢复。",
                "扫描本身不改任何照片；只有你点删除，才会真的删。"
            ),
            (
                "左滑是「标记」，不是删",
                "右滑保留、左滑标记待删，底下的深红「删除」才是立刻删（会先问一次，删完不退出，继续下一张）。标记只是暂存，回列表点红按钮才真删。视频点封面中间就能播，默认静音，划走自动停。",
                "真删不能在这一页撤销——删一张会让后面的位置全部前移，做半残的撤销不如不做。"
            ),
            (
                "四个 tab，各管一件事",
                "清理=干活的地方；分类=一屏看全各类多少张，点进去就地挑；空间=谁在吃空间；我的=开关、缓存、权限、版本。隐私是单独一类，判定口径是「排除人脸之后、身体上还剩多少裸露皮肤」，它不进建议清理，全选也带不走。",
                "隐私组误判很正常，最终点删除的永远是你自己。"
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: "%02d / %02d", page + 1, pages.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭新手教程")
                .accessibilityIdentifier("tutorial-close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(index)
                        .tag(index)
                }
            }
            // 这里用系统 TabView 是安全的，别被「底部四 tab 不能用 TabView」那条误导：
            // 那条的理由是切走会销毁页面、丢 selectedIDs；教程页是纯静态内容，销毁不丢任何东西。
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
                .padding(.bottom, 14)

            Button {
                if page + 1 < pages.count {
                    withAnimation(.easeInOut(duration: 0.22)) { page += 1 }
                } else {
                    seenVersion = appShortVersion()
                    onFinish()
                    dismiss()
                }
            } label: {
                Text(page + 1 < pages.count ? "下一步" : (hasScanned ? "知道了" : "开始扫描"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(blue)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .accessibilityIdentifier(page + 1 < pages.count ? "tutorial-next" : "tutorial-done")
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
    }

    // MARK: - 单页

    @ViewBuilder
    private func pageView(_ index: Int) -> some View {
        let item = pages[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.body)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                mock(index)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .cornerRadius(14)

                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(blue)
                        .frame(width: 3)
                    Text(item.memo)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .background(Color(red: 0.93, green: 0.95, blue: 0.99))
                .cornerRadius(10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? blue : Color.black.opacity(0.14))
                    .frame(width: i == page ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }

    // MARK: - 示意图（全部假数据，不读相册）

    @ViewBuilder
    private func mock(_ index: Int) -> some View {
        switch index {
        case 0: ScanMock()
        case 1: StatsMock()
        case 2: SelectMock()
        case 3: SwipeMock()
        default: TabBarMock()
        }
    }
}

private func appShortVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5"
}

// MARK: - 五个示意图

private struct MockShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ScanMock: View {
    private let blue = Color(red: 0.18, green: 0.49, blue: 0.96)
    private let gray = Color.black.opacity(0.09)

    var body: some View {
        MockShell {
            HStack(spacing: 5) {
                Circle().fill(blue).frame(width: 6, height: 6)
                Text("正在识别内容 43%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(blue)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(blue.opacity(0.1)))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(gray)
                    Capsule().fill(blue).frame(width: geo.size.width * 0.43)
                }
            }
            .frame(height: 3)
            .padding(.top, 2)

            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4).fill(gray).frame(height: 42)
                        RoundedRectangle(cornerRadius: 2).fill(gray.opacity(0.6)).frame(height: 5)
                    }
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }
}

private struct StatsMock: View {
    private let gray = Color.black.opacity(0.09)
    private let red = Color(red: 0.85, green: 0.25, blue: 0.2)

    var body: some View {
        MockShell {
            HStack(spacing: 8) {
                stat("128", "建议清理", red)
                stat("6", "重复组", Color(red: 0.85, green: 0.45, blue: 0.15))
                stat("32", "发票", Color(red: 0.2, green: 0.55, blue: 0.4))
                stat("91", "截图", Color(red: 0.4, green: 0.45, blue: 0.5))
            }

            HStack(spacing: 6) {
                ForEach(["重复", "相似", "模糊", "大文件"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(gray))
                }
                Spacer()
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

    private func stat(_ value: String, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(gray.opacity(0.5))
        .cornerRadius(8)
    }
}

private struct SelectMock: View {
    private let blue = Color(red: 0.18, green: 0.49, blue: 1.0)
    private let gray = Color.black.opacity(0.1)

    var body: some View {
        MockShell {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { row in
                    VStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { col in
                            let on = (row == 0 && col == 0) || (row == 1 && col == 2)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(gray)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(on ? blue : Color.clear, lineWidth: 2)
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    if on {
                                        Circle().fill(blue).frame(width: 10, height: 10).padding(2)
                                    }
                                }
                                .frame(height: 44)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Text("删除 2 张")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.25, blue: 0.2)))
            }
            .padding(.top, 6)
        }
    }
}

private struct SwipeMock: View {
    private let gray = Color.black.opacity(0.1)

    var body: some View {
        MockShell {
            RoundedRectangle(cornerRadius: 8)
                .fill(gray)
                .frame(height: 96)
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.9))
                )

            HStack(spacing: 6) {
                pill("撤销", Color.black.opacity(0.35))
                pill("保留", Color(red: 0.2, green: 0.62, blue: 0.36))
                pill("标记", Color(red: 0.9, green: 0.5, blue: 0.1))
                pill("删除", Color(red: 0.85, green: 0.25, blue: 0.2))
            }
            .padding(.top, 8)

            Text("左滑 = 标记，不是删")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 2)

            Spacer(minLength: 0)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
    }
}

private struct TabBarMock: View {
    private let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    private let items: [(String, String)] = [
        ("sparkles", "清理"), ("square.grid.2x2", "分类"),
        ("internaldrive", "空间"), ("person.crop.circle", "我的")
    ]

    var body: some View {
        MockShell {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.08))
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.black.opacity(0.08))
                                .frame(width: 90, height: 7)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.black.opacity(0.05))
                                .frame(width: 56, height: 6)
                        }
                        Spacer()
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ForEach(items, id: \.1) { icon, name in
                    VStack(spacing: 3) {
                        Image(systemName: icon).font(.system(size: 13))
                        Text(name).font(.system(size: 9))
                    }
                    .foregroundColor(name == "分类" ? blue : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5)
            }
        }
    }
}
