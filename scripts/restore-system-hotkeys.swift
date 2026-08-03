#!/usr/bin/env swift

// Hands the system's ⌘Tab back, for the cases the app itself cannot cover.
//
// HyperSwitch switches the native shortcut off with `CGSSetSymbolicHotKeyEnabled` while it
// is running, and restores it on termination and at the next launch. Neither of those helps
// when the process is killed outright and *not* relaunched — which is exactly what a
// rebuild does, and what a `pkill` during development does. Left alone, the user is handed
// a Mac whose ⌘Tab does nothing and no running application to connect that to.
//
// The identifiers are the ones the app uses, and they were measured rather than looked up:
// walking `CGSGetSymbolicHotKeyValue` over every identifier and keeping those whose virtual
// key code is 48 (Tab) returns exactly 1 (⌘Tab) and 2 (⇧⌘Tab) on macOS 26.

import Foundation

typealias SetFn = @convention(c) (Int32, DarwinBoolean) -> Int32
typealias IsEnabledFn = @convention(c) (Int32) -> DarwinBoolean

let framework = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
guard let handle = dlopen(framework, RTLD_LAZY),
      let setSymbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled"),
      let isSymbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled")
else {
    FileHandle.standardError.write(Data("CGS symbolic hot key SPI unavailable\n".utf8))
    exit(1)
}

let setEnabled = unsafeBitCast(setSymbol, to: SetFn.self)
let isEnabled = unsafeBitCast(isSymbol, to: IsEnabledFn.self)

let commandTab: Int32 = 1
let commandShiftTab: Int32 = 2

if isEnabled(commandTab).boolValue && isEnabled(commandShiftTab).boolValue {
    print("system ⌘Tab already enabled")
    exit(0)
}

_ = setEnabled(commandTab, true)
_ = setEnabled(commandShiftTab, true)

// Clear the app's own bookkeeping too, so its next launch does not "restore" over a state
// that is already correct.
UserDefaults.standard.removePersistentDomain(forName: "com.hyperswitch.HyperSwitch")

print("system ⌘Tab restored: ⌘Tab=\(isEnabled(commandTab).boolValue) "
      + "⇧⌘Tab=\(isEnabled(commandShiftTab).boolValue)")
