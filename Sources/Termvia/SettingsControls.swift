import AppKit
import SwiftUI
import TermviaCore

/// Size numeric fields to their range, leaving room for units and native steppers.
struct SettingsNumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    var step = 1
    let identifier: String
    @Environment(\.locale) private var locale
    var controlWidth: CGFloat {
        let digits = max(String(range.lowerBound).count, String(range.upperBound).count)
        return CGFloat(max(3, digits) * 8 + 20 + 19 + 6) + (unit.isEmpty ? 0 : 32)
    }
    var body: some View {
        let _ = locale.identifier
        LabeledContent(T(title)) {
            SettingsNumberControl(value: $value, range: range, unit: unit, step: step, title: title, identifier: identifier)
                .frame(width: controlWidth, height: 24)
        }
    }
}

/// Editing stays in AppKit's field editor until Return or focus loss. An
/// incomplete draft never changes the live setting or interrupts the sampler.
struct SettingsNumberControl: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    var step = 1
    let title: String
    let identifier: String
    @Environment(\.locale) private var locale
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NumberView {
        let view = NumberView()
        view.field.delegate = context.coordinator
        view.stepper.target = context.coordinator
        view.stepper.action = #selector(Coordinator.adjust(_:))
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ view: NumberView, context: Context) {
        context.coordinator.parent = self
        view.formatter.locale = locale
        view.field.isEnabled = context.environment.isEnabled
        view.stepper.isEnabled = context.environment.isEnabled
        view.unit.stringValue = unit
        view.unit.isHidden = unit.isEmpty
        view.unit.textColor = context.environment.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        view.field.setAccessibilityLabel(T(title))
        view.field.setAccessibilityIdentifier(identifier)
        view.field.setAccessibilityHelp("\(range.lowerBound)–\(range.upperBound)" + (unit.isEmpty ? "" : " " + unit))
        view.stepper.setAccessibilityLabel(T(title))
        view.stepper.setAccessibilityIdentifier(identifier + ".Stepper")
        view.stepper.minValue = Double(range.lowerBound); view.stepper.maxValue = Double(range.upperBound)
        view.stepper.increment = Double(step)
        context.coordinator.synchronize(preserveDraft: true)
    }
    final class NumberView: NSStackView {
        let field = NSTextField(), unit = NSTextField(labelWithString: ""), stepper = NSStepper()
        let formatter = NumberFormatter()
        init() {
            super.init(frame: .zero)
            orientation = .horizontal; alignment = .centerY; spacing = 6
            formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
            formatter.allowsFloats = false; formatter.maximumFractionDigits = 0
            field.formatter = formatter; field.alignment = .right; field.controlSize = .small
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            unit.alignment = .center
            unit.widthAnchor.constraint(equalToConstant: 26).isActive = true
            unit.setContentHuggingPriority(.required, for: .horizontal)
            unit.setContentCompressionResistancePriority(.required, for: .horizontal)
            stepper.controlSize = .small; stepper.valueWraps = false
            stepper.setContentHuggingPriority(.required, for: .horizontal)
            stepper.setContentCompressionResistancePriority(.required, for: .horizontal)
            for control in [field, unit, stepper] { addArrangedSubview(control) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsNumberControl
        weak var view: NumberView?
        private var stepperValue = 0
        init(parent: SettingsNumberControl) { self.parent = parent }
        private func bounded(_ value: Int) -> Int { min(parent.range.upperBound, max(parent.range.lowerBound, value)) }
        func synchronize(preserveDraft: Bool) {
            guard let view else { return }
            let value = bounded(parent.value)
            if !preserveDraft || view.field.currentEditor() == nil {
                view.field.integerValue = value
                if let editor = view.field.currentEditor(), editor.string != view.field.stringValue { editor.string = view.field.stringValue }
            }
            view.stepper.integerValue = value; stepperValue = value
        }
        func commit() {
            guard let view else { return }
            let draft = view.field.currentEditor()?.string ?? view.field.stringValue
            let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)).map(bounded) ?? bounded(parent.value)
            if parent.value != value { parent.value = value }
            synchronize(preserveDraft: false)
        }
        func controlTextDidEndEditing(_ notification: Notification) { commit() }
        @objc func adjust(_ sender: NSStepper) {
            let direction = sender.integerValue - stepperValue
            guard direction != 0 else { return }
            commit()
            let candidate = parent.value + (direction > 0 ? parent.step : -parent.step)
            let value = bounded(candidate)
            if parent.value != value { parent.value = value }
            synchronize(preserveDraft: false)
        }
    }
}

struct CursorShapeControl: NSViewRepresentable {
    @Binding var selection: TerminalCursorShape
    @Environment(\.locale) private var locale
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(images: TerminalCursorShape.allCases.map(Self.image), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.controlSize = .small; control.segmentDistribution = .fillEqually
        control.role = .valueSelection
        control.setAccessibilityIdentifier("Termvia.CursorShape")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let _ = locale.identifier
        context.coordinator.selection = $selection
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(T("光标样式"))
        for (index, shape) in TerminalCursorShape.allCases.enumerated() {
            control.setToolTip(shape.title, forSegment: index)
            control.image(forSegment: index)?.accessibilityDescription = shape.title
        }
        control.selectedSegment = TerminalCursorShape.allCases.firstIndex(of: selection) ?? 1
    }
    static func image(_ shape: TerminalCursorShape) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            let rect: NSRect
            switch shape {
            case .block: rect = NSRect(x: 3, y: 2, width: 8, height: 12)
            case .bar: rect = NSRect(x: 6, y: 2, width: 2, height: 12)
            case .underline: rect = NSRect(x: 3, y: 2, width: 8, height: 2)
            }
            rect.fill(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = shape.title
        return image
    }
    final class Coordinator: NSObject {
        var selection: Binding<TerminalCursorShape>
        init(selection: Binding<TerminalCursorShape>) { self.selection = selection }
        @objc func select(_ control: NSSegmentedControl) {
            guard TerminalCursorShape.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = TerminalCursorShape.allCases[control.selectedSegment]
        }
    }
}
