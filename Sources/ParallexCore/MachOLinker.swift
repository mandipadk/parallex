import Foundation

/// Adds a library to a Mach-O binary's load commands (a weak one: the
/// binary still runs if the library is missing), so the binary loads it on
/// its own instead of through `DYLD_INSERT_LIBRARIES`. The new command goes
/// in the free space after the existing ones, which linkers leave for this;
/// a slice without room is left alone. The binary must be re-signed after.
enum MachOLinker {
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let loadDylib: UInt32 = 0x0c
    static let segment64: UInt32 = 0x19

    enum Architecture: String, Sendable {
        case arm64, x86_64, other
    }

    /// Add `installName` to every 64-bit slice of `binary` with room for it.
    /// Returns the architectures that now load it (including any that
    /// already did).
    @discardableResult
    static func addWeakLibrary(_ installName: String, to binary: URL) throws -> Set<Architecture> {
        var data = try Data(contentsOf: binary)
        var linked = Set<Architecture>()
        var changed = false
        for slice in slices(of: data) {
            switch addWeakLibrary(installName, to: &data, sliceAt: slice) {
            case .added(let architecture):
                linked.insert(architecture)
                changed = true
            case .alreadyThere(let architecture):
                linked.insert(architecture)
            case .noRoom, .unsupported:
                break
            }
        }
        if changed {
            try data.write(to: binary)
        }
        return linked
    }

    /// Where each architecture's image starts (one, at 0, for a thin binary).
    static func slices(of data: Data) -> [Int] {
        guard data.count >= 8 else { return [] }
        let magic = data.readUInt32(at: 0, bigEndian: true)
        guard magic == 0xCAFE_BABE else { return [0] }
        // (Java class files share the magic; a real one has a few slices.)
        let count = Int(data.readUInt32(at: 4, bigEndian: true))
        guard count <= 32 else { return [] }
        return (0..<count).compactMap { index in
            let entry = 8 + index * 20
            guard entry + 20 <= data.count else { return nil }
            return Int(data.readUInt32(at: entry + 8, bigEndian: true))
        }
    }

    enum Outcome {
        case added(Architecture), alreadyThere(Architecture), noRoom, unsupported
    }

    static func addWeakLibrary(_ installName: String, to data: inout Data, sliceAt offset: Int) -> Outcome {
        guard offset + 32 <= data.count, data.readUInt32(at: offset) == 0xFEED_FACF else { return .unsupported }
        let cpuType = data.readUInt32(at: offset + 4)
        let architecture: Architecture = cpuType == 0x0100_000C ? .arm64 : cpuType == 0x0100_0007 ? .x86_64 : .other
        let commandCount = Int(data.readUInt32(at: offset + 16))
        let commandsSize = Int(data.readUInt32(at: offset + 20))
        let commandsEnd = offset + 32 + commandsSize
        guard commandsEnd <= data.count else { return .unsupported }
        let name = Array(installName.utf8) + [0]
        let size = (24 + name.count + 7) / 8 * 8

        // Existing commands: is it there already, and where does the first
        // section's content begin (the end of the room for commands)?
        var position = offset + 32
        var firstContent: Int?
        for _ in 0..<commandCount {
            guard position + 8 <= commandsEnd else { return .unsupported }
            let command = data.readUInt32(at: position)
            let commandSize = Int(data.readUInt32(at: position + 4))
            guard commandSize >= 8, position + commandSize <= commandsEnd else { return .unsupported }
            if command == loadWeakDylib || command == loadDylib {
                let nameOffset = Int(data.readUInt32(at: position + 8))
                guard nameOffset < commandSize else { return .unsupported }
                let start = position + nameOffset
                let end = min(position + commandSize, data.count)
                if start < end, data[start..<end].prefix(while: { $0 != 0 }).elementsEqual(installName.utf8) {
                    return .alreadyThere(architecture)
                }
            }
            if command == segment64 {
                guard commandSize >= 72 else { return .unsupported }
                let sections = Int(data.readUInt32(at: position + 64))
                guard 72 + sections * 80 <= commandSize else { return .unsupported }
                for index in 0..<sections {
                    let sectionOffset = Int(data.readUInt32(at: position + 72 + index * 80 + 48))
                    if sectionOffset > 0, firstContent.map({ sectionOffset < $0 }) ?? true {
                        firstContent = sectionOffset
                    }
                }
            }
            position += commandSize
        }
        guard let firstContent else { return .unsupported }
        let end = commandsEnd
        guard offset + firstContent - end >= size, end + size <= data.count else { return .noRoom }
        guard data[end..<(end + size)].allSatisfy({ $0 == 0 }) else { return .noRoom }

        var command = Data()
        command.appendUInt32(loadWeakDylib)
        command.appendUInt32(UInt32(size))
        command.appendUInt32(24)          // the name follows the fixed part
        command.appendUInt32(2)           // timestamp
        command.appendUInt32(0x0001_0000) // current version 1.0.0
        command.appendUInt32(0x0001_0000) // compatibility version 1.0.0
        command.append(contentsOf: name)
        command.append(contentsOf: [UInt8](repeating: 0, count: size - command.count))
        data.replaceSubrange(end..<(end + size), with: command)
        data.writeUInt32(UInt32(commandCount + 1), at: offset + 16)
        data.writeUInt32(UInt32(commandsSize + size), at: offset + 20)
        return .added(architecture)
    }

    /// The architecture this Mac runs `binary` as: arm64 on Apple silicon
    /// when it has that slice, otherwise x86_64.
    static func runningArchitecture(of binary: URL) -> Architecture? {
        guard let data = try? Data(contentsOf: binary, options: .alwaysMapped) else { return nil }
        let architectures = slices(of: data).compactMap { offset -> Architecture? in
            guard offset + 8 <= data.count, data.readUInt32(at: offset) == 0xFEED_FACF else { return nil }
            let cpuType = data.readUInt32(at: offset + 4)
            return cpuType == 0x0100_000C ? .arm64 : cpuType == 0x0100_0007 ? .x86_64 : .other
        }
        #if arch(arm64)
        return architectures.contains(.arm64) ? .arm64 : architectures.first
        #else
        return architectures.contains(.x86_64) ? .x86_64 : nil
        #endif
    }
}

private extension Data {
    /// 0 past the end (callers check what they read against the size).
    func readUInt32(at offset: Int, bigEndian: Bool = false) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let value = self[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
