import CodexAppServer

struct CodexTaskCatalog {
  private var descriptorsByID: [String: CodexThreadDescriptor] = [:]
  private var hasAuthoritativeSnapshot = false

  var authoritativeIDs: Set<String>? {
    guard hasAuthoritativeSnapshot else { return nil }
    return Set(descriptorsByID.keys)
  }

  func admits(_ conversationID: String) -> Bool {
    !hasAuthoritativeSnapshot || descriptorsByID[conversationID] != nil
  }

  func descriptor(for conversationID: String) -> CodexThreadDescriptor? {
    descriptorsByID[conversationID]
  }

  @discardableResult
  mutating func replace(with descriptors: [CodexThreadDescriptor]) -> Set<String> {
    descriptorsByID = Dictionary(
      uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
    )
    hasAuthoritativeSnapshot = true
    return Set(descriptorsByID.keys)
  }

  mutating func remove(_ conversationID: String) {
    descriptorsByID.removeValue(forKey: conversationID)
  }
}
