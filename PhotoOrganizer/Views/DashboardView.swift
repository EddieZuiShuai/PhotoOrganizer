import SwiftUI

// MARK: - 体积格式化

func byteText(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 MB" }
    let kb = Double(bytes) / 1024.0
    let mb = kb / 1024.0
    let gb = mb / 1024.0
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    return String(format: "%.0f KB", kb)
}

// MARK: - 时间窗口

enum TimeWindow: String, CaseIterable, Identifiable {
    case all = "全部时间"
    case last7 = "近 7 天"
    case last30 = "近 30 天"
    case thisYear = "今年"
    case lastYear = "去年"
    case older = "更早"

    var id: String { rawValue }

    func contains(_ date: Date?) -> Bool {
        guard self != .all else { return true }
        guard let d = date else { return false }
        let cal = Calendar.current
        let now = Date()

        switch self {
        case .all:
            return true
        case .last7:
            let start = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return d >= start
        case .last30:
            let start = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return d >= start
        case .thisYear:
            return cal.component(.year, from: d) == cal.component(.year, from: now)
        case .lastYear:
            return cal.component(.year, from: d) == cal.component(.year, from: now) - 1
        case .older:
            let year = cal.component(.year, from: now) - 1
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            return d < start
        }
    }
}

// MARK: - 相册

struct AlbumOption: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

// MARK: - 筛选面板

struct FilterSheet: View {
    @Binding var period: TimeWindow
    @Binding var album: AlbumOption?
    let albums: [AlbumOption]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TimeWindow.allCases) { w in
                        row(title: w.rawValue, selected: period == w) {
                            period = w
                        }
                    }
                } header: {
                    Text("时间段")
                }

                Section {
                    row(title: "全部相册", selected: album == nil) {
                        album = nil
                    }
                    ForEach(albums) { a in
                        row(title: "\(a.title)（\(a.count)）", selected: album?.id == a.id) {
                            album = a
                        }
                    }
                } header: {
                    Text("相册")
                } footer: {
                    Text("筛选只影响显示，不会改动照片。已勾选的照片不会因为切换筛选而丢失。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Color(red: 0.18, green: 0.49, blue: 0.96))
                }
            }
        }
    }
}

// MARK: - 空间看板

struct CatRow: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let count: Int
}

struct SpaceDashboardView: View {
    let totalBytes: Int64
    let photoBytes: Int64
    let videoBytes: Int64
    let suggestedBytes: Int64
    let duplicateWasteBytes: Int64
    let freedBytes: Int64
    let deletedCount: Int
    let categoryRows: [CatRow]
    let onGoLarge: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                // 以前这是一个 sheet，标题靠系统的 navigationTitle；
                // 改成底部 tab 之后没有导航栏了，标题自己画。
                HStack {
                    Text("空间看板")
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                }
                .padding(.top, 6)

                VStack(spacing: 4) {
                    Text("相册总共占用")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        Text(byteText(totalBytes))
                            .font(.system(size: 34, weight: .semibold))
                        Text("照片 \(byteText(photoBytes)) · 视频 \(byteText(videoBytes))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(red: 0.18, green: 0.49, blue: 0.96).opacity(0.08))
                    .cornerRadius(14)

                    HStack(spacing: 10) {
                        statCard(title: "已释放", value: byteText(freedBytes), sub: "已删 \(deletedCount) 张", color: Color(red: 0.2, green: 0.6, blue: 0.4))
                        statCard(title: "建议清理", value: byteText(suggestedBytes), sub: "智能评过分", color: Color(red: 0.85, green: 0.35, blue: 0.2))
                        statCard(title: "重复可省", value: byteText(duplicateWasteBytes), sub: "每组留一张", color: Color(red: 0.85, green: 0.55, blue: 0.15))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("占用分布")
                            .font(.system(size: 14, weight: .semibold))

                        let maxBytes = categoryRows.map { $0.bytes }.max() ?? 0
                        ForEach(categoryRows) { row in
                            barRow(row, maxBytes: maxBytes)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(14)

                    Button {
                        onGoLarge()
                    } label: {
                        Text("去看大文件（可压视频）")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.18, green: 0.49, blue: 0.96))
                            .cornerRadius(12)
                    }

                    Text("「已释放」只统计本次打开 App 后删掉的部分；系统「最近删除」里 30 天后才真正腾出空间。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 20)
            }
            .padding(16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
    }

    private func statCard(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(sub)
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white)
        .cornerRadius(12)
    }

    private func barRow(_ row: CatRow, maxBytes: Int64) -> some View {
        let ratio: CGFloat = maxBytes > 0 ? CGFloat(Double(row.bytes) / Double(maxBytes)) : 0
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 12))
                Text("\(row.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(byteText(row.bytes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.05))
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.49, blue: 0.96).opacity(0.75))
                        .frame(width: max(3, geo.size.width * ratio))
                }
            }
            .frame(height: 7)
        }
    }
}
