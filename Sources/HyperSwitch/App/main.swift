import AppKit

// Top-level code is only legal in a file named `main.swift`, which is the whole reason
// this one exists separately from `HyperSwitchApp.swift`. See the note there for why the
// app does not use a SwiftUI `App`/`Scene` at all.

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
