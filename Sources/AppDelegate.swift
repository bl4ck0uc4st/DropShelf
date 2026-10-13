import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var shelf: ShelfPanel!
    private let detector = ShakeDetector()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hideTimer: Timer?

    /// Change count of the drag pasteboard when the current mouse-down began.
    /// A real drag session writes to that pasteboard, so if the count has not
    /// moved we are looking at a window move or a text selection, not a file drag.
    private var dragStartChangeCount = NSPasteboard(name: .drag).changeCount

    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf = ShelfPanel()
        buildStatusItem()
        detector.onShake = { [weak self] in self?.handleShake() }
        installMonitors()
    }

    // MARK: Mouse monitoring

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            detector.beginDrag()
        case .leftMouseDragged:
            detector.feed(x: NSEvent.mouseLocation.x, at: event.timestamp)
        case .leftMouseUp:
            scheduleHideIfEmpty()
        default:
            break
        }
    }

    private func handleShake() {
        guard !shelf.isDraggingOut, currentDragHasFiles() else { return }
        shelf.show(near: NSEvent.mouseLocation, autoHide: true)
    }

    private func currentDragHasFiles() -> Bool {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragStartChangeCount else { return false }
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// A shake opened the shelf but nothing was dropped: tidy it away.
    private func scheduleHideIfEmpty() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.shelf.isVisible && self.shelf.isEmpty && self.shelf.autoHidesWhenEmpty {
                self.shelf.hideShelf()
            }
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "DropShelf")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "DropShelf — shake a file while dragging it"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func showShelf() {
        shelf.show(near: NSEvent.mouseLocation, autoHide: false)
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        Settings.sensitivity = sender.tag
    }

    @objc private func toggleKeep() {
        Settings.keepAfterDragOut.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Shelf at Cursor", action: #selector(showShelf), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let sensitivity = NSMenuItem(title: "Shake Sensitivity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in [("Low", 1), ("Normal", 2), ("High", 3)] {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.tag = value
            item.target = self
            item.state = Settings.sensitivity == value ? .on : .off
            sub.addItem(item)
        }
        sensitivity.submenu = sub
        menu.addItem(sensitivity)

        let keep = NSMenuItem(title: "Keep Files on Shelf After Dragging Out", action: #selector(toggleKeep), keyEquivalent: "")
        keep.target = self
        keep.state = Settings.keepAfterDragOut ? .on : .off
        menu.addItem(keep)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = launchAtLoginEnabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit DropShelf", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
