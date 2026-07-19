import Foundation

public actor SettingsStore {
  private let defaults: UserDefaults
  private let key: String
  private let suiteName: String?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var latestRevision: UInt64 = 0

  public init(suiteName: String? = nil, key: String = "vani.settings.v1") {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.key = key
    self.suiteName = suiteName
  }

  public func load() -> VaniSettings {
    guard let data = defaults.data(forKey: key),
      let settings = try? decoder.decode(VaniSettings.self, from: data)
    else {
      return .default
    }
    return settings
  }

  public func save(_ settings: VaniSettings) throws {
    let data = try encoder.encode(settings)
    defaults.set(data, forKey: key)
  }

  @discardableResult
  public func save(_ settings: VaniSettings, revision: UInt64) throws -> Bool {
    guard revision >= latestRevision else { return false }
    let data = try encoder.encode(settings)
    defaults.set(data, forKey: key)
    latestRevision = revision
    return true
  }

  public func reset() {
    defaults.removeObject(forKey: key)
  }

  func storeRawDataForTesting(_ data: Data) {
    defaults.set(data, forKey: key)
  }

  func clearSuiteForTesting() {
    if let suiteName {
      defaults.removePersistentDomain(forName: suiteName)
    } else {
      reset()
    }
  }
}
