import Foundation

/// Navigation owns no recording or storage work; the existing feature models keep that lifetime.
@MainActor
final class WorkspaceModel: ObservableObject {
  enum Section: String, CaseIterable, Identifiable {
    case meetings = "Meetings"
    case notes = "Notes"
    case settings = "Settings"
    var id: Self { self }
    var icon: String {
      switch self {
      case .meetings: "waveform"
      case .notes: "note.text"
      case .settings: "gearshape"
      }
    }
  }

  let notes: NotesModel
  let meetings: MeetingModel
  @Published private(set) var selection: Section = .meetings
  @Published private(set) var transitioning = false

  init(notes: NotesModel = NotesModel(), meetings: MeetingModel) {
    self.notes = notes
    self.meetings = meetings
  }

  @discardableResult
  func select(_ section: Section) async -> Bool {
    guard !transitioning else { return false }
    transitioning = true
    defer { transitioning = false }
    if section != selection {
      switch selection {
      case .notes: guard await notes.save() else { return false }
      case .meetings: guard await meetings.prepareToClose() else { return false }
      case .settings: break
      }
      selection = section
    }
    switch section {
    case .notes: await notes.load()
    case .meetings: await meetings.load()
    case .settings: break
    }
    return true
  }

  func prepareToClose(quitting: Bool = false) async -> Bool {
    guard !transitioning else { return false }
    transitioning = true
    defer { transitioning = false }
    let meetingSaved =
      quitting
      ? await meetings.prepareToQuit() : await meetings.prepareToClose()
    guard meetingSaved else {
      selection = .meetings
      return false
    }
    guard await notes.save() else {
      selection = .notes
      return false
    }
    return true
  }
}
