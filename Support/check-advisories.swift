// Checks advisories/advisories.json before it's signed: valid, every
// version range well formed (the same rules Parallex reads them by), and
// `issued` newer than the file published now (Parallex ignores an older one).
//
//   swift Support/check-advisories.swift <new> <published>
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func isVersion(_ text: String) -> Bool {
    text.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
}

func isValidRange(_ range: String) -> Bool {
    let trimmed = range.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "*" { return true }
    return trimmed.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { part in
        let part = part.trimmingCharacters(in: .whitespaces)
        if part.contains("...") {
            let bounds = part.components(separatedBy: "...")
            return bounds.count == 2 && bounds.allSatisfy { isVersion($0.trimmingCharacters(in: .whitespaces)) }
        }
        for prefix in ["<=", ">=", "<", ">"] where part.hasPrefix(prefix) {
            return isVersion(String(part.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return isVersion(part)
    }
}

func issued(_ path: String) -> Date? {
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["issued"] as? String
    else { return nil }
    return ISO8601DateFormatter().date(from: text)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: check-advisories.swift <new> <published>") }
guard let data = FileManager.default.contents(atPath: arguments[1]),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
else { fail("\(arguments[1]) isn't valid JSON") }
guard let newIssued = issued(arguments[1]) else { fail("\"issued\" must be a date like 2026-10-01T09:00:00Z") }
for app in object["apps"] as? [[String: Any]] ?? [] {
    guard app["bundleID"] is String, app["message"] is String, ["warning", "unsupported"].contains(app["level"] as? String ?? "") else {
        fail("each app notice needs bundleID, message and a level of warning or unsupported")
    }
    if let range = app["versions"] as? String, !isValidRange(range) { fail("bad versions range: \(range)") }
    if let range = app["parallex"] as? String, !isValidRange(range) { fail("bad parallex range: \(range)") }
}
for message in object["messages"] as? [[String: Any]] ?? [] {
    guard message["id"] is String, message["title"] is String, message["body"] is String else { fail("each message needs id, title and body") }
    if let range = message["parallex"] as? String, !isValidRange(range) { fail("bad parallex range: \(range)") }
    if let link = message["link"] as? String, !link.hasPrefix("https://") { fail("links must be https: \(link)") }
}
func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
}
// The same rules Parallex applies (Knowledge.swift): what it would drop is
// an error here, and types are exact (Parallex can't read a file that
// isn't, and would then miss every notice in it).
let sharedDotfolders: Set<String> = ["config", "local", "cache", "ssh", "gnupg", "claude", "codex", "aws", "kube", "docker", "npm",
                                     "cargo", "rustup", "gem", "bundle", "zsh", "oh-my-zsh", "git", "vim", "trash"]
if let knowledge = object["knowledge"] {
    guard let entries = knowledge as? [[String: Any]] else { fail("\"knowledge\" must be a list of entries") }
    let known: Set<String> = ["bundleID", "versions", "dataFolders", "homeFolders", "singleInstancePorts"]
    for entry in entries {
        guard let bundleID = entry["bundleID"] as? String, !bundleID.isEmpty else { fail("each knowledge entry needs a bundleID") }
        if let unknown = entry.keys.first(where: { !known.contains($0) }) { fail("\(bundleID): unknown key \(unknown)") }
        if let versions = entry["versions"] {
            guard let range = versions as? String, isValidRange(range) else { fail("\(bundleID): bad versions range") }
        }
        if let value = entry["dataFolders"] {
            guard let folders = value as? [String], folders.count <= 32 else { fail("\(bundleID): dataFolders must be up to 32 names") }
            for folder in folders {
                let lower = folder.lowercased()
                guard isPlainName(folder), !lower.hasPrefix("com.apple."),
                      !["parallex", "clouddocs", "mobilesync", "addressbook", "icloud", "knowledge"].contains(lower)
                else { fail("\(bundleID): not an app's data folder: \(folder)") }
            }
        }
        if let value = entry["homeFolders"] {
            guard let items = value as? [String], items.count <= 32 else { fail("\(bundleID): homeFolders must be up to 32 items") }
            for item in items {
                let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard let first = parts.first, first.hasPrefix("."), parts.allSatisfy(isPlainName) else {
                    fail("\(bundleID): home folders are hidden items relative to home, like .acme or .config/acme: \(item)")
                }
                let name = String(first.dropFirst()).lowercased()
                let sharedFiles: Set<String> = ["zshrc", "zprofile", "zshenv", "zlogin", "bashrc", "bash_profile", "profile",
                                                "npmrc", "netrc", "yarnrc", "yarnrc.yml", "gitconfig", "git-credentials", "inputrc"]
                if sharedFiles.contains(name)
                    || (name == "config" && parts.count >= 2 && ["git", "gh", "gcloud", "hub"].contains(parts[1].lowercased())) {
                    fail("\(bundleID): \(item) is shared by everything, not one app's")
                }
                let allowed: Bool
                switch name {
                case "config": allowed = parts.count >= 2
                case "local", "cache": allowed = parts.count >= 3
                default: allowed = !sharedDotfolders.contains(name) && ![".gitconfig", ".ssh"].contains(item.lowercased())
                }
                guard allowed else { fail("\(bundleID): \(item) is shared by everything, not one app's") }
            }
        }
        if let value = entry["singleInstancePorts"] {
            guard let ports = value as? [[String: Any]], ports.count <= 16 else { fail("\(bundleID): singleInstancePorts must be up to 16") }
            for port in ports {
                guard let base = port["base"] as? Int, (1024...65000).contains(base) else { fail("\(bundleID): ports go from 1024 to 65000") }
                if let plus = port["plusUserID"], !(plus is Bool) || (plus as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true {
                    fail("\(bundleID): plusUserID is true or false")
                }
            }
        }
    }
}
if data.count > 256 * 1024 { fail("keep the file under 256 KB") }
if let published = issued(arguments[2]), FileManager.default.contents(atPath: arguments[2]) != data, newIssued <= published {
    fail("raise \"issued\": it must be newer than the published file's (\(ISO8601DateFormatter().string(from: published)))")
}
print("Notices look right.")
