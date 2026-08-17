import Foundation

enum PinnedModelDownloadError: Error, Equatable {
  case invalidSource
  case invalidPath
  case invalidResponse
  case invalidArtifact
}

actor PinnedModelDownloader {
  typealias Fetch = @Sendable (URL, Int) async throws -> (URL, URLResponse)

  private let repository: String
  private let revision: String
  private let verifier: ModelIntegrityVerifier
  private let fetch: Fetch
  private let fileManager: FileManager
  private let retryLimit: Int

  private static func downloadConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 1_800
    configuration.waitsForConnectivity = true
    return configuration
  }

  init(
    repository: String,
    revision: String,
    verifier: ModelIntegrityVerifier,
    fileManager: FileManager = .default,
    retryLimit: Int = 3,
    fetch: @escaping Fetch = PinnedModelDownloader.defaultFetch
  ) {
    self.repository = repository
    self.revision = revision
    self.verifier = verifier
    self.fileManager = fileManager
    self.retryLimit = max(1, retryLimit)
    self.fetch = fetch
  }

  func install(
    at targetDirectory: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard isSafeRepository(repository), isSafeRevision(revision),
      verifier.artifacts.allSatisfy({ isSafeRelativePath($0.path) })
    else {
      throw PinnedModelDownloadError.invalidSource
    }

    let parentDirectory = targetDirectory.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
    try recoverInterruptedReplacement(at: targetDirectory)
    let stagingRoot = parentDirectory.appendingPathComponent(
      ".vani-model-\(UUID().uuidString)",
      isDirectory: true
    )
    let stagedModel = stagingRoot.appendingPathComponent(
      targetDirectory.lastPathComponent,
      isDirectory: true
    )
    try fileManager.createDirectory(at: stagedModel, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingRoot.path)
    defer { try? fileManager.removeItem(at: stagingRoot) }

    let totalBytes = max(1, verifier.artifacts.reduce(0) { $0 + $1.byteCount })
    var completedBytes = 0
    progress(0)

    for artifact in verifier.artifacts {
      let sourceURL = try artifactURL(path: artifact.path)
      let temporaryURL = try await fetchWithRetry(sourceURL, expectedBytes: artifact.byteCount)
      defer { try? fileManager.removeItem(at: temporaryURL) }

      let destination = stagedModel.appendingPathComponent(artifact.path)
      let stagedPathPrefix = stagedModel.standardizedFileURL.path + "/"
      guard destination.standardizedFileURL.path.hasPrefix(stagedPathPrefix)
      else {
        throw PinnedModelDownloadError.invalidPath
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: temporaryURL, to: destination)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

      completedBytes += artifact.byteCount
      progress(Double(completedBytes) / Double(totalBytes))
    }

    do {
      try verifier.verify(directory: stagedModel, fileManager: fileManager)
    } catch {
      throw VaniFailure.modelIntegrityFailed
    }
    try replaceDirectory(at: targetDirectory, with: stagedModel)
    progress(1)
  }

  private func fetchWithRetry(_ sourceURL: URL, expectedBytes: Int) async throws -> URL {
    var lastError: Error = PinnedModelDownloadError.invalidResponse

    for attempt in 1...retryLimit {
      do {
        let (temporaryURL, response) = try await fetch(sourceURL, expectedBytes)
        guard let response = response as? HTTPURLResponse,
          response.statusCode == 200,
          response.url?.scheme == "https"
        else {
          try? fileManager.removeItem(at: temporaryURL)
          throw PinnedModelDownloadError.invalidResponse
        }
        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue == expectedBytes else {
          try? fileManager.removeItem(at: temporaryURL)
          throw PinnedModelDownloadError.invalidArtifact
        }
        return temporaryURL
      } catch {
        lastError = error
        guard attempt < retryLimit else { break }
        try await Task.sleep(for: .seconds(attempt))
      }
    }
    throw lastError
  }

  private func artifactURL(path: String) throws -> URL {
    guard isSafeRelativePath(path), let baseURL = URL(string: "https://huggingface.co") else {
      throw PinnedModelDownloadError.invalidPath
    }
    let components = [repository, "resolve", revision, path]
      .flatMap { $0.split(separator: "/").map(String.init) }
    return components.reduce(baseURL) { $0.appending(path: $1) }
  }

  private func replaceDirectory(at target: URL, with staged: URL) throws {
    guard fileManager.fileExists(atPath: target.path) else {
      try fileManager.moveItem(at: staged, to: target)
      return
    }

    let backup = target.deletingLastPathComponent().appendingPathComponent(
      "\(backupPrefix(for: target))\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.moveItem(at: target, to: backup)
    do {
      try fileManager.moveItem(at: staged, to: target)
      try? fileManager.removeItem(at: backup)
    } catch {
      if !fileManager.fileExists(atPath: target.path) {
        try? fileManager.moveItem(at: backup, to: target)
      }
      throw error
    }
  }

  private func recoverInterruptedReplacement(at target: URL) throws {
    let parent = target.deletingLastPathComponent()
    let prefix = backupPrefix(for: target)
    let candidates = try fileManager.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    ).filter { url in
      guard url.lastPathComponent.hasPrefix(prefix) else { return false }
      guard
        let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey,
          .isSymbolicLinkKey,
        ])
      else {
        return false
      }
      return values.isDirectory == true && values.isSymbolicLink != true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    if !fileManager.fileExists(atPath: target.path), let backup = candidates.last {
      try fileManager.moveItem(at: backup, to: target)
    }
    for backup in candidates where fileManager.fileExists(atPath: backup.path) {
      try? fileManager.removeItem(at: backup)
    }
  }

  private func backupPrefix(for target: URL) -> String {
    ".vani-model-backup-\(target.lastPathComponent)-"
  }

  private func isSafeRepository(_ value: String) -> Bool {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.count == 2 && components.allSatisfy(isSafeComponent)
  }

  private func isSafeRevision(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy(\.isHexDigit)
  }

  private func isSafeRelativePath(_ value: String) -> Bool {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return !value.hasPrefix("/") && !components.isEmpty
      && components.allSatisfy(isSafeComponent)
  }

  private func isSafeComponent(_ value: Substring) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("\\")
  }

  private static func defaultFetch(_ url: URL, expectedBytes: Int) async throws
    -> (URL, URLResponse)
  {
    let delegate = ByteLimitedDownloadDelegate(maximumBytes: expectedBytes)
    return try await delegate.download(
      from: url,
      configuration: downloadConfiguration()
    )
  }
}

private final class ByteLimitedDownloadDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let maximumBytes: Int64
  private let lock = NSLock()
  private var continuation: CheckedContinuation<(URL, URLResponse), any Error>?
  private var completed = false

  init(maximumBytes: Int) {
    self.maximumBytes = Int64(max(0, maximumBytes))
  }

  func download(
    from url: URL,
    configuration: URLSessionConfiguration
  ) async throws -> (URL, URLResponse) {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        self.continuation = continuation
      }
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      session.downloadTask(with: url).resume()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten <= maximumBytes,
      totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
        || totalBytesExpectedToWrite <= maximumBytes
    else {
      downloadTask.cancel()
      finish(.failure(PinnedModelDownloadError.invalidArtifact), session: session)
      return
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
        byteCount == maximumBytes,
        let response = downloadTask.response
      else {
        throw PinnedModelDownloadError.invalidArtifact
      }
      let retainedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "VaniPinnedDownload-\(UUID().uuidString)"
      )
      try FileManager.default.moveItem(at: location, to: retainedURL)
      finish(.success((retainedURL, response)), session: session)
    } catch {
      finish(.failure(error), session: session)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    guard let error else { return }
    finish(.failure(error), session: session)
  }

  private func finish(
    _ result: Result<(URL, URLResponse), any Error>,
    session: URLSession
  ) {
    let continuation = lock.withLock { () -> CheckedContinuation<(URL, URLResponse), any Error>? in
      guard !completed else { return nil }
      completed = true
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    guard let continuation else { return }
    session.finishTasksAndInvalidate()
    continuation.resume(with: result)
  }
}
