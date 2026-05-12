import XCTest
@testable import QuotaBar

final class CopilotOAuthTests: XCTestCase {

    override func tearDown() {
        MockHTTPProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Test Factory

    private func makeAccount(
        login: String = "testuser",
        accessToken: String = "gho_test_token",
        provider: QuotaProvider = .copilot
    ) -> OAuthAccount {
        OAuthAccount(
            id: "copilot-oauth-\(login)",
            provider: provider,
            email: nil,
            login: login,
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: nil,
            projectId: nil,
            isActive: true,
            createdAt: Date()
        )
    }

    // MARK: - DeviceCodeResponse Decoding

    func testDeviceCodeResponseDecoding() throws {
        let json = """
        {
            "device_code": "abc123def456",
            "user_code": "ABCD-1234",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 899,
            "interval": 5
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DeviceCodeResponse.self, from: json)
        XCTAssertEqual(response.deviceCode, "abc123def456")
        XCTAssertEqual(response.userCode, "ABCD-1234")
        XCTAssertEqual(response.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(response.expiresIn, 899)
        XCTAssertEqual(response.interval, 5)
    }

    func testDeviceCodeResponseDecodingMissingFieldThrows() {
        let json = """
        {
            "device_code": "abc",
            "user_code": "ABCD-1234"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(DeviceCodeResponse.self, from: json))
    }

    // MARK: - Token Poll Response Parsing

    func testTokenPollSuccessResponse() throws {
        let json = """
        {
            "access_token": "gho_token_value_here",
            "token_type": "bearer",
            "scope": "read:user,copilot"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenPollResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "gho_token_value_here")
        XCTAssertEqual(response.tokenType, "bearer")
        XCTAssertEqual(response.scope, "read:user,copilot")
        XCTAssertNil(response.error)
    }

    func testTokenPollAuthorizationPending() throws {
        let json = """
        { "error": "authorization_pending" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenPollResponse.self, from: json)
        XCTAssertNil(response.accessToken)
        XCTAssertEqual(response.error, "authorization_pending")
    }

    func testTokenPollSlowDown() throws {
        let json = """
        { "error": "slow_down" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenPollResponse.self, from: json)
        XCTAssertNil(response.accessToken)
        XCTAssertEqual(response.error, "slow_down")
    }

    func testTokenPollExpiredToken() throws {
        let json = """
        { "error": "expired_token" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenPollResponse.self, from: json)
        XCTAssertNil(response.accessToken)
        XCTAssertEqual(response.error, "expired_token")
    }

    func testTokenPollAccessDenied() throws {
        let json = """
        { "error": "access_denied" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenPollResponse.self, from: json)
        XCTAssertNil(response.accessToken)
        XCTAssertEqual(response.error, "access_denied")
    }

    // MARK: - DirectCopilotClient Construction

    func testDirectCopilotClientSetsHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        let userRequest = XCTestExpectation(description: "User endpoint requested")
        let billingRequest = XCTestExpectation(description: "Billing endpoint requested")

        MockHTTPProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token gho_test_token_abc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "QuotaBar")

            switch request.url?.path {
            case "/copilot_internal/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                userRequest.fulfill()

                let responseJSON = """
                {
                    "login": "testuser",
                    "quota_snapshots": {
                        "premium_interactions": {
                            "percent_remaining": 100,
                            "remaining": 50,
                            "entitlement": 50
                        }
                    }
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            case "/users/testuser/settings/billing/premium_request/usage":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                billingRequest.fulfill()

                let responseJSON = """
                {
                    "usageItems": [
                        { "grossQuantity": 0 }
                    ]
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        }

        let account = makeAccount(login: "testuser", accessToken: "gho_test_token_abc")
        let client = DirectCopilotClient(account: account, session: session)
        _ = try await client.fetchQuotaCard()

        await fulfillment(of: [userRequest, billingRequest], timeout: 5)
    }

    // MARK: - DirectCopilotClient Success Parsing

    func testDirectCopilotClientParsesValidResponse() throws {
        let json = """
        {
            "login": "testuser",
            "access_type_sku": "monthly_subscriber_quota",
            "copilot_plan": "individual",
            "quota_reset_date": "2025-02-01",
            "quota_snapshots": {
                "premium_interactions": {
                    "percent_remaining": 75.5,
                    "quota_remaining": 37.75,
                    "remaining": 37,
                    "entitlement": 50
                }
            }
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(CopilotUserResponse.self, from: json)
        let card = CopilotQuotaBuilder.makeCard(user: user)

        XCTAssertEqual(card.provider, .copilot)
        XCTAssertEqual(card.title, "testuser")
        XCTAssertEqual(card.planLabel, "PRO")
        XCTAssertFalse(card.windows.isEmpty)
        XCTAssertNil(card.errorMessage)
    }

    // MARK: - DirectCopilotClient Error Handling

    func testDirectCopilotClientNon200ThrowsError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        MockHTTPProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let account = makeAccount(login: "testuser", accessToken: "expired_token")
        let client = DirectCopilotClient(account: account, session: session)

        do {
            _ = try await client.fetchQuotaCard()
            XCTFail("Expected error for 401 response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
    }

    func testDirectCopilotClientInvalidJSONThrowsError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        MockHTTPProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("not json".utf8), response)
        }

        let account = makeAccount(login: "testuser", accessToken: "some_token")
        let client = DirectCopilotClient(account: account, session: session)

        do {
            _ = try await client.fetchQuotaCard()
            XCTFail("Expected error for invalid JSON")
        } catch {
            // Decoding error is expected
        }
    }

    func testDirectCopilotClient200WithValidCopilotResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        let responseJSON = """
        {
            "login": "octocat",
            "access_type_sku": "free_limited_copilot",
            "copilot_plan": "individual",
            "quota_reset_date_utc": "2025-03-01T00:00:00.000Z",
            "quota_snapshots": {
                "premium_interactions": {
                    "percent_remaining": 50.0,
                    "quota_remaining": 25,
                    "remaining": 25,
                    "entitlement": 50
                }
            }
        }
        """

        MockHTTPProtocol.handler = { request in
            if request.url?.path == "/copilot_internal/user" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: [
                    "X-Accepted-OAuth-Scopes": "user",
                    "X-OAuth-Scopes": "copilot, read:user",
                ]
            )!
            return (Data("{}".utf8), response)
        }

        let account = makeAccount(login: "octocat", accessToken: "gho_valid_token")
        let client = DirectCopilotClient(account: account, session: session)
        let card = try await client.fetchQuotaCard()

        XCTAssertEqual(card.provider, .copilot)
        XCTAssertEqual(card.title, "octocat")
        XCTAssertEqual(card.planLabel, "FREE")
        XCTAssertEqual(card.windows.count, 1)
        XCTAssertNil(card.errorMessage)
    }

    func testDirectCopilotClientUsesBillingUsageReportForAuthoritativeConsumption() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        let billingRequestSeen = XCTestExpectation(description: "Billing usage endpoint requested")
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        let expectedPath = "/users/SemiStack/settings/billing/premium_request/usage"
        let expectedYear = String(components.year ?? 0)
        let expectedMonth = String(components.month ?? 0)

        MockHTTPProtocol.handler = { request in
            guard let url = request.url else {
                XCTFail("Missing request URL")
                let fallbackURL = URL(string: "https://example.com")!
                let response = HTTPURLResponse(
                    url: fallbackURL,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }

            switch url.path {
            case "/copilot_internal/user":
                let responseJSON = """
                {
                    "login": "SemiStack",
                    "access_type_sku": "plus_monthly_subscriber_quota",
                    "copilot_plan": "individual_pro",
                    "quota_reset_date": "2026-05-01",
                    "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
                    "quota_snapshots": {
                        "premium_interactions": {
                            "percent_remaining": 89.1,
                            "quota_remaining": 1336.7,
                            "remaining": 1336,
                            "entitlement": 1500
                        }
                    }
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            case expectedPath:
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first(where: { $0.name == "year" })?.value, expectedYear)
                XCTAssertEqual(query.first(where: { $0.name == "month" })?.value, expectedMonth)
                billingRequestSeen.fulfill()

                let responseJSON = """
                {
                    "usageItems": [
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "Claude Haiku 4.5",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 2.31,
                            "discountQuantity": 32.31,
                            "netQuantity": -30.0
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "Claude Opus 4.6",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 138.0,
                            "discountQuantity": 138.0,
                            "netQuantity": 0.0
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "Claude Opus 4.7",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 7.5,
                            "discountQuantity": 7.5,
                            "netQuantity": 0.0
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "Claude Sonnet 4.5",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 0.0,
                            "discountQuantity": 7.5,
                            "netQuantity": -7.5
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "Claude Sonnet 4.6",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 13.0,
                            "discountQuantity": 13.0,
                            "netQuantity": 0.0
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "GPT-5.4",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 8.0,
                            "discountQuantity": 8.0,
                            "netQuantity": 0.0
                        },
                        {
                            "product": "Copilot",
                            "sku": "Copilot Premium Request",
                            "model": "GPT-5.4 mini",
                            "unitType": "requests",
                            "pricePerUnit": 0.04,
                            "grossQuantity": 0.66,
                            "discountQuantity": 0.66,
                            "netQuantity": 0.0
                        }
                    ]
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        }

        let account = makeAccount(login: "SemiStack", accessToken: "gho_valid_token")
        let client = DirectCopilotClient(account: account, session: session)
        let card = try await client.fetchQuotaCard()

        await fulfillment(of: [billingRequestSeen], timeout: 5)
        XCTAssertEqual(card.planLabel, "PRO +")
        XCTAssertEqual(card.windows.first?.valueText, "86%/206.97")
        XCTAssertEqual(card.windows.first?.resetLabel, "05/01 · 1500")
    }

    func testDirectCopilotClientPromptsReloginWhenBillingScopeMissing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        MockHTTPProtocol.handler = { request in
            guard let url = request.url else {
                let fallbackURL = URL(string: "https://example.com")!
                let response = HTTPURLResponse(
                    url: fallbackURL,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }

            switch url.path {
            case "/copilot_internal/user":
                let responseJSON = """
                {
                    "login": "SemiStack",
                    "access_type_sku": "plus_monthly_subscriber_quota",
                    "copilot_plan": "individual_pro",
                    "quota_reset_date": "2026-05-01",
                    "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
                    "quota_snapshots": {
                        "premium_interactions": {
                            "percent_remaining": 89.1,
                            "quota_remaining": 1336.7,
                            "remaining": 1336,
                            "entitlement": 1500
                        }
                    }
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            case "/users/SemiStack/settings/billing/premium_request/usage":
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: [
                        "X-Accepted-OAuth-Scopes": "user",
                        "X-OAuth-Scopes": "copilot, read:user",
                    ]
                )!
                return (Data("{}".utf8), response)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        }

        let account = makeAccount(login: "SemiStack", accessToken: "gho_legacy_scope_token")
        let client = DirectCopilotClient(account: account, session: session)
        let card = try await client.fetchQuotaCard()

        XCTAssertEqual(card.planLabel, "PRO +")
        XCTAssertEqual(card.subtitle, "重新登录后可同步官网用量")
        XCTAssertEqual(card.windows.first?.valueText, "89%/163.3")
    }

    // MARK: - CopilotOAuthClient HTTP Integration Tests

    func testRequestDeviceCodeSetsCorrectHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        let expectation = XCTestExpectation(description: "Request intercepted")

        MockHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            
            if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
                XCTAssertTrue(bodyString.contains("client_id=178c6fc778ccc68e1d6a"))
                XCTAssertTrue(bodyString.contains("scope=read:user%20user%20copilot"))
                XCTAssertTrue(bodyString.contains("copilot"))
            } else {
                XCTFail("Request body is missing")
            }
            
            expectation.fulfill()

            let responseJSON = """
            {
                "device_code": "test_device_code",
                "user_code": "TEST-CODE",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5
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

        let client = CopilotOAuthClient(session: session)
        _ = try await client.requestDeviceCode()

        await fulfillment(of: [expectation], timeout: 5)
    }

    func testRequestDeviceCodeNon200Throws() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        MockHTTPProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let client = CopilotOAuthClient(session: session)

        do {
            _ = try await client.requestDeviceCode()
            XCTFail("Expected error for non-200 response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testFetchUserInfoSetsAuthHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        let expectation = XCTestExpectation(description: "Request intercepted")

        MockHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token gho_test_token_123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "QuotaBar")
            expectation.fulfill()

            let responseJSON = """
            {
                "login": "testuser",
                "email": "test@example.com"
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

        let client = CopilotOAuthClient(session: session)
        _ = try await client.fetchUserInfo(accessToken: "gho_test_token_123")

        await fulfillment(of: [expectation], timeout: 5)
    }

    func testFetchUserInfoParsesLoginAndEmail() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        let session = URLSession(configuration: config)

        MockHTTPProtocol.handler = { request in
            let responseJSON = """
            {
                "login": "octocat",
                "email": "octocat@github.com"
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

        let client = CopilotOAuthClient(session: session)
        let (login, email) = try await client.fetchUserInfo(accessToken: "gho_test_token")

        XCTAssertEqual(login, "octocat")
        XCTAssertEqual(email, "octocat@github.com")
    }
}
