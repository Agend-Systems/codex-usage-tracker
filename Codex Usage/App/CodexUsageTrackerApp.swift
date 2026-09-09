import AppKit
import SwiftUI
import UserNotifications

@main
struct CodexUsageTrackerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var preferences = TrackerPreferences.shared
  @StateObject private var store = UsageStore.shared

  var body: some Scene {
    MenuBarExtra {
      PopoverView()
    } label: {
      MenuBarLabel(preferences: preferences, store: store)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
    UNUserNotificationCenter.current().delegate = self
    Task { @MainActor in UsageStore.shared.start() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    UsageStore.terminateChildrenSynchronously()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
