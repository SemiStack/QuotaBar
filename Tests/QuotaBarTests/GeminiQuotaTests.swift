import XCTest
@testable import QuotaBar

final class GeminiQuotaTests: XCTestCase {
    func testGeminiProjectIDHintFallsBackToAccountSuffix() {
        let file = AuthFile(
            fileID: nil,
            name: "gemini-liujiachxy@gmail.com-designcodesample.json",
            authIndex: "ab3b75e01183750c",
            provider: "gemini-cli",
            type: "gemini-cli",
            status: nil,
            statusMessage: nil,
            disabled: false,
            unavailable: false,
            email: "liujiachxy@gmail.com",
            account: "liujiachxy@gmail.com (designcodesample)",
            idToken: nil,
            path: nil,
            nextRetryAfter: nil
        )

        XCTAssertEqual(file.geminiProjectIDHint, "designcodesample")
    }

    func testGeminiQuotaBuilderGroupsBucketsIntoSeriesRows() {
        let file = makeGeminiFile()
        let codeAssist = GeminiCodeAssistResponse(
            currentTier: GeminiCodeAssistTier(id: "free-tier", name: "Free", description: nil),
            allowedTiers: nil,
            cloudaicompanionProject: .string("optical-glass-zsthn"),
            gcpManaged: nil,
            paidTier: nil
        )
        let quota = GeminiQuotaResponse(
            buckets: [
                GeminiQuotaBucket(
                    resetTime: "2026-04-07T20:11:55Z",
                    tokenType: "REQUESTS",
                    modelId: "gemini-2.5-flash-lite",
                    remainingFraction: 1
                ),
                GeminiQuotaBucket(
                    resetTime: "2026-04-07T18:14:54Z",
                    tokenType: "REQUESTS",
                    modelId: "gemini-2.5-flash",
                    remainingFraction: 0.976
                ),
                GeminiQuotaBucket(
                    resetTime: "2026-04-07T16:47:54Z",
                    tokenType: "REQUESTS",
                    modelId: "gemini-2.5-pro",
                    remainingFraction: 0.006666667
                ),
            ]
        )

        let card = GeminiQuotaBuilder.makeCard(
            file: file,
            projectID: "designcodesample",
            codeAssist: codeAssist,
            quota: quota
        )

        XCTAssertEqual(card.planLabel, "免费版")
        XCTAssertEqual(card.subtitle, "designcodesample")
        XCTAssertEqual(card.primaryStatusRow?.remainingPercent, 1)
        XCTAssertEqual(
            card.windows.map(\.label),
            ["Gemini Flash Lite Series", "Gemini Flash Series", "Gemini Pro Series"]
        )
        XCTAssertEqual(card.windows.map(\.remainingPercent), [100, 98, 1])
        XCTAssertEqual(card.windows.map(\.compactLabel), ["Lite", "Flash", "Pro"])
    }

    func testGeminiQuotaBuilderIgnoresNonRequestBucketsWhenRequestBucketsExist() {
        let card = GeminiQuotaBuilder.makeCard(
            file: makeGeminiFile(),
            projectID: "designcodesample",
            codeAssist: makeCodeAssistResponse(),
            quota: GeminiQuotaResponse(
                buckets: [
                    GeminiQuotaBucket(
                        resetTime: "2026-04-07T18:14:54Z",
                        tokenType: "TOKENS",
                        modelId: "gemini-2.5-flash",
                        remainingFraction: 0.1
                    ),
                    GeminiQuotaBucket(
                        resetTime: "2026-04-07T17:14:54Z",
                        tokenType: "REQUESTS",
                        modelId: "gemini-2.5-flash",
                        remainingFraction: 0.8
                    ),
                ]
            )
        )

        XCTAssertEqual(card.windows.count, 1)
        XCTAssertEqual(card.windows.first?.label, "Gemini Flash Series")
        XCTAssertEqual(card.windows.first?.remainingPercent, 80)
    }

    func testGeminiQuotaBuilderSubtitleUsesResolvedProjectIDAfterFallback() {
        let file = makeGeminiFile(account: "liujiachxy@gmail.com (stale-project)")

        let card = GeminiQuotaBuilder.makeCard(
            file: file,
            projectID: "resolved-project",
            codeAssist: makeCodeAssistResponse(),
            quota: GeminiQuotaResponse(buckets: [])
        )

        XCTAssertEqual(card.subtitle, "resolved-project")
    }
}

private func makeGeminiFile(account: String = "liujiachxy@gmail.com (designcodesample)") -> AuthFile {
    AuthFile(
        fileID: nil,
        name: "gemini-liujiachxy@gmail.com-designcodesample.json",
        authIndex: "ab3b75e01183750c",
        provider: "gemini-cli",
        type: "gemini-cli",
        status: nil,
        statusMessage: nil,
        disabled: false,
        unavailable: false,
        email: "liujiachxy@gmail.com",
        account: account,
        idToken: nil,
        path: nil,
        nextRetryAfter: nil
    )
}

private func makeCodeAssistResponse() -> GeminiCodeAssistResponse {
    GeminiCodeAssistResponse(
        currentTier: GeminiCodeAssistTier(id: "free-tier", name: "Free", description: nil),
        allowedTiers: nil,
        cloudaicompanionProject: .string("optical-glass-zsthn"),
        gcpManaged: nil,
        paidTier: nil
    )
}
