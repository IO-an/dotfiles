import AppKit
import Foundation

func emitChange() {
    FileHandle.standardOutput.write(Data("changed\n".utf8))
}

let distributedObserver = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
    object: nil,
    queue: nil
) { _ in
    emitChange()
}

// When a Mac wakes, re-check the selected appearance as well.
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: nil
) { _ in
    emitChange()
}

// Trigger one initial refresh after the process starts.
emitChange()
RunLoop.main.run()

// Keep observer tokens alive for the lifetime of the process.
withExtendedLifetime((distributedObserver, wakeObserver)) {}
