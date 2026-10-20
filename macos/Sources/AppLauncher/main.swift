import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MenuApp()
app.delegate = delegate
app.run()
