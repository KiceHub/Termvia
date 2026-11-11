import TermviaCore
import AppKit
import SwiftUI

struct PersistentSplit<First: View, Second: View>: NSViewRepresentable {
    var vertical: Bool
    @Binding var fraction: Double
    var firstHidden = false
    var secondHidden = false
    var firstMinimum: CGFloat
    var secondMinimum: CGFloat
    var terminalRowHeight: CGFloat? = nil
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second
    func makeNSView(context: Context) -> WorkspaceSplitView {
        let view = WorkspaceSplitView()
        view.isVertical = vertical; view.dividerStyle = .thin
        for content in [AnyView(first()), AnyView(second())] {
            let host = NSHostingView(rootView: AnyView(content.environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme)))
            // NSSplitView owns these frames; hosting sizing constraints must not
            // move a pane independently of its native divider during a drag.
            host.sizingOptions = []
            view.addArrangedSubview(host)
        }
        return view
    }
    func updateNSView(_ view: WorkspaceSplitView, context: Context) {
        (view.arrangedSubviews[0] as? NSHostingView<AnyView>)?.rootView = AnyView(first().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme))
        (view.arrangedSubviews[1] as? NSHostingView<AnyView>)?.rootView = AnyView(second().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme))
        view.configure(fraction: fraction, firstHidden: firstHidden, secondHidden: secondHidden,
                       firstMinimum: firstMinimum, secondMinimum: secondMinimum, terminalRowHeight: terminalRowHeight) { value in
            if abs(fraction - value) > 0.002 { fraction = value }
        }
    }
}

@MainActor private final class WorkspaceSplitDelegate: NSObject, NSSplitViewDelegate {
    weak var owner: WorkspaceSplitView?
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { owner?.splitView(splitView, resizeSubviewsWithOldSize: oldSize) }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { owner?.splitView(splitView, shouldHideDividerAt: dividerIndex) ?? false }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { owner?.splitView(splitView, constrainSplitPosition: proposedPosition, ofSubviewAt: dividerIndex) ?? proposedPosition }
    func splitViewDidResizeSubviews(_ notification: Notification) { owner?.splitViewDidResizeSubviews(notification) }
}

@MainActor final class WorkspaceSplitView: NSSplitView {
    // AppKit forwards some action queries to a split view's delegate. Using
    // the split view itself makes responds(to:) recurse during menu validation.
    private let splitDelegate = WorkspaceSplitDelegate()
    override var isFlipped: Bool { true }
    private var fraction = 0.5
    private var firstMinimum: CGFloat = 0
    private var secondMinimum: CGFloat = 0
    private var applying = false
    private var terminalRowHeight: CGFloat?
    private var gridReflowPending = false
    private(set) var lastDrawnDivider: NSRect?
    override var dividerThickness: CGFloat { arrangedSubviews.contains(where: \.isHidden) ? 0 : super.dividerThickness }
    override func drawDivider(in rect: NSRect) {
        if !arrangedSubviews.contains(where: \.isHidden) {
            if ProcessInfo.processInfo.arguments.contains("--launch-check") { lastDrawnDivider = rect }
            super.drawDivider(in: rect)
        }
    }
    private var onDrag: ((Double) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); splitDelegate.owner = self; delegate = splitDelegate }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(fraction: Double, firstHidden: Bool, secondHidden: Bool,
                   firstMinimum: CGFloat, secondMinimum: CGFloat, terminalRowHeight: CGFloat? = nil, onDrag: @escaping (Double) -> Void) {
        self.onDrag = onDrag; self.firstMinimum = firstMinimum; self.secondMinimum = secondMinimum
        let changed = abs(self.fraction - fraction) > 0.003 || arrangedSubviews[0].isHidden != firstHidden || arrangedSubviews[1].isHidden != secondHidden || self.terminalRowHeight != terminalRowHeight
        self.fraction = fraction
        self.terminalRowHeight = terminalRowHeight
        applying = true
        arrangedSubviews[0].isHidden = firstHidden; arrangedSubviews[1].isHidden = secondHidden
        if changed { applyFraction() }
        applying = false
    }
    private var length: CGFloat { max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness) }
    private func position(_ requested: CGFloat) -> CGFloat {
        guard length >= firstMinimum + secondMinimum else { return max(0, length * fraction) }
        let clamped = min(length - secondMinimum, max(firstMinimum, requested))
        guard !isVertical, let row = terminalRowHeight, row > 0 else { return clamped }
        let host = terminalHost(in: arrangedSubviews[0])
        let offset = max(0, arrangedSubviews[0].bounds.height - (host?.bounds.height ?? arrangedSubviews[0].bounds.height)) + (host?.insets.vertical ?? TerminalInsets().vertical)
        let minimumRows = ceil((firstMinimum - offset) / row)
        let maximumRows = floor((length - secondMinimum - offset) / row)
        guard minimumRows <= maximumRows else { return clamped }
        return offset + min(maximumRows, max(minimumRows, ((clamped - offset) / row).rounded())) * row
    }
    private func terminalHost(in view: NSView) -> TerminalHostView? {
        if let host = view as? TerminalHostView { return host }
        return view.subviews.lazy.compactMap { self.terminalHost(in: $0) }.first
    }
    func reflowTerminalGrid() {
        guard !isVertical, terminalRowHeight != nil, !gridReflowPending, arrangedSubviews.count == 2,
              !arrangedSubviews.contains(where: \.isHidden), abs(position(length * fraction) - arrangedSubviews[0].frame.height) > 0.1 else { return }
        // Never resize an ancestor synchronously from an NSHostingView layout.
        gridReflowPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gridReflowPending = false; self.applyFraction()
        }
    }
    private func applyFraction() {
        guard arrangedSubviews.count == 2 else { return }
        let previous = applying; applying = true
        if arrangedSubviews[0].isHidden { arrangedSubviews[0].frame = .zero; arrangedSubviews[1].frame = bounds }
        else if arrangedSubviews[1].isHidden { arrangedSubviews[0].frame = bounds; arrangedSubviews[1].frame = .zero }
        else {
            let first = position(length * fraction)
            let divider = min(dividerThickness, isVertical ? bounds.width : bounds.height)
            if isVertical {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
                arrangedSubviews[1].frame = NSRect(x: first + divider, y: 0, width: max(0, length - first), height: bounds.height)
            } else {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
                arrangedSubviews[1].frame = NSRect(x: 0, y: first + divider, width: bounds.width, height: max(0, length - first))
            }
        }
        applying = previous
        needsDisplay = true
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { applyFraction() }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { arrangedSubviews.contains(where: \.isHidden) }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { position(proposedPosition) }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        needsDisplay = true
        guard !applying, length > 0, arrangedSubviews.count == 2, !arrangedSubviews.contains(where: \.isHidden) else { return }
        let first = arrangedSubviews[0].frame
        let actual = isVertical ? first.width : first.height
        // AppKit can deliver resize notifications after our frame assignment
        // has finished. A snapped automatic layout must not become a user drag.
        guard abs(actual - position(length * fraction)) > 0.1 else { return }
        fraction = Double((isVertical ? first.width : first.height) / length)
        let value = fraction
        let callback = onDrag
        DispatchQueue.main.async { callback?(value) }
    }
}
