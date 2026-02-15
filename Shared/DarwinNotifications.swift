import Foundation

/// Darwin notification names for IPC between the app and the Broadcast Upload Extension.
enum DarwinNotifications {
    static let broadcastStarted: CFString = "com.voiceping.translate.broadcastStarted" as CFString
    static let broadcastStopped: CFString = "com.voiceping.translate.broadcastStopped" as CFString
    static let stopBroadcast = CFNotificationName("com.voiceping.translate.stopBroadcast" as CFString)
    static let audioReady: CFString = "com.voiceping.translate.audioReady" as CFString
}
