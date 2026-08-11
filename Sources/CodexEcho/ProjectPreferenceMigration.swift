import Foundation

enum ProjectPreferenceMigration {
  static func migrate<Value: Equatable>(
    valuesByProjectID: inout [String: Value],
    authoritativeProjectIDs: inout Set<String>,
    migrationSourcesByProjectID: inout [String: String],
    from legacyProjectIDs: [String],
    to canonicalProjectID: String
  ) -> Bool {
    let legacyProjectIDs = Array(
      Set(legacyProjectIDs.filter { $0 != canonicalProjectID })
    ).sorted()
    guard !legacyProjectIDs.isEmpty else { return false }

    let previousValues = valuesByProjectID
    let previousAuthoritativeProjectIDs = authoritativeProjectIDs
    let previousMigrationSources = migrationSourcesByProjectID
    let canonicalMigrationSource = migrationSourcesByProjectID[canonicalProjectID]
    let canonicalIsAuthoritative =
      authoritativeProjectIDs.contains(canonicalProjectID)
      || (valuesByProjectID[canonicalProjectID] != nil && canonicalMigrationSource == nil)

    var candidates: [(sourceID: String, holderID: String, value: Value?)] = []
    if let canonicalMigrationSource {
      candidates.append(
        (
          sourceID: canonicalMigrationSource,
          holderID: canonicalProjectID,
          value: valuesByProjectID[canonicalProjectID]
        )
      )
    }
    for legacyProjectID in legacyProjectIDs {
      if let sourceID = migrationSourcesByProjectID[legacyProjectID] {
        candidates.append(
          (
            sourceID: sourceID,
            holderID: legacyProjectID,
            value: valuesByProjectID[legacyProjectID]
          )
        )
      } else if authoritativeProjectIDs.contains(legacyProjectID)
        || valuesByProjectID[legacyProjectID] != nil
      {
        candidates.append(
          (
            sourceID: legacyProjectID,
            holderID: legacyProjectID,
            value: valuesByProjectID[legacyProjectID]
          )
        )
      }
    }

    for legacyProjectID in legacyProjectIDs {
      valuesByProjectID.removeValue(forKey: legacyProjectID)
      authoritativeProjectIDs.remove(legacyProjectID)
      migrationSourcesByProjectID.removeValue(forKey: legacyProjectID)
    }

    if canonicalIsAuthoritative {
      authoritativeProjectIDs.insert(canonicalProjectID)
      migrationSourcesByProjectID.removeValue(forKey: canonicalProjectID)
    } else if let selected = candidates.min(by: {
      ($0.sourceID, $0.holderID) < ($1.sourceID, $1.holderID)
    }) {
      valuesByProjectID[canonicalProjectID] = selected.value
      authoritativeProjectIDs.remove(canonicalProjectID)
      migrationSourcesByProjectID[canonicalProjectID] = selected.sourceID
    }

    return valuesByProjectID != previousValues
      || authoritativeProjectIDs != previousAuthoritativeProjectIDs
      || migrationSourcesByProjectID != previousMigrationSources
  }
}
