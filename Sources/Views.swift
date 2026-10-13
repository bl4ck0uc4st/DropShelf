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

    var icon: NSImage {
        let image = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    var detailText: String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return "Folder · \(folder)" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        return "\(size) · \(folder)"
    }
}

// MARK: - Helpers

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ShelfButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        // esc
            panel?.hideShelf()
        case 51, 117:   // delete / forward delete
            panel?.removeSelected()
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
        panel?.setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        panel?.setHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURLs(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        panel?.setHighlighted(false)
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (objects as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        panel?.add(urls: urls)
        return true
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
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        toolTip = "Drag here to move all files at once"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
    private var downEvent: NSEvent?

    init(item: ShelfItem, panel: ShelfPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(detailLabel)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refresh() {
        iconView.image = item.icon
        nameLabel.stringValue = item.name
        detailLabel.stringValue = item.detailText
        toolTip = item.refreshedURL().path
        layer?.backgroundColor = item.selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            : NSColor.clear.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = newSize.height
        iconView.frame = NSRect(x: 8, y: (h - 32) / 2, width: 32, height: 32)
        nameLabel.frame = NSRect(x: 48, y: h / 2 - 1, width: newSize.width - 56, height: 17)
        detailLabel.frame = NSRect(x: 48, y: h / 2 - 16, width: newSize.width - 56, height: 15)
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
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealItem), keyEquivalent: "")
        let all = NSMenuItem(title: "Select All", action: #selector(selectAllItems), keyEquivalent: "")
        let remove = NSMenuItem(title: "Remove from Shelf", action: #selector(removeSelected), keyEquivalent: "")
        for menuItem in [open, reveal, all, remove] { menuItem.target = self }
        menu.addItem(open)
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(all)
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openItem() { NSWorkspace.shared.open(item.refreshedURL()) }
    @objc private func revealItem() { NSWorkspace.shared.activateFileViewerSelecting([item.refreshedURL()]) }
    @objc private func selectAllItems() { panel?.selectAll() }
    @objc private func removeSelected() { panel?.removeSelected() }
}
