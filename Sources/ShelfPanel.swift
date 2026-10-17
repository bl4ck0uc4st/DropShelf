import Cocoa
import Quartz

final class ShelfPanel: NSPanel {
    static let width: CGFloat = 300
    static let headerHeight: CGFloat = 52
    static let rowHeight: CGFloat = 52
    static let emptyHeight: CGFloat = 116
    static let maxRows = 7
    static let cornerRadius: CGFloat = 14

    private(set) var items: [ShelfItem] = []
    var isEmpty: Bool { items.isEmpty }
    var selectedItems: [ShelfItem] { items.filter { $0.selected } }

    /// True while the shelf was opened by a shake and nothing has been dropped yet.
    var autoHidesWhenEmpty = false
    /// True while a drag that started on the shelf is in flight.
    var isDraggingOut = false
    /// Fires when the item count or visibility changes (drives the menu bar badge).
    var onStateChange: (() -> Void)?

    private static let initialFrame = NSRect(x: 0, y: 0, width: ShelfPanel.width, height: ShelfPanel.headerHeight + 1 + ShelfPanel.emptyHeight)

    private let dropView = DropView(frame: ShelfPanel.initialFrame)
    private let backdrop = NSVisualEffectView()
    private let header = NSView()
    private let separator = NSView()
    private let body = NSView()
    private let grip = GripView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "DropShelf")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let clearButton = ShelfButton(frame: .zero)
    private let closeButton = ShelfButton(frame: .zero)
    private let emptyView = EmptyStateView(frame: .zero)
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private var titleLeadingWithGrip: NSLayoutConstraint?
    private var titleLeadingWithoutGrip: NSLayoutConstraint?
    private var isBuilt = false

    private var rows: [ItemRow] = []
    private var inFlight: [ShelfItem] = []
    private var isDragOver = false
    private var showGeneration = 0

    init() {
        super.init(contentRect: ShelfPanel.initialFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        appearance = Settings.nsAppearance

        contentView = dropView
        buildUI()
        isBuilt = true
        // Wire these up only after the UI exists: attaching the content view
        // already triggers appearance callbacks that call updateChrome().
        dropView.panel = self
        grip.panel = self
        updateChrome()
    }

    override var canBecomeKey: Bool { true }

    // MARK: UI

    private func buildUI() {
        dropView.wantsLayer = true
        dropView.layer?.cornerRadius = ShelfPanel.cornerRadius
        dropView.layer?.masksToBounds = true
        dropView.layer?.borderWidth = 1

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = ShelfPanel.roundedMask(radius: ShelfPanel.cornerRadius)

        separator.wantsLayer = true

        let chrome: [NSView] = [backdrop, header, separator, body]
        let headerViews: [NSView] = [grip, titleLabel, subtitleLabel, clearButton, closeButton]
        let bodyViews: [NSView] = [emptyView, scrollView]
        for view in chrome {
            view.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(view)
        }
        for view in headerViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in bodyViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(clearButton, symbol: "trash", tooltip: "Clear shelf", action: #selector(clearAll))
        configure(closeButton, symbol: "xmark.circle.fill", tooltip: "Hide shelf (files stay on it)", action: #selector(hideShelf))

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = listView

        titleLeadingWithGrip = titleLabel.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10)
        titleLeadingWithoutGrip = titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: dropView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            header.topAnchor.constraint(equalTo: dropView.topAnchor),
            header.heightAnchor.constraint(equalToConstant: ShelfPanel.headerHeight),

            separator.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            body.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),

            grip.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            grip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 24),
            grip.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            emptyView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: body.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: body.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    /// Stretchable rounded-rectangle mask so the blur backdrop gets rounded corners.
    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    /// Colors, labels and which parts are visible. Cheap; called often.
    func updateChrome() {
        guard isBuilt else { return }
        let accent = NSColor.controlAccentColor
        dropView.layer?.borderColor = dropView.cgColor(isDragOver ? accent : .separatorColor)
        dropView.layer?.borderWidth = isDragOver ? 2 : 1
        separator.layer?.backgroundColor = dropView.cgColor(.separatorColor)

        let empty = items.isEmpty
        emptyView.isHidden = !empty
        emptyView.isDragTarget = isDragOver
        scrollView.isHidden = empty
        clearButton.isHidden = empty
        grip.isHidden = empty
        // Deactivate before activating so the two leading constraints never clash.
        if empty {
            titleLeadingWithGrip?.isActive = false
            titleLeadingWithoutGrip?.isActive = true
        } else {
            titleLeadingWithoutGrip?.isActive = false
            titleLeadingWithGrip?.isActive = true
        }

        if empty {
            titleLabel.stringValue = "DropShelf"
            subtitleLabel.stringValue = isDragOver ? "Release to add" : "Shelf is empty"
        } else {
            let count = items.count
            var title = "\(count) \(count == 1 ? "file" : "files")"
            let total = items.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.fileSize) }
            if total > 0 { title += " · " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) }
            titleLabel.stringValue = title
            subtitleLabel.stringValue = isDragOver ? "Release to add" : "Drag out to move · ⌥ copies"
        }
        subtitleLabel.textColor = isDragOver ? accent : .secondaryLabelColor
    }

    func appearanceDidChange() {
        updateChrome()
        rows.forEach { $0.refresh() }
    }

    func setDragOver(_ on: Bool) {
        guard isDragOver != on else { return }
        isDragOver = on
        updateChrome()
    }

    // MARK: Sizing

    private func targetHeight() -> CGFloat {
        if items.isEmpty { return ShelfPanel.headerHeight + 1 + ShelfPanel.emptyHeight }
        let visibleRows = min(items.count, ShelfPanel.maxRows)
        return ShelfPanel.headerHeight + 1 + CGFloat(visibleRows) * ShelfPanel.rowHeight + 10
    }

    private func layoutRows() {
        let docHeight = CGFloat(items.count) * ShelfPanel.rowHeight + 10
        listView.frame = NSRect(x: 0, y: 0, width: ShelfPanel.width, height: docHeight)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 6, y: 5 + CGFloat(i) * ShelfPanel.rowHeight,
                               width: ShelfPanel.width - 12, height: ShelfPanel.rowHeight)
        }
    }

    /// Grows or shrinks the panel to fit, keeping its top edge where it is.
    private func resize(animated: Bool) {
        let total = targetHeight()
        var f = frame
        f.origin.y += f.height - total
        f.size = NSSize(width: ShelfPanel.width, height: total)
        guard f != frame else { return }
        if animated && isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(f, display: true)
            }
        } else {
            setFrame(f, display: true)
        }
    }

    // MARK: Showing / hiding

    func show(near point: NSPoint, autoHide: Bool) {
        showGeneration += 1
        if !isVisible { autoHidesWhenEmpty = autoHide }
        updateChrome()
        layoutRows()

        // Put the pointer inside the drop area so a drop can happen right away.
        let total = targetHeight()
        var origin = NSPoint(x: point.x - ShelfPanel.width / 2, y: point.y - total + 84)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - ShelfPanel.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - total - 8)
        }
        let target = NSRect(origin: origin, size: NSSize(width: ShelfPanel.width, height: total))

        if isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 1
            }
        } else {
            var start = target
            start.origin.y -= 10
            alphaValue = 0
            setFrame(start, display: true)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 1
            }
        }
        makeFirstResponder(dropView)
        onStateChange?()
    }

    @objc func hideShelf() {
        guard isVisible else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
            ql.orderOut(nil)
        }
        showGeneration += 1
        let generation = showGeneration
        var f = frame
        f.origin.y -= 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, self.showGeneration == generation else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.onStateChange?()
        })
    }

    // MARK: Items

    func add(urls: [URL]) {
        autoHidesWhenEmpty = false
        var newRows: [ItemRow] = []
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = ShelfItem(url: url)
            items.append(item)
            let row = ItemRow(item: item, panel: self)
            row.alphaValue = 0
            rows.append(row)
            newRows.append(row)
            listView.addSubview(row)
        }
        guard !newRows.isEmpty else { return }
        layoutRows()
        updateChrome()
        resize(animated: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for row in newRows { row.animator().alphaValue = 1 }
        }
        if let last = newRows.last { _ = listView.scrollToVisible(last.frame) }
        onStateChange?()
    }

    func remove(_ toRemove: [ShelfItem]) {
        let ids = Set(toRemove.map { ObjectIdentifier($0) })
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains(ObjectIdentifier($0)) }
        for row in rows where ids.contains(ObjectIdentifier(row.item)) {
            row.removeFromSuperview()
        }
        rows.removeAll { ids.contains(ObjectIdentifier($0.item)) }
        layoutRows()
        updateChrome()
        resize(animated: true)
        refreshQuickLook()
        onStateChange?()
    }

    func removeSelected() {
        remove(selectedItems)
    }

    @objc func clearAll() {
        remove(items)
    }

    func openSelected() {
        for item in selectedItems { NSWorkspace.shared.open(item.refreshedURL()) }
    }

    // MARK: Selection

    func refreshRows() {
        rows.forEach { $0.refresh() }
    }

    func select(only item: ShelfItem) {
        for other in items { other.selected = (other === item) }
        refreshRows()
    }

    func extendSelection(to item: ShelfItem) {
        guard let target = items.firstIndex(where: { $0 === item }) else { return }
        let anchor = items.firstIndex(where: { $0.selected }) ?? target
        let range = min(anchor, target)...max(anchor, target)
        for (i, other) in items.enumerated() { other.selected = range.contains(i) }
        refreshRows()
    }

    func selectAll() {
        items.forEach { $0.selected = true }
        refreshRows()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next: Int
        if let current = items.firstIndex(where: { $0.selected }) {
            next = min(max(current + delta, 0), items.count - 1)
        } else {
            next = delta > 0 ? 0 : items.count - 1
        }
        select(only: items[next])
        _ = listView.scrollToVisible(rows[next].frame)
        refreshQuickLook()
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard !items.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        if selectedItems.isEmpty { select(only: items[0]) }
        if ql.isVisible {
            ql.orderOut(nil)
        } else {
            ql.makeKeyAndOrderFront(nil)
        }
    }

    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible,
              let controller = ql.currentController as? ShelfPanel, controller === self else { return }
        ql.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: Dragging out

    func beginDrag(items toDrag: [ShelfItem], from view: NSView, anchor: NSRect, event: NSEvent) {
        var dragItems: [NSDraggingItem] = []
        for (i, item) in toDrag.enumerated() {
            let url = item.refreshedURL()
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            var imageFrame = anchor
            let fan = CGFloat(min(i, 4)) * 5
            imageFrame.origin.x += fan
            imageFrame.origin.y -= fan
            dragItem.setDraggingFrame(imageFrame, contents: item.icon)
            dragItems.append(dragItem)
        }
        guard !dragItems.isEmpty else { return }
        for row in rows where toDrag.contains(where: { $0 === row.item }) { row.alphaValue = 0.4 }
        inFlight = toDrag
        isDraggingOut = true
        _ = view.beginDraggingSession(with: dragItems, event: event, source: self)
    }
}

extension ShelfPanel: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.move, .copy, .link]
        default: return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingOut = false
        let dropped = inFlight
        inFlight = []
        rows.forEach { $0.alphaValue = 1 }
        guard operation != [] else { return }          // cancelled or refused
        if !Settings.keepAfterDragOut {
            remove(dropped)
            if isEmpty { hideShelf() }
        }
    }
}

extension ShelfPanel: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewItems: [ShelfItem] { selectedItems.isEmpty ? items : selectedItems }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let source = previewItems
        guard index >= 0, index < source.count else { return nil }
        return source[index].refreshedURL() as NSURL
    }

    /// With a single selection, arrow keys step through the shelf. With several
    /// files selected, Quick Look's own navigation between them is left alone.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, selectedItems.count <= 1 else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1); return true
        case 126: moveSelection(by: -1); return true
        default: return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL,
              let index = items.firstIndex(where: { $0.url == url }), index < rows.count else { return .zero }
        let row = rows[index]
        return convertToScreen(row.convert(row.iconFrame, to: nil))
    }
}
