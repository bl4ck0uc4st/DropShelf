import Cocoa

// MARK: - Model

final class ShelfItem {
    private(set) var url: URL
    private let bookmark: Data?
    var selected = false

    init(url: URL) {
        self.url = url
        self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Re-resolves the file in case it was moved or renamed after it was dropped.
    func refreshedURL() -> URL {
        guard let data = bookmark else { return url }
        var stale = false
        if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = resolved
        }
        return url
    }

    var name: String { url.lastPathComponent }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var fileSize: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    var icon: NSImage {
        let image = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 36, height: 36)
        return image
    }

    var detailText: String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        if isDirectory { return "Folder · \(folder)" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        return "\(size) · \(folder)"
    }
}

// MARK: - Helpers

extension NSView {
    /// Resolves a dynamic (light/dark) color for this view's current appearance.
    func cgColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Borderless icon button with a soft hover circle.
final class ShelfButton: NSButton {
    private var hovered = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        isBordered = false
        imagePosition = .imageOnly
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = hovered ? cgColor(NSColor.labelColor.withAlphaComponent(0.1)) : nil
    }
}

// MARK: - Drop target (the panel's content view)

final class DropView: NSView {
    weak var panel: ShelfPanel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Empty areas of the shelf move it around.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        panel?.appearanceDidChange()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            panel?.selectAll()
            return
        }
        switch event.keyCode {
        case 53:        // esc
            panel?.hideShelf()
        case 51, 117:   // delete / forward delete
            panel?.removeSelected()
        case 49:        // space
            panel?.toggleQuickLook()
        case 125:       // down
            panel?.moveSelection(by: 1)
        case 126:       // up
            panel?.moveSelection(by: -1)
        case 36, 76:    // return / enter
            panel?.openSelected()
        default:
            super.keyDown(with: event)
        }
    }

    private func hasFileURLs(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is ShelfPanel { return [] }
        guard hasFileURLs(sender) else { return [] }
        panel?.setDragOver(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        panel?.setDragOver(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURLs(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        panel?.setDragOver(false)
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (objects as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        panel?.add(urls: urls)
        return true
    }
}

// MARK: - Empty state

final class EmptyStateView: NSView {
    private let dash = CAShapeLayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Drop files here")
    private let subtitleLabel = NSTextField(labelWithString: "They stay on the shelf until you drag them out")

    var isDragTarget = false { didSet { update() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 4]
        layer?.addSublayer(dash)

        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let box = NSRect(origin: .zero, size: newSize).insetBy(dx: 12, dy: 10)
        dash.frame = NSRect(origin: .zero, size: newSize)
        dash.path = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)

        let contentHeight: CGFloat = 32 + 6 + 17 + 2 + 15
        var y = box.midY + contentHeight / 2
        iconView.frame = NSRect(x: box.midX - 20, y: y - 32, width: 40, height: 32)
        y -= 32 + 6
        titleLabel.frame = NSRect(x: box.minX + 8, y: y - 17, width: box.width - 16, height: 17)
        y -= 17 + 2
        subtitleLabel.frame = NSRect(x: box.minX + 8, y: y - 15, width: box.width - 16, height: 15)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        let accent = NSColor.controlAccentColor
        dash.strokeColor = cgColor(isDragTarget ? accent : NSColor.tertiaryLabelColor)
        iconView.contentTintColor = isDragTarget ? accent : .tertiaryLabelColor
        titleLabel.stringValue = isDragTarget ? "Release to add" : "Drop files here"
        titleLabel.textColor = isDragTarget ? accent : .secondaryLabelColor
    }
}

// MARK: - "Drag everything" grip in the header

final class GripView: NSView {
    weak var panel: ShelfPanel?
    private let imageView = NSImageView()
    private var downEvent: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Drag all files")
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        addSubview(imageView)
        toolTip = "Drag to move all files at once"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        imageView.frame = NSRect(origin: .zero, size: newSize).insetBy(dx: 2, dy: 2)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Swallow hits on the image so this view gets the mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview = superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let panel = panel, !panel.items.isEmpty else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        downEvent = nil
        panel.beginDrag(items: panel.items, from: self, anchor: bounds, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
    }
}

// MARK: - One file row

final class ItemRow: NSView {
    let item: ShelfItem
    private weak var panel: ShelfPanel?
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let removeButton = ShelfButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private var downEvent: NSEvent?
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet {
            removeButton.isHidden = !hovered
            refreshBackground()
        }
    }

    /// Where the icon sits, for Quick Look's zoom animation.
    var iconFrame: NSRect { iconView.frame }

    init(item: ShelfItem, panel: ShelfPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(detailLabel)

        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from shelf")
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.toolTip = "Remove from shelf"
        removeButton.target = self
        removeButton.action = #selector(removeMe)
        removeButton.isHidden = true
        addSubview(removeButton)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    func refresh() {
        iconView.image = item.icon
        nameLabel.stringValue = item.name
        detailLabel.stringValue = item.detailText
        toolTip = item.refreshedURL().path
        refreshBackground()
    }

    private func refreshBackground() {
        let color: NSColor?
        if item.selected {
            color = NSColor.controlAccentColor.withAlphaComponent(hovered ? 0.36 : 0.28)
        } else if hovered {
            color = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            color = nil
        }
        layer?.backgroundColor = color.map { cgColor($0) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = newSize.height
        iconView.frame = NSRect(x: 10, y: (h - 36) / 2, width: 36, height: 36)
        let textX: CGFloat = 56
        let textWidth = newSize.width - textX - 36
        nameLabel.frame = NSRect(x: textX, y: h / 2, width: textWidth, height: 17)
        detailLabel.frame = NSRect(x: textX, y: h / 2 - 16, width: textWidth, height: 15)
        removeButton.frame = NSRect(x: newSize.width - 30, y: (h - 22) / 2, width: 22, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.refreshedURL())
            return
        }
        if event.modifierFlags.contains(.command) {
            item.selected.toggle()
            panel?.refreshRows()
        } else if event.modifierFlags.contains(.shift) {
            panel?.extendSelection(to: item)
        } else if !item.selected {
            panel?.select(only: item)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let panel = panel else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        downEvent = nil
        let selected = panel.selectedItems
        let toDrag = (item.selected && selected.count > 1) ? selected : [item]
        panel.beginDrag(items: toDrag, from: self, anchor: iconView.frame, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click (no drag) on an already-selected row narrows the selection to it.
        if downEvent != nil, event.clickCount == 1,
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            panel?.select(only: item)
        }
        downEvent = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if !item.selected { panel?.select(only: item) }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open", action: #selector(openItem), keyEquivalent: "")
        let look = NSMenuItem(title: "Quick Look", action: #selector(quickLookItem), keyEquivalent: "")
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealItem), keyEquivalent: "")
        let all = NSMenuItem(title: "Select All", action: #selector(selectAllItems), keyEquivalent: "")
        let remove = NSMenuItem(title: "Remove from Shelf", action: #selector(removeSelected), keyEquivalent: "")
        for menuItem in [open, look, reveal, all, remove] { menuItem.target = self }
        menu.addItem(open)
        menu.addItem(look)
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(all)
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openItem() { NSWorkspace.shared.open(item.refreshedURL()) }
    @objc private func quickLookItem() { panel?.toggleQuickLook() }
    @objc private func revealItem() { NSWorkspace.shared.activateFileViewerSelecting([item.refreshedURL()]) }
    @objc private func selectAllItems() { panel?.selectAll() }
    @objc private func removeSelected() { panel?.removeSelected() }
    @objc private func removeMe() { panel?.remove([item]) }
}
