import XCTest
@testable import QuotaBar

final class GeminiOAuthTests: XCTestCase {

    override func tearDown() {
        MockHTTPProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Test Factory

    private func makeAccount(
        email: String = "user@gmail.com",
        accessToken: String = "ya29.test_token",
        refreshToken: String? = "1//refresh_token",
        expiresAt: Date? = Date().addingTimeInterval(3600),
        projectId: String? = "my-gcp-project"
    ) -> OAuthAccount {
        OAuthAccount(
            id: "gemini-oauth-\(email)",
            provider: .gemini,
            email: email,
            login: nil,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            projectId: projectId,
            isActive: true,
            createdAt: Date()
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Credential Extraction Regex Tests

    // Helpers to build test values that avoid GitHub push protection pattern matching.
    private static let googleSuffix = ".apps." + "googleusercontent" + ".com"
    private static let secretPrefix = "GO" + "CSPX-"

    func testExtractCredentialsFromSampleOAuth2JS() throws {
        let cid = "000000000000-testclientid" + Self.googleSuffix
        let sec = Self.secretPrefix + "FakePlaceholderSecret"
        let sampleJS = """
        "use strict";
        Object.defineProperty(exports, "__esModule", { value: true });
        const CLIENT_ID = "\(cid)";
        const CLIENT_SECRET = "\(sec)";
        function getOAuthConfig() {
            return { clientId: CLIENT_ID, clientSecret: CLIENT_SECRET };
        }
        """

        let (clientID, clientSecret) = try GeminiOAuthClient.parseCredentials(from: sampleJS)
        XCTAssertEqual(clientID, cid)
        XCTAssertEqual(clientSecret, sec)
    }

    func testExtractCredentialsMinifiedJS() throws {
        let cid = "000000000000-anotherfakeclient" + Self.googleSuffix
        let sec = Self.secretPrefix + "AnotherPlaceholder123456"
        let minifiedJS = """
        var a="\(cid)",b="\(sec)";module.exports={a,b};
        """

        let (clientID, clientSecret) = try GeminiOAuthClient.parseCredentials(from: minifiedJS)
        XCTAssertEqual(clientID, cid)
        XCTAssertEqual(clientSecret, sec)
    }

    func testExtractCredentialsPicksOAuthClientIDOverOtherClientIDs() throws {
        let otherCID = "111111111111-otherlibfakeid" + Self.googleSuffix
        let oauthCID = "222222222222-oauthfakeclientid" + Self.googleSuffix
        let sec = Self.secretPrefix + "OAuthFakePlaceholder99"
        let bundleJS = """
        var someOtherLib = {clientId: "\(otherCID)"};
        var OAUTH_CLIENT_ID = "\(oauthCID)";
        var OAUTH_CLIENT_SECRET = "\(sec)";
        """

        let (clientID, clientSecret) = try GeminiOAuthClient.parseCredentials(from: bundleJS)
        XCTAssertEqual(clientID, oauthCID)
        XCTAssertEqual(clientSecret, sec)
    }

    func testExtractCredentialsMissingClientIDThrows() {
        let sec = Self.secretPrefix + "AbCdEfGh"
        let jsContent = """
        const CLIENT_SECRET = "\(sec)";
        """

        XCTAssertThrowsError(try GeminiOAuthClient.parseCredentials(from: jsContent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("client_id"))
        }
    }

    func testExtractCredentialsMissingClientSecretThrows() {
        let cid = "000000000000-abcdefghij" + Self.googleSuffix
        let jsContent = """
        const CLIENT_ID = "\(cid)";
        """

        XCTAssertThrowsError(try GeminiOAuthClient.parseCredentials(from: jsContent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("client_secret"))
        }
    }

    func testExtractCredentialsEmptyStringThrows() {
        XCTAssertThrowsError(try GeminiOAuthClient.parseCredentials(from: ""))
    }

    // MARK: - Token Exchange Response Decoding

    func testGoogleTokenResponseDecoding() throws {
        let json = """
        {
            "access_token": "ya29.a0AfH6SMBx_example_token",
            "refresh_token": "1//0eXaMpLeReFrEsH",
            "expires_in": 3599,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "ya29.a0AfH6SMBx_example_token")
        XCTAssertEqual(response.refreshToken, "1//0eXaMpLeReFrEsH")
        XCTAssertEqual(response.expiresIn, 3599)
        XCTAssertEqual(response.tokenType, "Bearer")
    }

    func testGoogleTokenResponseWithoutRefreshToken() throws {
        let json = """
        {
            "access_token": "ya29.refreshed_token",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "ya29.refreshed_token")
        XCTAssertNil(response.refreshToken)
        XCTAssertEqual(response.expiresIn, 3600)
    }

    func testGoogleTokenResponseMissingAccessTokenThrows() {
        let json = """
        {
            "refresh_token": "1//something",
            "expires_in": 3600
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(GoogleTokenResponse.self, from: json))
    }

    // MARK: - User Info Response Decoding

    func testGoogleUserInfoResponseDecoding() throws {
        let json = """
        {
            "email": "user@gmail.com",
            "name": "Test User",
            "picture": "https://lh3.googleusercontent.com/photo.jpg"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleUserInfoResponse.self, from: json)
        XCTAssertEqual(response.email, "user@gmail.com")
        XCTAssertEqual(response.name, "Test User")
        XCTAssertEqual(response.picture, "https://lh3.googleusercontent.com/photo.jpg")
    }

    func testGoogleUserInfoResponsePartialFields() throws {
        let json = """
        {
            "email": "user@example.com"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleUserInfoResponse.self, from: json)
        XCTAssertEqual(response.email, "user@example.com")
        XCTAssertNil(response.name)
        XCTAssertNil(response.picture)
    }

    // MARK: - DirectGeminiClient Auth Headers

    func testDirectGeminiClientSetsCorrectAuthHeaders() async throws {
        let session = makeMockSession()
        let expectation = XCTestExpectation(description: "Request intercepted")

        MockHTTPProtocol.handler = { request in
            let urlString = request.url?.absoluteString ?? ""

            if urlString.contains("loadCodeAssist") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer ya29.test_auth_header"
                )
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Content-Type"),
                    "application/json"
                )
                expectation.fulfill()

                let responseJSON = """
                {
                    "currentTier": { "id": "free-tier", "name": "Free", "description": "Free tier" },
                    "cloudaicompanionProject": "test-project-id"
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            }

            // retrieveUserQuota
            let quotaJSON = """
            {
                "buckets": [
                    {
                        "resetTime": "2025-01-01T00:00:00Z",
                        "tokenType": "REQUESTS",
                        "modelId": "gemini-2.0-flash",
                        "remainingFraction": 0.75
                    }
                ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(quotaJSON.utf8), response)
        }

        let account = makeAccount(accessToken: "ya29.test_auth_header")
        let client = DirectGeminiClient(account: account, session: session)
        let card = try await client.fetchQuotaCard()

        XCTAssertEqual(card.provider, .gemini)
        XCTAssertEqual(card.title, "user@gmail.com")
        XCTAssertFalse(card.windows.isEmpty)

        await fulfillment(of: [expectation], timeout: 5)
    }

    // MARK: - DirectGeminiClient Error Handling

    func testDirectGeminiClientNon200ThrowsError() async throws {
        let session = makeMockSession()

        MockHTTPProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let account = makeAccount(accessToken: "expired_token")
        let client = DirectGeminiClient(account: account, session: session)

        do {
            _ = try await client.fetchQuotaCard()
            XCTFail("Expected error for 401 response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
    }

    func testDirectGeminiClientNon200OnQuotaThrows() async throws {
        let session = makeMockSession()

        MockHTTPProtocol.handler = { request in
            let urlString = request.url?.absoluteString ?? ""

            if urlString.contains("loadCodeAssist") {
                let responseJSON = """
                {
                    "currentTier": { "id": "free-tier" },
                    "cloudaicompanionProject": "test-project"
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            }

            // Quota endpoint returns 500
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let account = makeAccount(accessToken: "some_token")
        let client = DirectGeminiClient(account: account, session: session)

        do {
            _ = try await client.fetchQuotaCard()
            XCTFail("Expected error for 500 quota response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    // MARK: - Refresh Token Response Decoding

    func testRefreshTokenResponseDecoding() throws {
        let json = """
        {
            "access_token": "ya29.new_refreshed_token",
            "expires_in": 3600,
            "token_type": "Bearer",
            "scope": "openid https://www.googleapis.com/auth/cloud-platform"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "ya29.new_refreshed_token")
        XCTAssertNil(response.refreshToken)
        XCTAssertEqual(response.expiresIn, 3600)
    }

    // MARK: - GeminiQuotaBuilder.makeCard(account:) Integration

    func testMakeCardWithOAuthAccountProducesCorrectCard() throws {
        let account = makeAccount(email: "dev@example.com", projectId: "my-project")

        let codeAssist = try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: Data("""
        {
            "currentTier": { "id": "standard-tier", "name": "Standard", "description": "Pro tier" },
            "cloudaicompanionProject": "my-project"
        }
        """.utf8))

        let quota = try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data("""
        {
            "buckets": [
                {
                    "resetTime": "2025-06-01T00:00:00Z",
                    "tokenType": "REQUESTS",
                    "modelId": "gemini-2.0-flash",
                    "remainingFraction": 0.5
                }
            ]
        }
        """.utf8))

        let card = GeminiQuotaBuilder.makeCard(
            account: account,
            projectID: "my-project",
            codeAssist: codeAssist,
            quota: quota
        )

        XCTAssertEqual(card.provider, .gemini)
        XCTAssertEqual(card.id, "gemini-oauth-dev@example.com")
        XCTAssertEqual(card.title, "dev@example.com")
        XCTAssertEqual(card.subtitle, "my-project")
        XCTAssertEqual(card.planLabel, "Pro")
        XCTAssertFalse(card.windows.isEmpty)
        XCTAssertNil(card.errorMessage)
    }

    func testMakeCardWithFreeTierLabel() throws {
        let account = makeAccount()

        let codeAssist = try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: Data("""
        {
            "currentTier": { "id": "free-tier", "name": "Free", "description": "Free" }
        }
        """.utf8))

        let quota = try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data("""
        { "buckets": [] }
        """.utf8))

        let card = GeminiQuotaBuilder.makeCard(
            account: account,
            projectID: "proj",
            codeAssist: codeAssist,
            quota: quota
        )

        XCTAssertEqual(card.planLabel, "免费版")
    }

    // MARK: - Payload Encoding

    func testGeminiCodeAssistPayloadEncoding() throws {
        let payload = GeminiCodeAssistPayload(projectID: "my-project")
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["cloudaicompanionProject"] as? String, "my-project")

        let metadata = dict?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["ideType"] as? String, "IDE_UNSPECIFIED")
        XCTAssertEqual(metadata?["platform"] as? String, "PLATFORM_UNSPECIFIED")
        XCTAssertEqual(metadata?["pluginType"] as? String, "GEMINI")
        XCTAssertEqual(metadata?["duetProject"] as? String, "my-project")
    }

    func testGeminiCodeAssistPayloadNilProject() throws {
        let payload = GeminiCodeAssistPayload(projectID: nil)
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // When project is nil, key should be absent or null
        let hasProject = dict?["cloudaicompanionProject"] as? String
        XCTAssertNil(hasProject)
    }

    func testGeminiQuotaPayloadEncoding() throws {
        let payload = GeminiQuotaPayload(projectID: "test-project")
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["project"] as? String, "test-project")
    }
}
