import XCTest
@testable import ParallexCore

final class KeyShortcutTests: XCTestCase {
    func testParsesWordModifiers() throws {
        let shortcut = try XCTUnwrap(KeyShortcut(parsing: "ctrl+opt+1"))
        XCTAssertEqual(shortcut.keyCode, 0x12)
        XCTAssertEqual(shortcut.modifiers, [.control, .option])
        XCTAssertEqual(shortcut.displayString, "⌃⌥1")
    }

    func testParsesSymbolsAndIsCaseInsensitive() throws {
        let symbols = try XCTUnwrap(KeyShortcut(parsing: "⌘⇧K"))
        XCTAssertEqual(symbols.modifiers, [.command, .shift])
        XCTAssertEqual(symbols.displayString, "⇧⌘K")
        let words = try XCTUnwrap(KeyShortcut(parsing: "Cmd + Shift + k"))
        XCTAssertTrue(words.sameKeys(as: symbols))
    }

    func testFunctionAndNamedKeys() throws {
        let f5 = try XCTUnwrap(KeyShortcut(parsing: "f5"))
        XCTAssertEqual(f5.displayString, "F5")
        XCTAssertTrue(f5.isValidGlobal, "function keys don't need a modifier")
        let space = try XCTUnwrap(KeyShortcut(parsing: "ctrl+option+space"))
        XCTAssertEqual(space.displayString, "⌃⌥Space")
        let plus = try XCTUnwrap(KeyShortcut(parsing: "cmd++"))
        XCTAssertEqual(plus.keyCode, 0x18)
    }

    func testRejectsNonsense() {
        XCTAssertNil(KeyShortcut(parsing: ""))
        XCTAssertNil(KeyShortcut(parsing: "ctrl+"))
        XCTAssertNil(KeyShortcut(parsing: "hyper+k"))
        XCTAssertNil(KeyShortcut(parsing: "ctrl+banana"))
    }

    func testGlobalShortcutsNeedAChord() throws {
        XCTAssertFalse(try XCTUnwrap(KeyShortcut(parsing: "k")).isValidGlobal)
        XCTAssertFalse(try XCTUnwrap(KeyShortcut(parsing: "shift+k")).isValidGlobal)
        XCTAssertTrue(try XCTUnwrap(KeyShortcut(parsing: "opt+k")).isValidGlobal)
        XCTAssertFalse(try XCTUnwrap(KeyShortcut(parsing: "cmd+c")).isValidGlobal, "⌘ chords belong to apps")
        XCTAssertFalse(try XCTUnwrap(KeyShortcut(parsing: "cmd+shift+n")).isValidGlobal)
        XCTAssertTrue(try XCTUnwrap(KeyShortcut(parsing: "cmd+opt+n")).isValidGlobal)
    }

    func testShortcutIsBookkeepingOnly() throws {
        let before = InstanceSettings()
        var after = before
        after.shortcut = KeyShortcut(parsing: "ctrl+opt+1")
        XCTAssertFalse(before.requiresRebuild(toReach: after), "a shortcut never rebuilds the instance")
    }

    func testSettingsRoundTripWithShortcut() throws {
        var settings = InstanceSettings()
        settings.shortcut = KeyShortcut(parsing: "ctrl+opt+w")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InstanceSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        // Settings written before shortcuts existed still decode.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["shortcut"] = nil
        let old = try JSONDecoder().decode(InstanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.shortcut)
    }
}
