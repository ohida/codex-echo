import AppKit
import Combine
import Foundation
import SwiftUI

enum ProjectCustomizationWindowMetrics {
  static let width: CGFloat = 620
  static let height: CGFloat = 380
  static let minimumWidth: CGFloat = 520
  static let minimumHeight: CGFloat = 300
}

@MainActor
enum ProjectCustomizationWindowFactory {
  static let frameAutosaveName =
    NSWindow.FrameAutosaveName("CodexEcho.ProjectCustomizations")

  static func make(
    customizations: TaskCustomizationStore,
    savesFrame: Bool = true
  ) -> NSWindowController {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: ProjectCustomizationWindowMetrics.width,
        height: ProjectCustomizationWindowMetrics.height
      ),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Project Customizations"
    window.contentMinSize = NSSize(
      width: ProjectCustomizationWindowMetrics.minimumWidth,
      height: ProjectCustomizationWindowMetrics.minimumHeight
    )
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    if savesFrame {
      window.setFrameAutosaveName(frameAutosaveName)
    }

    window.contentView = NSHostingView(
      rootView: ProjectCustomizationSettingsView(
        customizations: customizations,
        close: { [weak window] in
          window?.performClose(nil)
        }
      )
    )

    let windowController = NSWindowController(window: window)
    windowController.shouldCascadeWindows = true
    return windowController
  }
}

struct ProjectCustomization: Equatable, Identifiable {
  let identity: TaskProjectIdentity
  let color: TaskAccentColor?
  let voice: SpokenUpdateVoice?

  init(
    identity: TaskProjectIdentity,
    color: TaskAccentColor?,
    voice: SpokenUpdateVoice?
  ) {
    self.identity = identity
    self.color = color
    self.voice = voice
  }

  init(
    projectID: String,
    color: TaskAccentColor?,
    voice: SpokenUpdateVoice?
  ) {
    self.init(identity: .project(projectID), color: color, voice: voice)
  }

  var id: TaskProjectIdentity { identity }
  var projectID: String? { identity.projectID }

  var displayName: String { identity.displayName }
}

@MainActor
final class TaskCustomizationStore: ObservableObject {
  @Published private(set) var projectCustomizations: [ProjectCustomization]

  let projectCustomizationDidChange = PassthroughSubject<TaskProjectIdentity, Never>()

  private let userDefaults: UserDefaults
  private var colorPreferences: TaskColorPreferences
  private var voicePreferences: TaskVoicePreferences

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    let colorPreferences = TaskColorPreferences.load(from: userDefaults)
    let voicePreferences = TaskVoicePreferences.load(from: userDefaults)
    self.colorPreferences = colorPreferences
    self.voicePreferences = voicePreferences
    self.projectCustomizations = Self.makeProjectCustomizations(
      colorPreferences: colorPreferences,
      voicePreferences: voicePreferences
    )
  }

  func taskColor(for taskID: String) -> TaskAccentColor? {
    colorPreferences.taskColor(for: taskID)
  }

  func taskColorPreference(for taskID: String) -> TaskColorPreference {
    colorPreferences.taskColorPreference(for: taskID)
  }

  func projectColor(for projectID: String?) -> TaskAccentColor? {
    colorPreferences.projectColor(for: projectID)
  }

  func parentColor(for identity: TaskProjectIdentity?) -> TaskAccentColor? {
    colorPreferences.parentColor(for: identity)
  }

  func setTaskColorPreference(
    _ preference: TaskColorPreference,
    for taskID: String
  ) {
    colorPreferences.setTaskColorPreference(preference, for: taskID)
    colorPreferences.save(to: userDefaults)
  }

  func setProjectColor(_ color: TaskAccentColor?, for projectID: String) {
    setParentColor(color, for: .project(projectID))
  }

  func setParentColor(_ color: TaskAccentColor?, for identity: TaskProjectIdentity) {
    switch identity {
    case .project(let projectID):
      colorPreferences.setProjectColor(color, for: projectID)
    case .noProject:
      colorPreferences.setNoProjectColor(color)
    }
    colorPreferences.save(to: userDefaults)
    finishProjectCustomizationChange(for: identity)
  }

  func taskVoice(for taskID: String) -> SpokenUpdateVoice? {
    voicePreferences.taskVoice(for: taskID)
  }

  func taskVoicePreference(for taskID: String) -> TaskVoicePreference {
    voicePreferences.taskVoicePreference(for: taskID)
  }

  func projectVoice(for projectID: String?) -> SpokenUpdateVoice? {
    voicePreferences.projectVoice(for: projectID)
  }

  func parentVoice(for identity: TaskProjectIdentity?) -> SpokenUpdateVoice? {
    voicePreferences.parentVoice(for: identity)
  }

  func setTaskVoicePreference(
    _ preference: TaskVoicePreference,
    for taskID: String
  ) {
    voicePreferences.setTaskVoicePreference(preference, for: taskID)
    voicePreferences.save(to: userDefaults)
  }

  func setProjectVoice(_ voice: SpokenUpdateVoice?, for projectID: String) {
    setParentVoice(voice, for: .project(projectID))
  }

  func migrateProjectCustomizations(
    _ aliases: [(legacyProjectID: String, canonicalProjectID: String)]
  ) {
    let candidateAliases = aliases
      .filter { $0.legacyProjectID != $0.canonicalProjectID }
    let canonicalIDsByLegacyProjectID = Dictionary(
      grouping: candidateAliases,
      by: \.legacyProjectID
    ).mapValues { Set($0.map(\.canonicalProjectID)) }
    let canonicalProjectIDs = Set(candidateAliases.map(\.canonicalProjectID))
    let unambiguousAliases = candidateAliases.filter {
      canonicalIDsByLegacyProjectID[$0.legacyProjectID]?.count == 1
        && !canonicalProjectIDs.contains($0.legacyProjectID)
    }
    let aliasesByCanonicalProjectID = Dictionary(
      grouping: unambiguousAliases,
      by: \.canonicalProjectID
    )

    var migratedColor = false
    var migratedVoice = false
    for canonicalProjectID in aliasesByCanonicalProjectID.keys.sorted() {
      let legacyProjectIDs = aliasesByCanonicalProjectID[canonicalProjectID, default: []]
        .map(\.legacyProjectID)
      migratedColor = colorPreferences.migrateProjectColors(
        from: legacyProjectIDs,
        to: canonicalProjectID
      ) || migratedColor
      migratedVoice = voicePreferences.migrateProjectVoices(
        from: legacyProjectIDs,
        to: canonicalProjectID
      ) || migratedVoice
    }
    guard migratedColor || migratedVoice else { return }

    if migratedColor {
      colorPreferences.save(to: userDefaults)
    }
    if migratedVoice {
      voicePreferences.save(to: userDefaults)
    }
    projectCustomizations = Self.makeProjectCustomizations(
      colorPreferences: colorPreferences,
      voicePreferences: voicePreferences
    )
  }

  func setParentVoice(_ voice: SpokenUpdateVoice?, for identity: TaskProjectIdentity) {
    switch identity {
    case .project(let projectID):
      voicePreferences.setProjectVoice(voice, for: projectID)
    case .noProject:
      voicePreferences.setNoProjectVoice(voice)
    }
    voicePreferences.save(to: userDefaults)
    finishProjectCustomizationChange(for: identity)
  }

  func removeProjectCustomization(for projectID: String) {
    removeProjectCustomization(for: .project(projectID))
  }

  func removeProjectCustomization(for identity: TaskProjectIdentity) {
    switch identity {
    case .project(let projectID):
      colorPreferences.setProjectColor(nil, for: projectID)
      voicePreferences.setProjectVoice(nil, for: projectID)
    case .noProject:
      colorPreferences.setNoProjectColor(nil)
      voicePreferences.setNoProjectVoice(nil)
    }
    colorPreferences.save(to: userDefaults)
    voicePreferences.save(to: userDefaults)
    finishProjectCustomizationChange(for: identity)
  }

  private func finishProjectCustomizationChange(for identity: TaskProjectIdentity) {
    projectCustomizations = Self.makeProjectCustomizations(
      colorPreferences: colorPreferences,
      voicePreferences: voicePreferences
    )
    projectCustomizationDidChange.send(identity)
  }

  private static func makeProjectCustomizations(
    colorPreferences: TaskColorPreferences,
    voicePreferences: TaskVoicePreferences
  ) -> [ProjectCustomization] {
    let projectCustomizations = colorPreferences.customizedProjectIDs
      .union(voicePreferences.customizedProjectIDs)
      .map { projectID in
        ProjectCustomization(
          projectID: projectID,
          color: colorPreferences.projectColor(for: projectID),
          voice: voicePreferences.projectVoice(for: projectID)
        )
      }
      .sorted {
        ($0.projectID ?? "").localizedStandardCompare($1.projectID ?? "") == .orderedAscending
      }
    return [
      ProjectCustomization(
        identity: .noProject,
        color: colorPreferences.noProjectColor,
        voice: voicePreferences.noProjectVoice
      )
    ] + projectCustomizations
  }
}

struct ProjectCustomizationSettingsView: View {
  @ObservedObject var customizations: TaskCustomizationStore
  let close: () -> Void

  @State private var pendingRemoval: ProjectCustomization?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "Set shared defaults for No Project tasks, or review and remove colors and voices saved for projects. Project folders and Codex tasks are not changed."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(customizations.projectCustomizations) { customization in
            projectRow(customization)
              .padding(.horizontal, 12)

            if customization.id
              != customizations.projectCustomizations.last?.id
            {
              Divider()
                .padding(.leading, 12)
            }
          }
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.55), lineWidth: 1)
      }

      if let pendingRemoval {
        removalConfirmation(for: pendingRemoval)
      }

      HStack {
        Spacer()
        Button("Done") {
          close()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(
      minWidth: ProjectCustomizationWindowMetrics.minimumWidth,
      idealWidth: ProjectCustomizationWindowMetrics.width,
      maxWidth: .infinity,
      minHeight: ProjectCustomizationWindowMetrics.minimumHeight,
      idealHeight: ProjectCustomizationWindowMetrics.height,
      maxHeight: .infinity
    )
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func projectRow(_ customization: ProjectCustomization) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(customization.displayName)
          .font(.body)
          .lineLimit(1)

        if let projectID = customization.projectID {
          Text(projectID)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(projectID)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if customization.identity == .noProject {
        noProjectColorPicker(customization)
        noProjectVoicePicker(customization)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          if let color = customization.color {
            Label {
              Text(color.displayName)
            } icon: {
              Circle()
                .fill(color.color)
                .frame(width: 9, height: 9)
            }
            .accessibilityLabel("Color, \(color.displayName)")
          }

          if let voice = customization.voice {
            Label(voice.displayName, systemImage: "waveform")
              .accessibilityLabel("Voice, \(voice.displayName)")
          }
        }
        .font(.caption)
        .frame(width: 110, alignment: .leading)
      }

      if customization.color != nil || customization.voice != nil {
        Button("Remove…", role: .destructive) {
          pendingRemoval = customization
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(
          "Remove customizations for \(customization.displayName)"
        )
      }
    }
    .padding(.vertical, 4)
  }

  private func noProjectColorPicker(
    _ customization: ProjectCustomization
  ) -> some View {
    Picker(
      "No Project Color",
      selection: Binding(
        get: { customization.color },
        set: { color in
          customizations.setParentColor(color, for: .noProject)
        }
      )
    ) {
      Text("Default Color").tag(TaskAccentColor?.none)
      ForEach(TaskAccentColor.allCases) { color in
        Text(color.displayName).tag(Optional(color))
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .frame(width: 120)
    .accessibilityLabel("No Project Color")
  }

  private func noProjectVoicePicker(
    _ customization: ProjectCustomization
  ) -> some View {
    Picker(
      "No Project Voice",
      selection: Binding(
        get: { customization.voice },
        set: { voice in
          customizations.setParentVoice(voice, for: .noProject)
        }
      )
    ) {
      Text("Default Voice").tag(SpokenUpdateVoice?.none)
      ForEach(SpokenUpdateVoiceCatalog.availableEnglishUSVoices) { voice in
        Text(voice.displayName).tag(Optional(voice))
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .frame(width: 140)
    .accessibilityLabel("No Project Voice")
  }

  private func removalConfirmation(
    for customization: ProjectCustomization
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Remove customizations for \(customization.displayName)?")
        .font(.headline)

      Text(
        "This returns the selection to the default color and voice. Project folders and Codex tasks will not be deleted."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          pendingRemoval = nil
        }
        Button("Remove", role: .destructive) {
          customizations.removeProjectCustomization(
            for: customization.identity
          )
          pendingRemoval = nil
        }
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
  }
}
