import Foundation
import ParallexCore

/// Resolve an instance argument (name or slug) or fail with the list of
/// instances that do exist.
func lookupInstance(_ nameOrSlug: String) throws -> InstanceManifest {
    if let manifest = InstanceStore.find(nameOrSlug) {
        return manifest
    }
    let names = InstanceStore.loadAll().map(\.name)
    let hint = names.isEmpty
        ? "No instances exist yet."
        : "Existing instances: \(names.joined(separator: ", "))"
    throw ParallexError("No instance named '\(nameOrSlug)'. \(hint)")
}

/// Parse repeated KEY=VALUE options.
func parseEnvironment(_ entries: [String], flag: String = "--env") throws -> [String: String] {
    var environment: [String: String] = [:]
    for entry in entries {
        guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
            throw ParallexError("\(flag) expects KEY=VALUE, got '\(entry)'.")
        }
        environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
    }
    return environment
}

/// Validate option IDs against what the app's recipe offers.
func checkOptionIDs(_ ids: [String], available: [RecipeOption]) throws {
    for id in ids where !available.contains(where: { $0.id == id }) {
        let offered = available.isEmpty
            ? "This app's recipe has no options."
            : "Available: \(available.map(\.id).joined(separator: ", "))"
        throw ParallexError("Unknown option '\(id)'. \(offered)")
    }
}

func printResultSummary(_ result: CreateResult, verb: String) {
    let manifest = result.manifest
    print("\(Term.green("✓")) \(verb) \(Term.bold("“\(manifest.name)”"))")
    print("  Wrapper  \(manifest.wrapperPath)")
    print("  Target   \(manifest.targetApp)  \(Term.dim("(\(result.frameworkDisplayName))"))")
    print("  Mode     \(manifest.mode.rawValue) — \(manifest.mode.summary)")
    for directory in result.dataDirectories {
        print("  Data     \(Paths.abbreviate(directory))")
    }
    if let home = result.homeDirectory {
        print("  Home     \(Paths.abbreviate(home))")
    }
    print("")
    for warning in result.warnings {
        Term.warn(warning)
    }
    for note in result.notes {
        Term.warn(note)
    }
}
