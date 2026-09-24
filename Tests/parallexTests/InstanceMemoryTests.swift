import XCTest
@testable import ParallexCore

final class InstanceMemoryTests: XCTestCase {
    /// An instance's memory is its process plus what it started.
    func testCountsAProcessAndItsChildren() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        let me = InstanceMemory.footprint(of: getpid())
        let sleeper = InstanceMemory.footprint(of: child.processIdentifier)
        XCTAssertGreaterThan(me, 1_000_000)
        XCTAssertGreaterThan(sleeper, 0)

        let measured = InstanceMemory.measure([InstanceMemory.Target(slug: "me", pid: getpid(), bundlePath: nil)])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(measured["me"]), me + sleeper - 2_000_000)
        XCTAssertEqual(InstanceMemory.measure([]), [:])
    }
}
