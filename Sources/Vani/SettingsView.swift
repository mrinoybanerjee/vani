import SwiftUI
import VaniCore

struct SettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 0) {
      if let error = coordinator.settingsError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(error)
            .font(.caption)
          Spacer()
          Button {
            coordinator.dismissSettingsError()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        Divider()
      }

      TabView {
        GeneralSettingsView()
          .tabItem { Label("General", systemImage: "slider.horizontal.3") }
        DictionarySettingsView()
          .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        HistorySettingsView()
          .tabItem { Label("History", systemImage: "clock") }
        DiagnosticsSettingsView()
          .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
      }
    }
    .frame(width: 560, height: 410)
  }
}

private struct GeneralSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    Form {
      Section("Shortcut") {
        Picker(
          "Hold key",
          selection: Binding(
            get: { coordinator.settings.shortcut },
            set: { coordinator.setShortcut($0) }
          )
        ) {
          ForEach(HoldShortcut.allCases) { shortcut in
            Text(shortcut.label).tag(shortcut)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Startup") {
        Toggle(
          "Launch Vani at login",
          isOn: Binding(
            get: { coordinator.settings.launchAtLogin },
            set: { coordinator.setLaunchAtLogin($0) }
          ))
      }

      Section("Storage") {
        Toggle(
          "Save transcript history",
          isOn: Binding(
            get: { coordinator.settings.historyEnabled },
            set: { coordinator.setHistoryEnabled($0) }
          ))
      }

    }
    .formStyle(.grouped)
    .padding()
  }
}

private struct DictionarySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var spoken = ""
  @State private var replacement = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        TextField("Spoken phrase", text: $spoken)
        TextField("Replacement", text: $replacement)
        Button {
          coordinator.addDictionaryEntry(spoken: spoken, replacement: replacement)
          spoken = ""
          replacement = ""
        } label: {
          Image(systemName: "plus")
        }
        .disabled(
          spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Add correction")
      }

      List {
        ForEach(coordinator.settings.dictionary) { entry in
          HStack {
            Text(entry.spoken)
            Spacer()
            Image(systemName: "arrow.right")
              .foregroundStyle(.secondary)
            Text(entry.replacement)
          }
        }
        .onDelete { coordinator.removeDictionaryEntries(at: $0) }
      }
    }
    .padding(20)
  }
}

private struct HistorySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 12) {
      if coordinator.history.isEmpty {
        ContentUnavailableView("No History", systemImage: "clock")
      } else {
        List(coordinator.history) { entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
              .lineLimit(2)
              .textSelection(.enabled)
            Text(entry.createdAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      HStack {
        Spacer()
        Button("Clear", role: .destructive) {
          coordinator.clearHistory()
        }
        .disabled(coordinator.history.isEmpty)
      }
    }
    .padding(20)
  }
}

private struct DiagnosticsSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 12) {
      List(coordinator.diagnostics) { event in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(event.code)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(event.category.rawValue)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let duration = event.durationMilliseconds {
            Text("\(duration) ms")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise") {
          coordinator.refreshDiagnostics()
        }
        Spacer()
        Button("Clear", role: .destructive) {
          coordinator.clearDiagnostics()
        }
      }
    }
    .padding(20)
    .task { coordinator.refreshDiagnostics() }
  }
}
