// Signs release archives so the in-app updater can verify them.
//
//   swift Support/release-key.swift generate      # once: create the key pair
//   swift Support/release-key.swift public        # print the public key
//   swift Support/release-key.swift sign <file>   # print a signature
//
// The private key lives only in the login keychain (service "Parallex
// Release Signing"). The public key is compiled into the app
// (UpdateSignature.publicKey), which rejects any archive not signed with it.

import CryptoKit
import Foundation

let service = "Parallex Release Signing"
let account = "parallex"

func security(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard found.status == 0, let raw = Data(base64Encoded: found.output),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("No signing key in the keychain. Run: swift Support/release-key.swift generate\n".utf8))
        exit(1)
    }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
    if security(["find-generic-password", "-s", service, "-a", account]).status == 0 {
        FileHandle.standardError.write(Data("A signing key already exists; refusing to replace it.\n".utf8))
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    // `security -i` reads the command from stdin, so the key never appears
    // in a process's arguments (which other processes can see).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["-i"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    let command = "add-generic-password -s \"\(service)\" -a \(account) -w \(key.rawRepresentation.base64EncodedString())\n"
    input.fileHandleForWriting.write(Data(command.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    guard security(["find-generic-password", "-s", service, "-a", account]).status == 0 else {
        FileHandle.standardError.write(Data("Couldn't store the key in the keychain.\n".utf8))
        exit(1)
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = arguments.dropFirst().first, let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("Usage: release-key.swift sign <file>\n".utf8))
        exit(1)
    }
    print(try loadKey().signature(for: data).base64EncodedString())
default:
    FileHandle.standardError.write(Data("Usage: release-key.swift generate | public | sign <file>\n".utf8))
    exit(1)
}
