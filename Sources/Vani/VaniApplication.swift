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
  static weak var coordinator: AppCoordinator?
  private var terminationInProgress = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress, let coordinator = Self.coordinator else {
      return terminationInProgress ? .terminateLater : .terminateNow
    }
    terminationInProgress = true
    Task {
      await coordinator.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
