import AppKit

@MainActor private enum ToolbarControlLayout {
    static let height: CGFloat = 28
    static func constrain(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36), button.heightAnchor.constraint(equalToConstant: height)])
    }
    static func insets(_ original: NSEdgeInsets, cellHeight: CGFloat?) -> NSEdgeInsets {
        var insets = original
        // Cell metrics change on entering a toolbar. Use current native metrics
        // without re-entering intrinsicContentSize from the alignment getter.
        let offset = (height - (cellHeight ?? height)) / 2
        insets.top -= offset; insets.bottom += offset
        return insets
    }
}

/// Keep the native control aligned with its enlarged shared glass.
@MainActor final class ToolbarLayoutButton: NSButton {
    convenience init(image: NSImage?, label: String, tip: String?, target: AnyObject, action: Selector?) {
        self.init(image: image ?? NSImage(), target: target, action: action)
        self.image = image; imagePosition = .imageOnly; bezelStyle = .toolbar
        toolTip = tip; setAccessibilityLabel(label)
        ToolbarControlLayout.constrain(self)
    }
    override var alignmentRectInsets: NSEdgeInsets {
        ToolbarControlLayout.insets(super.alignmentRectInsets, cellHeight: cell?.cellSize.height)
    }
}

@MainActor final class ToolbarMenuButton: NSPopUpButton {
    convenience init(menu: NSMenu, label: String, tip: String?) {
        self.init(frame: .zero, pullsDown: true)
        bezelStyle = .toolbar; imagePosition = .imageOnly
        self.menu = menu; toolTip = tip; setAccessibilityLabel(label)
        if let cell = cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false; cell.arrowPosition = .noArrow
        }
        ToolbarControlLayout.constrain(self)
    }
    func setDisplayImage(_ image: NSImage?) {
        // An independent display item keeps the icon separate from the first
        // real menu action, including when the menu delegate rebuilds its items.
        let display = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        display.image = image
        (cell as? NSPopUpButtonCell)?.menuItem = display
    }
    override var alignmentRectInsets: NSEdgeInsets {
        ToolbarControlLayout.insets(super.alignmentRectInsets, cellHeight: cell?.cellSize.height)
    }
}
