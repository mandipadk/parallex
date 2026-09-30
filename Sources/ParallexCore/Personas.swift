import Foundation
import ParallexKit

/// A workspace as an identity for your command-line tools too. With its
/// persona on, a workspace has a home of its own for them
/// (`<support>/personas/<id>/home`): it mirrors yours, links and all,
/// except for the items that say who you are to a tool (your git identity,
/// gh, cloud and cluster sign-ins, registries), which are the workspace's.
/// `parallex run <workspace> -- <command>` and `parallex shell` use it, and
/// so do the shells and tools that copies in the workspace start (with
/// their own Library): a terminal or editor copy in "Client A" commits as
/// Client A.
public enum Personas {
    /// Items tools find through $HOME that make up who you are to them.
    /// (Not ~/.docker: its plugins live there, and `docker compose` with
    /// them. Add it, or anything else, per workspace.)
    public static let defaultItems = [
        ".gitconfig", ".git-credentials", ".config/gh", ".aws", ".kube", ".config/gcloud",
        ".npmrc", ".yarnrc.yml", ".netrc", ".config/hub",
    ]

    /// Beside a copy's instance folder's record: which persona its tools use.
    public static let markerFile = "persona.json"

    public struct Marker: Codable, Sendable, Equatable {
        public var home: String
        public var workspace: String
        public var items: [String]
    }

    public static func home(for workspace: Workspace) -> URL {
        Paths.supportRoot.appendingPathComponent("personas", isDirectory: true)
            .appendingPathComponent(workspace.id.uuidString, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    public static func items(for workspace: Workspace) -> [String] {
        workspace.personaItems ?? defaultItems
    }

    /// Make (or bring up to date) the persona's home.
    @discardableResult
    public static func prepare(_ workspace: Workspace) -> URL {
        let home = home(for: workspace)
        prepare(home: home, items: items(for: workspace))
        return home
    }

    /// Mirror your home into `home`, `items` aside, and link your Library
    /// (tools keep caches and app support there; the persona is about who
    /// you are, not where things are).
    public static func prepare(home: URL, items: [String]) {
        let fm = FileManager.default
        let realHome = URL(fileURLWithPath: realHomePath(), isDirectory: true)
        HomeMirror.sync(home: home, realHome: realHome, privateItems: items)
        let library = home.appendingPathComponent("Library")
        if (try? fm.destinationOfSymbolicLink(atPath: library.path)) == nil, !fm.fileExists(atPath: library.path) {
            try? fm.createSymbolicLink(at: library, withDestinationURL: realHome.appendingPathComponent("Library"))
        }
        // Its git settings start as yours (aliases, editor, …): what's set
        // for the workspace comes after, so it wins.
        let gitconfig = home.appendingPathComponent(".gitconfig")
        let yours = realHome.appendingPathComponent(".gitconfig")
        if items.contains(".gitconfig"), !fm.fileExists(atPath: gitconfig.path), fm.fileExists(atPath: yours.path) {
            let text = """
            # Your own settings first; what follows is this workspace's, and wins.
            [include]
            \tpath = \(yours.path)

            """
            fm.createFile(atPath: gitconfig.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    static func realHomePath() -> String {
        if let account = getpwuid(getuid()), let dir = account.pointee.pw_dir {
            return String(cString: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The environment a command runs with as `workspace`.
    public static func environment(for workspace: Workspace, base: [String: String]) -> [String: String] {
        var environment = base
        environment["HOME"] = home(for: workspace).path
        environment["PARALLEX_WORKSPACE"] = workspace.name
        // zsh reads its settings from ZDOTDIR, or HOME: yours, as always.
        if environment["ZDOTDIR"] == nil {
            environment["ZDOTDIR"] = realHomePath()
        }
        return environment
    }

    /// A script Terminal opens as a shell of the workspace's (what `parallex
    /// shell` does, without needing the command-line tool).
    public static func terminalScript(for workspace: Workspace) throws -> URL {
        let home = prepare(workspace)
        let script = home.deletingLastPathComponent().appendingPathComponent("\(workspace.name).command")
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let text = """
        #!/bin/zsh
        # Opened by Parallex: a shell as the workspace \(workspace.name).
        export HOME=\(quote(home.path))
        export PARALLEX_WORKSPACE=\(quote(workspace.name))
        export ZDOTDIR="${ZDOTDIR:-\(realHomePath())}"
        cd "$HOME"
        echo "You're \(workspace.name) in this shell."
        exec "${SHELL:-/bin/zsh}" -l

        """
        try Data(text.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    /// The persona workspace an instance's tools use: the first workspace
    /// with its persona on that it's in.
    public static func workspace(of slug: String, in workspaces: [Workspace]) -> Workspace? {
        workspaces.first { $0.persona == true && $0.members.contains(slug) }
    }

    /// Tell each instance which persona its tools use (read by its launcher).
    public static func syncMarkers(workspaces: [Workspace], manifests: [InstanceManifest] = InstanceStore.loadAll()) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for manifest in manifests {
            let url = Paths.instanceDir(slug: manifest.slug).appendingPathComponent(markerFile)
            if let workspace = workspace(of: manifest.slug, in: workspaces) {
                let marker = Marker(home: home(for: workspace).path, workspace: workspace.name, items: items(for: workspace))
                if let data = try? encoder.encode(marker), (try? Data(contentsOf: url)) != data {
                    try? data.write(to: url, options: .atomic)
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
