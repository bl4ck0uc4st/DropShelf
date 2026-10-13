import Cocoa

// DropShelf — a free, tiny Dropover-style "shake to get a shelf" app.
// Menu-bar only (no Dock icon). See README.md for build + usage.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
