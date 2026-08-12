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
    descriptorsByID = descriptors.reduce(into: [:]) { result, descriptor in
      // thread/list is ordered newest-first, so preserve the first descriptor if
      // an invalid external response repeats an ID.
      if result[descriptor.id] == nil {
        result[descriptor.id] = descriptor
      }
    }
    hasAuthoritativeSnapshot = true
    return Set(descriptorsByID.keys)
  }

  mutating func remove(_ conversationID: String) {
    descriptorsByID.removeValue(forKey: conversationID)
  }
}
