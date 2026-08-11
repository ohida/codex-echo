import Foundation

public struct CodexThreadDescriptor: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let cwd: String?
  public let updatedAt: Date?
  public let projectContext: CodexThreadProjectContext?

  init?(
    object: [String: Any],
    projectContext: CodexThreadProjectContext? = nil
  ) {
    guard let id = object["id"] as? String else { return nil }
    self.id = id
    self.cwd = object["cwd"] as? String
    self.projectContext = projectContext
    let rawTitle = (object["name"] as? String) ?? (object["preview"] as? String) ?? "Untitled task"
    let compactTitle =
      rawTitle.split(whereSeparator: \.isNewline).first.map(String.init) ?? rawTitle
    self.title = compactTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    self.updatedAt = Self.date(from: (object["updatedAt"] as? NSNumber)?.doubleValue)
  }

  private static func date(from timestamp: Double?) -> Date? {
    guard let timestamp, timestamp > 0 else { return nil }
    return Date(
      timeIntervalSince1970: timestamp > 1_000_000_000_000 ? timestamp / 1_000 : timestamp)
  }
}
