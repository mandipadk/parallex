import ArgumentParser
import Darwin
import Foundation
import ParallexCore

/// The workspace to run as, its persona turned on if it wasn't.
private func personaWorkspace(_ name: String) throws -> Workspace {
    var workspace = try WorkspaceCommand.lookup(name)
    if workspace.persona != true {
        workspace = try WorkspaceStore.update(id: workspace.id) { $0.persona = true }
        FileHandle.standardError.write(Data((
            "“\(workspace.name)” now has an identity of its own for your tools, for this and from now on: its git "
            + "settings start as yours (set what differs), its gh, cloud and cluster sign-ins start empty. "
            + "Everything else in your home is shared. (parallex workspace persona \"\(workspace.name)\" off undoes it.)\n"
        ).utf8))
    }
    Personas.prepare(workspace)
    return workspace
}

/// Replace this process with `arguments`, found on the PATH, in `environment`.
private func exec(_ arguments: [String], environment: [String: String]) throws -> Never {
    let name = arguments[0]
    let candidates = name.contains("/")
        ? [name]
        : (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map { "\($0)/\(name)" }
    var isDirectory: ObjCBool = false
    guard let path = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
            && FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue
    }) else {
        FileHandle.standardError.write(Data("parallex: \(name): command not found\n".utf8))
        Darwin.exit(127)
    }
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(path, argv, envp)
    throw ParallexError("Couldn't run \(name): \(String(cString: strerror(errno))).")
}

struct RunAs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command as a workspace, with its own git, gh, cloud and cluster identity.",
        discussion: """
        The command gets the workspace's persona as its home: your home, shared, \
        except for what says who you are to your tools (.gitconfig, .config/gh, \
        .aws, .kube, .config/gcloud, .npmrc, …), which is the workspace's own, and \
        without variables like GH_TOKEN or AWS_PROFILE that would point them back \
        at yours. Its git settings start as yours. The first run turns the \
        persona on. Set it up the way you would your own:

          parallex run "Client A" -- git config --global user.email me@client-a.com
          parallex run "Client A" -- gh auth login
          parallex run "Client A" -- git push

        Shells and tools that own-identity copies in the workspace start get it too.
        """
    )

    @Argument(help: "The workspace.")
    var workspace: String

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments (after --).")
    var command: [String] = []

    mutating func run() throws {
        var arguments = command
        if arguments.first == "--" { arguments.removeFirst() }
        guard !arguments.isEmpty else {
            throw ValidationError("Give a command to run, after --.")
        }
        let chosen = try personaWorkspace(workspace)
        try exec(arguments, environment: Personas.environment(for: chosen, base: ProcessInfo.processInfo.environment))
    }
}

struct ShellAs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Open your shell as a workspace (see `parallex run`).",
        discussion: "$PARALLEX_WORKSPACE names the workspace, for your prompt. Leave with exit."
    )

    @Argument(help: "The workspace.")
    var workspace: String

    mutating func run() throws {
        let chosen = try personaWorkspace(workspace)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        FileHandle.standardError.write(Data("You're “\(chosen.name)” in this shell. exit leaves.\n".utf8))
        try exec([shell, "-l"], environment: Personas.environment(for: chosen, base: ProcessInfo.processInfo.environment))
    }
}
