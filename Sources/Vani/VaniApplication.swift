import AppKit
import SwiftUI

enum QAWindowMode: Equatable {
  case menu
  case settings
  case teach

  init?(environmentValue: String?) {
    switch environmentValue {
    case "1": self = .menu
    case "settings": self = .settings
    case "teach": self = .teach
    default: return nil
    }
  }
}

@MainActor
final class QAWindowLaunchGate {
  private let isRequested: Bool
  private let present: () -> Void
  private var applicationReady = false
  private var coordinatorReady = false
  private var didPresent = false

  init(isRequested: Bool, present: @escaping () -> Void) {
    self.isRequested = isRequested
    self.present = present
  }

  func markApplicationReady() {
    applicationReady = true
    presentIfReady()
  }

  func markCoordinatorReady() {
    coordinatorReady = true
    presentIfReady()
  }

  private func presentIfReady() {
    guard isRequested, applicationReady, coordinatorReady, !didPresent else { return }
    didPresent = true
    present()
  }
}

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

    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { coordinator.showSettings() }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var coordinator: AppCoordinator?
  private static let qaWindowLaunchGate = QAWindowLaunchGate(
    isRequested: QAWindowMode(
      environmentValue: ProcessInfo.processInfo.environment["VANI_QA_WINDOW"]
    ) != nil,
    present: { coordinator?.showQAWindowIfRequested() }
  )
  private var terminationInProgress = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    Self.qaWindowLaunchGate.markApplicationReady()
  }

  static func coordinatorDidBecomeReady() {
    guard coordinator != nil else { return }
    qaWindowLaunchGate.markCoordinatorReady()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress, let coordinator = Self.coordinator else {
      return terminationInProgress ? .terminateLater : .terminateNow
    }
    terminationInProgress = true
    Task {
      guard await coordinator.saveNotesBeforeTermination() else {
        terminationInProgress = false
        sender.reply(toApplicationShouldTerminate: false)
        return
      }
      await coordinator.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

}
