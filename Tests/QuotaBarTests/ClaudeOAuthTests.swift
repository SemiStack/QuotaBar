import XCTest
@testable import QuotaBar

final class ClaudeOAuthTests: XCTestCase {
    func testPKCEGeneration() {
        let pkce = ClaudeOAuthClient.generatePKCE()
        // Verifier should be base64url, 43 chars (32 bytes → 43 base64url chars)
        XCTAssertGreaterThanOrEqual(pkce.codeVerifier.count, 40)
        XCTAssertFalse(pkce.codeVerifier.contains("+"))
        XCTAssertFalse(pkce.codeVerifier.contains("/"))
        XCTAssertFalse(pkce.codeVerifier.contains("="))

        // Challenge should also be base64url
        XCTAssertGreaterThanOrEqual(pkce.codeChallenge.count, 40)
        XCTAssertFalse(pkce.codeChallenge.contains("+"))
        XCTAssertFalse(pkce.codeChallenge.contains("/"))
        XCTAssertFalse(pkce.codeChallenge.contains("="))

        // Two generations should produce different values
        let pkce2 = ClaudeOAuthClient.generatePKCE()
        XCTAssertNotEqual(pkce.codeVerifier, pkce2.codeVerifier)
    }

    func testBuildAuthorizeURL() {
        let client = ClaudeOAuthClient()
        let pkce = ClaudeOAuthClient.PKCEPair(codeVerifier: "test-verifier", codeChallenge: "test-challenge")
        let url = client.buildAuthorizeURL(port: 12345, pkce: pkce, state: "test-state")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")

        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["client_id"], ClaudeOAuthClient.clientID)
        XCTAssertEqual(params["redirect_uri"], "http://localhost:12345/callback")
        XCTAssertEqual(params["code_challenge"], "test-challenge")
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertTrue(params["scope"]?.contains("user:profile") ?? false)
        XCTAssertTrue(params["scope"]?.contains("user:inference") ?? false)
        XCTAssertTrue(params["scope"]?.contains("user:sessions:claude_code") ?? false)
        XCTAssertFalse(params["scope"]?.contains("org:read_billing") ?? true)
    }

    func testClientID() {
        // Client ID should match Claude Code's production client ID
        XCTAssertEqual(ClaudeOAuthClient.clientID, "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    func testGenerateStateIsStrongEnough() {
        let state = ClaudeOAuthClient.generateState()
        // 32 bytes → base64url → 43 chars
        XCTAssertGreaterThanOrEqual(state.count, 43, "State must be ≥43 chars")
        XCTAssertFalse(state.contains("+"))
        XCTAssertFalse(state.contains("/"))
        XCTAssertFalse(state.contains("="))
        let state2 = ClaudeOAuthClient.generateState()
        XCTAssertNotEqual(state, state2)
    }
}
