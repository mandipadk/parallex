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

    /// Read by the launcher: the persona its tools use (with `home`), and
    /// the proxy its workspace goes through (with `proxy`).
    public struct Marker: Codable, Sendable, Equatable {
        public var home: String?
        public var workspace: String
        public var items: [String]?
        public var proxy: String?
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

    /// Mirror your home into `home`, `items` aside, your Library included
    /// (tools keep caches and app support there; the persona is about who
    /// you are, not where things are).
    public static func prepare(home: URL, items: [String]) {
        let fm = FileManager.default
        let realHome = URL(fileURLWithPath: realHomePath(), isDirectory: true)
        HomeMirror.sync(home: home, realHome: realHome, privateItems: items, linkLibrary: true)
        // Its git settings start as yours (aliases, editor, …), from both
        // places git reads them: what's set for the workspace comes after,
        // so it wins, and `git config --global` always writes here, never
        // to yours.
        let gitconfig = home.appendingPathComponent(".gitconfig")
        if items.contains(".gitconfig"), !fm.fileExists(atPath: gitconfig.path) {
            var text = "# Your own settings first; what follows is this workspace's, and wins.\n"
            // (Git reads ~/.config/git/config by itself: yours, through the
            // home's link, unless the persona keeps .config/git its own.)
            let xdgOwn = items.contains { $0 == ".config/git" || $0 == ".config" }
            for yours in [realHome.appendingPathComponent(".config/git/config"), realHome.appendingPathComponent(".gitconfig")]
            where fm.fileExists(atPath: yours.path) && (xdgOwn || yours.lastPathComponent == ".gitconfig") {
                let quoted = yours.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                text += "[include]\n\tpath = \"\(quoted)\"\n"
            }
            fm.createFile(atPath: gitconfig.path, contents: Data((text + "\n").utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Settings in your environment that would take a tool straight to your
    /// own identity whatever HOME says: not passed on.
    static let identityVariables: Set<String> = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_CONFIG_DIR",
        "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "KUBECONFIG", "CLOUDSDK_CONFIG", "CLOUDSDK_CORE_ACCOUNT",
        "GOOGLE_APPLICATION_CREDENTIALS", "GIT_CONFIG_GLOBAL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
        "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "NPM_CONFIG_USERCONFIG", "npm_config_userconfig",
        "DOCKER_CONFIG", "NETRC",
    ]

    static func realHomePath() -> String {
        if let account = getpwuid(getuid()), let dir = account.pointee.pw_dir {
            return String(cString: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The environment a command runs with as `workspace`.
    public static func environment(for workspace: Workspace, base: [String: String]) -> [String: String] {
        var environment = base.filter { !identityVariables.contains($0.key) }
        let home = home(for: workspace).path
        let real = realHomePath()
        // XDG folders set to yours become the persona's.
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            if let value = environment[key], value == real || value.hasPrefix(real + "/") {
                environment[key] = home + value.dropFirst(real.count)
            }
        }
        environment["HOME"] = home
        environment["PARALLEX_WORKSPACE"] = workspace.name
        if let proxy = workspace.proxy {
            environment.merge(WorkspaceNetwork.environment(proxy: proxy)) { _, new in new }
        }
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
        // Named by the workspace's id, and its name only ever a quoted value:
        // nothing in a name can be taken for a command.
        let script = home.deletingLastPathComponent().appendingPathComponent("Open Terminal.command")
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let variables = identityVariables.sorted().joined(separator: " ")
        let text = """
        #!/bin/zsh
        # Opened by Parallex: a shell as one of your workspaces.
        export HOME=\(quote(home.path))
        export PARALLEX_WORKSPACE=\(quote(workspace.name))
        export ZDOTDIR="${ZDOTDIR:-"\(realHomePath().replacingOccurrences(of: "\"", with: "\\\""))"}"
        unset \(variables)
        cd "$HOME"
        printf "You're %s in this shell.\\n" "$PARALLEX_WORKSPACE"
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
            let persona = workspace(of: manifest.slug, in: workspaces)
            let network = workspaces.first { $0.proxy != nil && $0.members.contains(manifest.slug) }
            if let named = persona ?? network {
                let marker = Marker(
                    home: persona.map { home(for: $0).path }, workspace: named.name,
                    items: persona.map { items(for: $0) }, proxy: network?.proxy
                )
                if let data = try? encoder.encode(marker), (try? Data(contentsOf: url)) != data {
                    try? data.write(to: url, options: .atomic)
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
