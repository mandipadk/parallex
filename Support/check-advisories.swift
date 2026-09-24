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
}
for message in object["messages"] as? [[String: Any]] ?? [] {
    guard message["id"] is String, message["title"] is String, message["body"] is String else { fail("each message needs id, title and body") }
    if let range = message["parallex"] as? String, !isValidRange(range) { fail("bad parallex range: \(range)") }
    if let link = message["link"] as? String, !link.hasPrefix("https://") { fail("links must be https: \(link)") }
}
if data.count > 256 * 1024 { fail("keep the file under 256 KB") }
if let published = issued(arguments[2]), FileManager.default.contents(atPath: arguments[2]) != data, newIssued <= published {
    fail("raise \"issued\": it must be newer than the published file's (\(ISO8601DateFormatter().string(from: published)))")
}
print("Notices look right.")
