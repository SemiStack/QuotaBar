import XCTest
@testable import QuotaBar

final class OAuthCallbackServerTests: XCTestCase {

    // MARK: - testStartReturnsValidPort

    func testStartReturnsValidPort() async throws {
        let server = OAuthCallbackServer(timeout: 30)
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThanOrEqual(port, 65535)
        await server.stop()
    }

    // MARK: - testReceivesAuthorizationCode

    func testReceivesAuthorizationCode() async throws {
        let server = OAuthCallbackServer(timeout: 10)
        let port = try await server.start()

        let codeTask = Task { try await server.waitForCode() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?code=test_code_123&state=xyz")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)

        let code = try await codeTask.value
        XCTAssertEqual(code, "test_code_123")
    }

    // MARK: - testHandlesErrorResponse

    func testHandlesErrorResponse() async throws {
        let server = OAuthCallbackServer(timeout: 10)
        let port = try await server.start()

        let codeTask = Task { try await server.waitForCode() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?error=access_denied")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 400)

        do {
            _ = try await codeTask.value
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("access_denied"),
                          "Expected error about access_denied, got: \(error.localizedDescription)")
        }
    }

    // MARK: - testMissingCodeThrows

    func testMissingCodeThrows() async throws {
        let server = OAuthCallbackServer(timeout: 10)
        let port = try await server.start()

        let codeTask = Task { try await server.waitForCode() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?state=abc")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 400)

        do {
            _ = try await codeTask.value
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OAuth 回调缺少授权码"),
                          "Expected missing code error, got: \(error.localizedDescription)")
        }
    }

    func testWaitForCodeRejectsMismatchedState() async throws {
        let server = OAuthCallbackServer(timeout: 10)
        let port = try await server.start()

        let codeTask = Task { try await server.waitForCode(expectedState: "expected-state") }
        try await Task.sleep(nanoseconds: 100_000_000)

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?code=test_code_123&state=wrong-state")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)

        do {
            _ = try await codeTask.value
            XCTFail("Expected state mismatch error to be thrown")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("state"),
                "Expected state mismatch error, got: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - testStopCleansUp

    func testStopCleansUp() async throws {
        let server = OAuthCallbackServer(timeout: 30)
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        await server.stop()
        // Calling stop again should be safe (idempotent)
        await server.stop()
    }

    // MARK: - testTimeoutThrows

    func testTimeoutThrows() async throws {
        let server = OAuthCallbackServer(timeout: 0.5)
        _ = try await server.start()

        do {
            _ = try await server.waitForCode()
            XCTFail("Expected timeout error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OAuth 回调超时"),
                          "Expected timeout error, got: \(error.localizedDescription)")
        }
    }

    // MARK: - testCodeArrivesBeforeWaitForCode

    func testCodeArrivesBeforeWaitForCode() async throws {
        let server = OAuthCallbackServer(timeout: 10)
        let port = try await server.start()

        // Send callback before calling waitForCode
        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?code=buffered_code_456&state=buffered-state")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)

        // Small delay to ensure the code is delivered
        try await Task.sleep(nanoseconds: 100_000_000)

        // Now call waitForCode - should get the buffered result
        let code = try await server.waitForCode()
        XCTAssertEqual(code, "buffered_code_456")
    }

    // MARK: - testParseRequestWithCode

    func testParseRequestWithCode() {
        let request = "GET /oauth2callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)

        if case .code(let response) = result {
            XCTAssertEqual(response.code, "abc123")
            XCTAssertEqual(response.state, "xyz")
        } else {
            XCTFail("Expected code result, got: \(result)")
        }
    }

    // MARK: - testParseRequestWithoutStateReturnsOAuthError

    func testParseRequestWithoutStateReturnsOAuthError() {
        let request = "GET /oauth2callback?code=abc123 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)

        switch result {
        case .oauthError(let error):
            XCTAssertTrue(
                error.localizedDescription.contains("state"),
                "Expected missing state error, got: \(error.localizedDescription)"
            )
        default:
            XCTFail("Expected .oauthError for missing state, got \(result)")
        }
    }

    // MARK: - testParseRequestNotCallback

    func testParseRequestNotCallback() {
        let request = "GET /some/other/path HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)

        if case .notCallback = result {
            // Success
        } else {
            XCTFail("Expected notCallback result, got: \(result)")
        }
    }

    // MARK: - testParseCallbackPath

    func testParseCallbackPath() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)
        switch result {
        case .code(let response):
            XCTAssertEqual(response.code, "abc123")
            XCTAssertEqual(response.state, "xyz")
        default:
            XCTFail("Expected .code, got \(result)")
        }
    }

    // MARK: - testParseCallbackPathWithError

    func testParseCallbackPathWithError() {
        let request = "GET /callback?error=access_denied&error_description=User%20denied HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)
        switch result {
        case .oauthError:
            break // expected
        default:
            XCTFail("Expected .oauthError, got \(result)")
        }
    }

    // MARK: - testParseAuthCallbackPath (Codex)

    func testParseAuthCallbackPath() {
        let request = "GET /auth/callback?code=codex_auth_code&state=test HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = OAuthCallbackServer.parseRequest(request)
        switch result {
        case .code(let response):
            XCTAssertEqual(response.code, "codex_auth_code")
            XCTAssertEqual(response.state, "test")
        default:
            XCTFail("Expected .code, got \(result)")
        }
    }
}
