import XCTest
@testable import ParallexCore

/// Firefox and Thunderbird bring their own allocator (mozglue's), which sets
/// itself up on its first allocation. Their crashhelper forks before
/// allocating anything; in a copy, the system's own fork-child steps then
/// allocated first and the child aborted. A stand-in allocator and helper
/// show the copy's helper forks as the original's does.
final class HelperForkTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("fork")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A malloc zone made the default as its library loads, which registers
    /// fork handlers on its first allocation (as mozglue's does).
    private let allocator = """
    #include <malloc/malloc.h>
    #include <pthread.h>
    #include <stdbool.h>
    static malloc_zone_t zone, *system_zone;
    static struct malloc_introspection_t introspect;
    static bool ready;
    static void nothing(void) {}
    static void set_up(void) { if (!ready) { ready = true; pthread_atfork(nothing, nothing, nothing); } }
    static size_t z_size(malloc_zone_t *z, const void *p) { return system_zone->size(system_zone, p); }
    static void *z_malloc(malloc_zone_t *z, size_t n) { set_up(); return system_zone->malloc(system_zone, n); }
    static void *z_calloc(malloc_zone_t *z, size_t c, size_t n) { set_up(); return system_zone->calloc(system_zone, c, n); }
    static void *z_valloc(malloc_zone_t *z, size_t n) { set_up(); return system_zone->valloc(system_zone, n); }
    static void *z_realloc(malloc_zone_t *z, void *p, size_t n) { set_up(); return system_zone->realloc(system_zone, p, n); }
    static void *z_memalign(malloc_zone_t *z, size_t a, size_t n) { set_up(); return system_zone->memalign(system_zone, a, n); }
    static void z_free(malloc_zone_t *z, void *p) { system_zone->free(system_zone, p); }
    static void z_free_size(malloc_zone_t *z, void *p, size_t n) { system_zone->free(system_zone, p); }
    static unsigned z_batch_malloc(malloc_zone_t *z, size_t n, void **r, unsigned c) {
        set_up();
        for (unsigned i = 0; i < c; i++) { if (!(r[i] = system_zone->malloc(system_zone, n))) return i; }
        return c;
    }
    static void z_batch_free(malloc_zone_t *z, void **r, unsigned c) { for (unsigned i = 0; i < c; i++) system_zone->free(system_zone, r[i]); }
    static size_t z_relief(malloc_zone_t *z, size_t g) { return 0; }
    static void z_destroy(malloc_zone_t *z) {}
    static void z_lock(malloc_zone_t *z) {}
    static size_t z_good(malloc_zone_t *z, size_t n) { return n; }
    static boolean_t z_check(malloc_zone_t *z) { return 1; }
    static void z_print(malloc_zone_t *z, boolean_t v) {}
    static void z_log(malloc_zone_t *z, void *a) {}
    static void z_stats(malloc_zone_t *z, malloc_statistics_t *s) {}
    static boolean_t z_locked(malloc_zone_t *z) { return 0; }
    static kern_return_t z_enum(task_t t, void *c, unsigned m, vm_address_t a, memory_reader_t r, vm_range_recorder_t rr) { return 0; }
    static malloc_zone_t *first_zone(void) {
        malloc_zone_t **zones = NULL; unsigned count = 0;
        if (malloc_get_all_zones(0, NULL, (vm_address_t **)&zones, &count) == KERN_SUCCESS && count) return zones[0];
        return malloc_default_zone();
    }
    __attribute__((constructor)) static void register_zone(void) {
        system_zone = first_zone();
        zone.size = z_size; zone.malloc = z_malloc; zone.calloc = z_calloc; zone.valloc = z_valloc;
        zone.free = z_free; zone.realloc = z_realloc; zone.destroy = z_destroy; zone.zone_name = "stand-in";
        zone.batch_malloc = z_batch_malloc; zone.batch_free = z_batch_free; zone.memalign = z_memalign;
        zone.free_definite_size = z_free_size; zone.pressure_relief = z_relief;
        zone.version = 9; zone.introspect = &introspect;
        introspect.enumerator = z_enum; introspect.good_size = z_good; introspect.check = z_check;
        introspect.print = z_print; introspect.log = z_log; introspect.force_lock = z_lock;
        introspect.force_unlock = z_lock; introspect.reinit_lock = z_lock;
        introspect.statistics = z_stats; introspect.zone_locked = z_locked;
        malloc_zone_t *purgeable = malloc_default_purgeable_zone();
        malloc_zone_register(&zone);
        malloc_zone_t *current = system_zone;
        do {
            malloc_zone_unregister(current); malloc_zone_register(current);
            malloc_zone_unregister(purgeable); malloc_zone_register(purgeable);
            current = first_zone();
        } while (current != &zone);
    }
    """

    /// Forks before allocating anything, and says how its child ended.
    private let helper = """
    #include <stdio.h>
    #include <sys/wait.h>
    #include <unistd.h>
    int main(void) {
        pid_t child = fork();
        if (child == 0) _exit(7);
        int status = 0;
        waitpid(child, &status, 0);
        printf("%s %d", WIFEXITED(status) ? "exited" : "signal", WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status));
        return 0;
    }
    """

    func testAHelperThatForksFirstStillForksInACopy() throws {
        let app = tempDir.appendingPathComponent("Forky.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let allocatorSource = tempDir.appendingPathComponent("allocator.c")
        let helperSource = tempDir.appendingPathComponent("helper.c")
        try Data(allocator.utf8).write(to: allocatorSource)
        try Data(helper.utf8).write(to: helperSource)
        let library = macOS.appendingPathComponent("liballocator.dylib")
        let executable = macOS.appendingPathComponent("helper")
        try Shell.run("/usr/bin/clang", ["-dynamiclib", allocatorSource.path, "-o", library.path,
                                         "-install_name", "@executable_path/liballocator.dylib"])
        // Like the real one, it links a system framework after its allocator.
        try Shell.run("/usr/bin/clang", [helperSource.path, library.path, "-framework", "CoreFoundation", "-o", executable.path])

        func run(inCopy: Bool) throws -> String {
            let process = Process()
            process.executableURL = executable
            var environment = ProcessInfo.processInfo.environment
            if inCopy {
                environment["DYLD_INSERT_LIBRARIES"] = Fixtures.homeLibrary.path
                environment["PARALLEX_HOME_REDIRECT"] = tempDir.appendingPathComponent("home").path
                environment["PARALLEX_HOME_SCOPE"] = app.path
            }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return printed
        }
        XCTAssertEqual(try run(inCopy: false), "exited 7", "the original")
        XCTAssertEqual(try run(inCopy: true), "exited 7", "the copy")
    }
}
