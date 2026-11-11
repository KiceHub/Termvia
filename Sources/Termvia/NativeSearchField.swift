import TermviaCore
import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
    @Environment(\.locale) private var uiLocale
    @Binding var text: String
    var focusRevision: Int? = nil
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.placeholderString = T("搜索主机")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(T("搜索主机"))
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        let _ = uiLocale.identifier
        field.placeholderString = T("搜索主机")
        field.setAccessibilityLabel(T("搜索主机"))
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if let focusRevision, context.coordinator.focusRevision != focusRevision {
            context.coordinator.focusRevision = focusRevision
            field.requestFocus()
        }
    }
    /// SwiftUI can update the field before AppKit attaches its hosting view.
    /// Keep the request pending until the field actually belongs to a window.
    final class SearchField: NSSearchField {
        private var pendingFocus = false
        private var focusScheduled = false
        func requestFocus() { pendingFocus = true; focusWhenAttached() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusWhenAttached() }
        private func focusWhenAttached() {
            guard pendingFocus, !focusScheduled, window != nil else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.pendingFocus, let window = self.window, window.attachedSheet == nil else { return }
                if window.makeFirstResponder(self) { self.pendingFocus = false }
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRevision: Int?
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
