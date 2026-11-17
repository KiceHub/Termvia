import SwiftUI
import TermviaCore

struct TransferRows: View {
    @ObservedObject var model: AppModel
    private static let timestamp: DateFormatter = { let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH:mm:ss"; return format }()
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.activeTransfers) { item in
                    HStack(spacing: 10) {
                        Text(item.startedAt.map(Self.timestamp.string) ?? "—").monospacedDigit().frame(width: 145, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.upload ? item.local + " → " + item.remote : item.remote + " → " + item.local)
                                .lineLimit(1).truncationMode(.middle).help(item.detail.isEmpty ? item.remote : item.detail)
                            if ["传输中", "已暂停"].contains(item.state) {
                                Group {
                                    if item.totalBytes > 0 {
                                        ProgressView(value: Double(min(item.completedBytes, item.totalBytes)), total: Double(item.totalBytes))
                                    } else if item.state == "已暂停" { ProgressView(value: 0) }
                                    else { ProgressView() }
                                }.progressViewStyle(.linear).controlSize(.mini)
                                    .tint(item.state == "已暂停" ? .secondary : .accentColor).accessibilityLabel(T("传输"))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.totalBytes == 0 ? "—" : FileSizeDisplay.string(item.totalBytes)).monospacedDigit().frame(width: 65, alignment: .trailing)
                        if ["传输中", "已暂停"].contains(item.state) {
                            Text(item.state == "已暂停" ? T("已暂停") : ByteCountFormatter.string(fromByteCount: Int64(max(0, item.bytesPerSecond)), countStyle: .file) + "/s").monospacedDigit().frame(width: 90, alignment: .trailing)
                            Button { if item.state == "已暂停" { model.resumeTransfer(item.id) } else { model.pauseTransfer(item.id) } } label: { Image(systemName: item.state == "已暂停" ? "play.fill" : "pause.fill") }.help(T(item.state == "已暂停" ? "继续" : "暂停")).disabled(item.state == "已暂停" ? !model.canResumeTransfer(item) : !model.canPauseTransfer(item.id))
                            Button { model.cancel(item.id) } label: { Image(systemName: "xmark") }.help(T("取消"))
                        } else {
                            Text(T(item.state)).foregroundStyle(item.state == "失败" ? Color.red : Color.secondary).frame(width: 80, alignment: .trailing)
                            if ["排队中", "正在取消"].contains(item.state) { Button { model.cancel(item.id) } label: { Image(systemName: "xmark") } }
                        }
                    }.font(.system(size: 11)).buttonStyle(.borderless).controlSize(.mini).padding(.horizontal, 8).frame(height: 36)
                }
            }
        }.background(AppTheme.surface).overlay { if model.activeTransfers.isEmpty { EmptyPane(symbol: "arrow.up.arrow.down.circle", title: "无传输", detail: "") } }
    }
}
