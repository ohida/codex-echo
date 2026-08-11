import Darwin
import Foundation

final class ApplicationInstanceLock {
  let fileURL: URL
  let fileDescriptor: Int32

  private init(fileURL: URL, fileDescriptor: Int32) {
    self.fileURL = fileURL
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    _ = Darwin.close(fileDescriptor)
  }

  static func defaultFileURL(
    fileManager: FileManager = .default,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
      .appendingPathComponent(
        bundleIdentifier ?? AppIdentity.bundleIdentifier,
        isDirectory: true
      )
      .appendingPathComponent("instance.lock")
  }

  static func acquire(
    fileURL: URL = defaultFileURL(),
    fileManager: FileManager = .default
  ) throws -> ApplicationInstanceLock? {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let fileDescriptor = fileURL.path.withCString {
      Darwin.open(
        $0,
        O_CREAT | O_RDWR | O_CLOEXEC,
        mode_t(S_IRUSR | S_IWUSR)
      )
    }
    guard fileDescriptor >= 0 else {
      throw posixError(errno)
    }

    var fileLock = Darwin.flock()
    fileLock.l_type = Int16(F_WRLCK)
    fileLock.l_whence = Int16(SEEK_SET)
    fileLock.l_start = 0
    fileLock.l_len = 0
    guard Darwin.fcntl(fileDescriptor, F_SETLK, &fileLock) == 0 else {
      let errorCode = errno
      _ = Darwin.close(fileDescriptor)
      if errorCode == EACCES || errorCode == EAGAIN {
        return nil
      }
      throw posixError(errorCode)
    }

    return ApplicationInstanceLock(
      fileURL: fileURL,
      fileDescriptor: fileDescriptor
    )
  }

  private static func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }
}

enum ApplicationInstanceLaunchCopy {
  static let alreadyRunningTitle = "Codex Echo is already running."
  static let alreadyRunningMessage = "Use the existing menu bar item."
  static let lockFailureTitle = "Codex Echo couldn’t start."
  static let lockFailureMessage =
    "The app couldn’t secure exclusive access to its local data. Quit any existing Codex Echo process, then try again."
}
