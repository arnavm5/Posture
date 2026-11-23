import Foundation

/// Minimal test harness (SwiftPM/XCTest aren't required — runs with just the Command Line Tools).
enum T {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed: [String] = []
    nonisolated(unsafe) static var current = ""
}

func test(_ name: String, _ body: () throws -> Void) {
    T.current = name
    let before = T.failed.count
    do { try body() } catch { T.failed.append("\(name): threw \(error)") }
    if T.failed.count == before { T.passed += 1; print("  ✓ \(name)") } else { print("  ✗ \(name)") }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    if !condition { T.failed.append("\(T.current) (line \(line)): \(message())") }
}

func expectNear(_ value: Double, _ target: Double, tolerance: Double, _ what: String = "", line: Int = #line) {
    expect(abs(value - target) <= tolerance,
           String(format: "%@ expected %.3f ± %.3f, got %.3f", what, target, tolerance, value), line: line)
}

func finish() -> Never {
    print("\n\(T.passed) passed, \(T.failed.count) failed")
    for f in T.failed { print("  FAIL \(f)") }
    exit(T.failed.isEmpty ? 0 : 1)
}
