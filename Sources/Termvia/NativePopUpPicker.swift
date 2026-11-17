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
    var preferredEdge: VerticalEdge? = nil
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: preferredEdge != nil)
        view.controlSize = .small; view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator; view.action = #selector(Coordinator.change(_:))
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // Ordinary popups anchor the selected row over the control, which can
        // leave a footer menu scrolling below it even when there is room above.
        // Edge-attached pull-downs let AppKit fit the full menu on either side
        // and provide native scrolling arrows when the screen is too short.
        view.pullsDown = preferredEdge != nil
        if let edge = preferredEdge {
            view.preferredEdge = edge == .top
                ? (view.isFlipped ? .minY : .maxY)
                : (view.isFlipped ? .maxY : .minY)
        }
        if view.itemTitles != options.map(\.title) { view.removeAllItems(); view.addItems(withTitles: options.map(\.title)) }
        let index = options.firstIndex { $0.value == selection } ?? -1
        let cell = view.cell as? NSPopUpButtonCell
        cell?.usesItemFromMenu = preferredEdge == nil
        view.selectItem(at: index)
        if preferredEdge != nil {
            // Keep the selected value as the button title without reserving or
            // hiding the first real option as a pull-down's display item.
            cell?.menuItem = NSMenuItem(title: options.indices.contains(index) ? options[index].title : "", action: nil, keyEquivalent: "")
            for (offset, item) in view.itemArray.enumerated() {
                item.isHidden = false
                item.state = offset == index ? .on : .off
            }
        }
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
