import AppIntents
import AppKit
import ParallexCore

// Shortcuts actions and a Focus filter. Shortcuts finds them through
// Contents/Resources/Metadata.appintents, which `make app` generates from
// this file (SwiftPM compiles App Intents but doesn't extract their
// metadata; Xcode's processor does, run by hand).

// MARK: - Things to act on

struct InstanceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Instance"
    static let defaultQuery = InstanceQuery()

    let id: String
    let name: String
    let app: String

    init(_ manifest: InstanceManifest) {
        id = manifest.slug
        name = manifest.name
        app = manifest.targetDisplayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(app)")
    }
}

struct InstanceQuery: EntityStringQuery {
    private var all: [InstanceEntity] {
        InstanceStore.loadAll()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(InstanceEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [InstanceEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [InstanceEntity] {
        all.filter { $0.name.localizedStandardContains(string) || $0.app.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [InstanceEntity] { all }
}

struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static let defaultQuery = WorkspaceQuery()

    let id: String
    let name: String
    let count: Int

    init(_ workspace: Workspace) {
        id = workspace.id.uuidString
        name = workspace.name
        count = workspace.members.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(count == 1 ? "1 instance" : "\(count) instances")")
    }
}

struct WorkspaceQuery: EntityStringQuery {
    private var all: [WorkspaceEntity] {
        WorkspaceStore.load().map(WorkspaceEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        all.filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] { all }
}

struct ParallexIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static let instanceGone = ParallexIntentError(message: "That instance no longer exists.")
    static let workspaceGone = ParallexIntentError(message: "That workspace no longer exists.")
}

private func storedManifest(for instance: InstanceEntity) throws -> InstanceManifest {
    guard let manifest = InstanceStore.load(slug: instance.id) else { throw ParallexIntentError.instanceGone }
    return manifest
}

private func storedWorkspace(for entity: WorkspaceEntity) throws -> Workspace {
    guard let workspace = WorkspaceStore.load().first(where: { $0.id.uuidString == entity.id }) else {
        throw ParallexIntentError.workspaceGone
    }
    return workspace
}

// MARK: - Actions

struct OpenInstanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Instance"
    static let description = IntentDescription("Opens an instance, or brings it forward if it's already running.")

    @Parameter(title: "Instance") var instance: InstanceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$instance)")
    }

    func perform() async throws -> some IntentResult {
        let manifest = try storedManifest(for: instance)
        if let pid = Running.processID(of: manifest) {
            InstanceLauncher.bringForward(manifest, pid: pid)
        } else {
            try InstanceLauncher.launch(manifest)
        }
        return .result()
    }
}

struct QuitInstanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Instance"
    static let description = IntentDescription("Asks a running instance to quit, as ⌘Q would (it may ask to save first).")

    @Parameter(title: "Instance") var instance: InstanceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Quit \(\.$instance)")
    }

    func perform() async throws -> some IntentResult {
        let manifest = try storedManifest(for: instance)
        if let pid = Running.processID(of: manifest) {
            await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
        }
        return .result()
    }
}

struct IsInstanceRunningIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Instance Running"
    static let description = IntentDescription("Whether an instance is open right now.")

    @Parameter(title: "Instance") var instance: InstanceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Is \(\.$instance) running")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: Running.isRunning(try storedManifest(for: instance)))
    }
}

struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Workspace"
    static let description = IntentDescription("Opens every instance in a workspace, in its order.")

    @Parameter(title: "Workspace") var workspace: WorkspaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$workspace)")
    }

    func perform() async throws -> some IntentResult {
        let outcome = WorkspaceLauncher.open(try storedWorkspace(for: workspace))
        if let failure = outcome.failed.first {
            throw ParallexIntentError(message: "Couldn't open \(failure.name): \(failure.reason)")
        }
        return .result()
    }
}

struct QuitWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Workspace"
    static let description = IntentDescription("Asks every running instance in a workspace to quit.")

    @Parameter(title: "Workspace") var workspace: WorkspaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Quit \(\.$workspace)")
    }

    func perform() async throws -> some IntentResult {
        _ = WorkspaceLauncher.quit(try storedWorkspace(for: workspace))
        return .result()
    }
}

// MARK: - Focus

/// Focus › Focus Filters › Parallex: a workspace that opens when the Focus
/// turns on (Work opens Slack Work and Chrome Work), optionally quitting the
/// instances of other workspaces. Nothing happens when the Focus ends.
struct ParallexFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Open a Workspace"
    static let description: IntentDescription? = IntentDescription("Opens a workspace when this Focus turns on.")

    @Parameter(title: "Workspace") var workspace: WorkspaceEntity?
    @Parameter(title: "Quit Other Workspaces", default: false) var quitOthers: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let workspace else { return DisplayRepresentation(title: "Choose a workspace") }
        return DisplayRepresentation(
            title: "Opens \(workspace.name)",
            subtitle: quitOthers ? "and quits other workspaces" : nil
        )
    }

    /// What was last applied: macOS also delivers the filter when it's
    /// edited while the Focus is on, or synced from another device, and
    /// that shouldn't reopen what you've quit since (or quit things).
    private static let appliedKey = "focusFilterApplied"

    func perform() async throws -> some IntentResult {
        // The Focus ending comes here too, with nothing chosen.
        guard let workspace else {
            UserDefaults.standard.removeObject(forKey: Self.appliedKey)
            return .result()
        }
        let applied = "\(workspace.id)|\(quitOthers)"
        guard UserDefaults.standard.string(forKey: Self.appliedKey) != applied else { return .result() }
        UserDefaults.standard.set(applied, forKey: Self.appliedKey)
        let chosen = try storedWorkspace(for: workspace)
        if quitOthers {
            let keep = Set(chosen.members)
            for other in WorkspaceStore.load() where other.id != chosen.id {
                var others = other
                others.members.removeAll { keep.contains($0) }
                _ = WorkspaceLauncher.quit(others)
            }
        }
        _ = WorkspaceLauncher.open(chosen)
        return .result()
    }
}

// MARK: - Suggested shortcuts

struct ParallexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWorkspaceIntent(),
            phrases: ["Open a workspace in \(.applicationName)", "Open \(\.$workspace) in \(.applicationName)"],
            shortTitle: "Open Workspace",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: OpenInstanceIntent(),
            phrases: ["Open an instance in \(.applicationName)", "Open \(\.$instance) in \(.applicationName)"],
            shortTitle: "Open Instance",
            systemImageName: "square.on.square"
        )
    }
}
