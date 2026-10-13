import Cocoa

final class ShelfPanel: NSPanel {
    static let width: CGFloat = 280
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 46
    static let maxRows = 7

    private(set) var items: [ShelfItem] = []
    var isEmpty: Bool { items.isEmpty }
    var selectedItems: [ShelfItem] { items.filter { $0.selected } }

    /// True while the shelf was opened by a shake and nothing has been dropped yet.
    var autoHidesWhenEmpty = false
    /// True while a drag that started on the shelf is in flight.
    var isDraggingOut = false

    private let dropView = DropView(frame: NSRect(x: 0, y: 0, width: ShelfPanel.width, height: 120))
    private let backdrop = NSVisualEffectView()
    private let grip = GripView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private let titleLabel = NSTextField(labelWithString: "DropShelf")
    private let hintLabel = NSTextField(labelWithString: "Drop files here")
    private let clearButton = ShelfButton()
    private let closeButton = ShelfButton()
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private var rows: [ItemRow] = []
    private var inFlight: [ShelfItem] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ShelfPanel.width, height: 120),
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
        animationBehavior = .utilityWindow

        dropView.panel = self
        grip.panel = self
        contentView = dropView
        buildUI()
    }

    override var canBecomeKey: Bool { true }

    // MARK: UI

    private func buildUI() {
        dropView.wantsLayer = true
        dropView.layer?.cornerRadius = 16
        dropView.layer?.masksToBounds = true
        dropView.layer?.borderWidth = 0

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = ShelfPanel.roundedMask(radius: 16)
        backdrop.frame = dropView.bounds
        backdrop.autoresizingMask = [.width, .height]
        dropView.addSubview(backdrop)

        dropView.addSubview(grip)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        dropView.addSubview(titleLabel)

        configure(clearButton, symbol: "trash", tooltip: "Remove all files from the shelf", action: #selector(clearAll))
        configure(closeButton, symbol: "xmark.circle.fill", tooltip: "Close the shelf", action: #selector(hideShelf))
        dropView.addSubview(clearButton)
        dropView.addSubview(closeButton)

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        dropView.addSubview(hintLabel)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = listView
        dropView.addSubview(scrollView)

        relayout()
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
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    private func relayout() {
        let w = ShelfPanel.width
        let visibleRows = min(max(items.count, 1), ShelfPanel.maxRows)
        let listHeight = CGFloat(visibleRows) * ShelfPanel.rowHeight + 8
        let total = ShelfPanel.headerHeight + listHeight

        // Resize while keeping the top edge where it is.
        var f = frame
        f.origin.y += f.height - total
        f.size = NSSize(width: w, height: total)
        setFrame(f, display: true)

        let headerMidY = total - ShelfPanel.headerHeight / 2
        grip.frame = NSRect(x: 12, y: headerMidY - 11, width: 22, height: 22)
        titleLabel.frame = NSRect(x: 40, y: headerMidY - 8, width: w - 100, height: 16)
        clearButton.frame = NSRect(x: w - 60, y: headerMidY - 11, width: 22, height: 22)
        closeButton.frame = NSRect(x: w - 32, y: headerMidY - 11, width: 22, height: 22)
        scrollView.frame = NSRect(x: 0, y: 0, width: w, height: listHeight)
        hintLabel.frame = NSRect(x: 0, y: listHeight / 2 - 9, width: w, height: 18)

        let docHeight = max(CGFloat(items.count) * ShelfPanel.rowHeight + 8, listHeight)
        listView.frame = NSRect(x: 0, y: 0, width: w, height: docHeight)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 6, y: 4 + CGFloat(i) * ShelfPanel.rowHeight, width: w - 12, height: ShelfPanel.rowHeight)
        }

        hintLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        clearButton.isHidden = items.isEmpty
        grip.isHidden = items.isEmpty
        titleLabel.stringValue = items.isEmpty
            ? "DropShelf"
            : "\(items.count) \(items.count == 1 ? "file" : "files") · drag out to move"
        invalidateShadow()
    }

    func setHighlighted(_ on: Bool) {
        dropView.layer?.borderWidth = on ? 2 : 0
        dropView.layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
    }

    // MARK: Showing / hiding

    func show(near point: NSPoint, autoHide: Bool) {
        if !isVisible { autoHidesWhenEmpty = autoHide }
        relayout()

        // Put the pointer just inside the top of the shelf so a drop can happen right away.
        var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height + 30)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
        makeFirstResponder(dropView)
    }

    @objc func hideShelf() {
        orderOut(nil)
    }

    // MARK: Items

    func add(urls: [URL]) {
        autoHidesWhenEmpty = false
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = ShelfItem(url: url)
            items.append(item)
            let row = ItemRow(item: item, panel: self)
            rows.append(row)
            listView.addSubview(row)
        }
        relayout()
    }

    func remove(_ toRemove: [ShelfItem]) {
        let ids = Set(toRemove.map { ObjectIdentifier($0) })
        items.removeAll { ids.contains(ObjectIdentifier($0)) }
        for row in rows where ids.contains(ObjectIdentifier(row.item)) {
            row.removeFromSuperview()
        }
        rows.removeAll { ids.contains(ObjectIdentifier($0.item)) }
        relayout()
    }

    func removeSelected() {
        remove(selectedItems)
    }

    @objc func clearAll() {
        remove(items)
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
        guard operation != [] else { return }          // cancelled or refused
        if !Settings.keepAfterDragOut {
            remove(dropped)
            if isEmpty { hideShelf() }
        }
    }
}
