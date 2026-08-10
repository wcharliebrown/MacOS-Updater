import AppKit

// An explicit AppKit entry point rather than a SwiftUI `App`.
//
// SwiftUI's `MenuBarExtra` produced no status item in this bundle, and a `Window`
// scene only opened when it happened to be declared first. Owning the status item and
// windows directly makes the app's lifecycle predictable, and the views stay SwiftUI.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// A menu bar utility: no Dock icon, no app switcher entry.
application.setActivationPolicy(.accessory)
application.run()
