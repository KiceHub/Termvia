import AppKit
import SwiftUI
import TermviaCore

/// A standard AppKit popup that fills its allotted form column. SwiftUI's
/// intrinsic-width menu picker otherwise floats inside a wider frame.
struct NativePopUpPicker<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let label: String
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        view.controlSize = .small; view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator; view.action = #selector(Coordinator.change(_:))
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if view.itemTitles != options.map(\.title) { view.removeAllItems(); view.addItems(withTitles: options.map(\.title)) }
        view.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityLabel(T(label)); view.setAccessibilityIdentifier(identifier)
        view.toolTip = options.first { $0.value == selection }?.title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }
    final class Coordinator: NSObject {
        var parent: NativePopUpPicker
        init(parent: NativePopUpPicker) { self.parent = parent }
        @objc func change(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].value
        }
    }
}
