import AppKit
import SwiftUI

@main
struct VaniApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var coordinator = AppCoordinator()

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(coordinator)
    } label: {
      Label("Vani", systemImage: coordinator.menuBarIconName)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .environmentObject(coordinator)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
  }
}
