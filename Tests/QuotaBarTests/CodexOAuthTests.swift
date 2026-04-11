import XCTest
@testable import QuotaBar

final class CodexOAuthTests: XCTestCase {
    // Test JWT account ID extraction with a crafted JWT
    func testExtractChatGPTAccountId() {
        // Create a JWT with payload: {"https://api.openai.com/auth": {"chatgpt_account_id": "acc_test123"}}
        let payload: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "acc_test123"]]
        let token = makeJWT(payload: payload)
        XCTAssertEqual(CodexOAuthClient.extractChatGPTAccountId(from: token), "acc_test123")
    }

    func testExtractChatGPTAccountIdMissing() {
        let payload: [String: Any] = ["sub": "user123"]
        let token = makeJWT(payload: payload)
        XCTAssertNil(CodexOAuthClient.extractChatGPTAccountId(from: token))
    }

    func testExtractEmail() {
        let payload: [String: Any] = ["email": "test@openai.com"]
        let token = makeJWT(payload: payload)
        XCTAssertEqual(CodexOAuthClient.extractEmail(from: token), "test@openai.com")
    }

    func testExtractEmailMissing() {
        let payload: [String: Any] = ["sub": "user123"]
        let token = makeJWT(payload: payload)
        XCTAssertNil(CodexOAuthClient.extractEmail(from: token))
    }

    func testInvalidJWT() {
        XCTAssertNil(CodexOAuthClient.extractChatGPTAccountId(from: "not-a-jwt"))
        XCTAssertNil(CodexOAuthClient.extractEmail(from: ""))
    }

    func testPKCEGeneration() {
        let pkce = CodexOAuthClient.generatePKCE()
        // Code verifier should be a non-empty base64url string
        XCTAssertFalse(pkce.codeVerifier.isEmpty)
        XCTAssertFalse(pkce.codeVerifier.contains("+"))
        XCTAssertFalse(pkce.codeVerifier.contains("/"))
        XCTAssertFalse(pkce.codeVerifier.contains("="))
        // Code challenge should also be non-empty base64url string
        XCTAssertFalse(pkce.codeChallenge.isEmpty)
        XCTAssertFalse(pkce.codeChallenge.contains("+"))
        XCTAssertFalse(pkce.codeChallenge.contains("/"))
        XCTAssertFalse(pkce.codeChallenge.contains("="))
        // They should be different (verifier != challenge)
        XCTAssertNotEqual(pkce.codeVerifier, pkce.codeChallenge)
    }

    func testAuthorizeURLContainsRequiredParams() {
        let client = CodexOAuthClient()
        let pkce = CodexOAuthClient.generatePKCE()
        let url = client.buildAuthorizeURL(port: 12345, pkce: pkce, state: "test-state")
        let urlString = url.absoluteString
        XCTAssertTrue(urlString.contains("auth.openai.com/oauth/authorize"))
        XCTAssertTrue(urlString.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        XCTAssertTrue(urlString.contains("response_type=code"))
        XCTAssertTrue(urlString.contains("code_challenge_method=S256"))
        XCTAssertTrue(urlString.contains("state=test-state"))
        XCTAssertTrue(urlString.contains("localhost"))
        XCTAssertTrue(urlString.contains("12345"))
        XCTAssertTrue(urlString.contains("codex_cli_simplified_flow=true"))
    }

    func testGenerateStateIsStrongEnough() {
        let state = CodexOAuthClient.generateState()
        // 32 bytes → base64url → 43 chars (matches official CLI)
        XCTAssertGreaterThanOrEqual(state.count, 43, "State must be ≥43 chars to pass OpenAI validation")
        // Must be base64url safe
        XCTAssertFalse(state.contains("+"))
        XCTAssertFalse(state.contains("/"))
        XCTAssertFalse(state.contains("="))
        // Different each time
        let state2 = CodexOAuthClient.generateState()
        XCTAssertNotEqual(state, state2)
    }

    // Helper: create a minimal JWT (header.payload.signature) with given payload
    private func makeJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payloadB64).fake-signature"
    }
}
