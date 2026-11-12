import Foundation
import Testing
@testable import LucidSQL

@Suite("Swift-Rust UniFFI Bridge Validation Tests")
struct BridgeValidationTests {
    @Test("Verify synchronous bridge_ping returns expected string")
    func testBridgePing() {
        let result = bridge_ping()
        #expect(result == "pong from rust")
    }

    @Test("Verify async operation executes and returns formatted delay")
    func testAsyncOperation() async throws {
        let startTime = Date()
        let result = try await async_test_operation(delayMs: 50)
        let elapsed = Date().timeIntervalSince(startTime)
        #expect(result == "completed after 50ms")
        #expect(elapsed >= 0.04)
    }

    @Test("Verify typed error mapping for authentication failure")
    func testAuthenticationError() {
        #expect(throws: LucidError.self) {
            try trigger_test_error(errorType: "auth")
        }

        do {
            try trigger_test_error(errorType: "auth")
            Issue.record("Expected AuthenticationFailed error but none was thrown")
        } catch let LucidError.AuthenticationFailed(message) {
            #expect(message == "invalid credentials")
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test("Verify typed error mapping for query timeout")
    func testTimeoutError() {
        do {
            try trigger_test_error(errorType: "timeout")
            Issue.record("Expected QueryTimedOut error")
        } catch let LucidError.QueryTimedOut(durationMs) {
            #expect(durationMs == 5000)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Verify typed error mapping for read-only violation")
    func testReadOnlyViolationError() {
        do {
            try trigger_test_error(errorType: "readonly")
            Issue.record("Expected ReadOnlyViolation error")
        } catch let LucidError.ReadOnlyViolation(attemptedOperation) {
            #expect(attemptedOperation == "DROP TABLE")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Verify typed error mapping for database syntax error")
    func testDatabaseError() {
        do {
            try trigger_test_error(errorType: "other")
            Issue.record("Expected DatabaseError error")
        } catch let LucidError.DatabaseError(code, message, detail) {
            #expect(code == "42601")
            #expect(message == "syntax error")
            #expect(detail == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Verify concurrent async calls execute non-blockingly")
    func testConcurrentAsyncCalls() async throws {
        async let first = async_test_operation(delayMs: 30)
        async let second = async_test_operation(delayMs: 30)
        async let third = async_test_operation(delayMs: 30)

        let results = try await [first, second, third]
        #expect(results.count == 3)
        for r in results {
            #expect(r == "completed after 30ms")
        }
    }
}
