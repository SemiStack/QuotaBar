import XCTest

final class ProjectSigningConfigTests: XCTestCase {
    func testIOSProjectDoesNotDisableCodeSigning() throws {
        let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("project.yml")
        let contents = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertFalse(contents.contains("CODE_SIGNING_ALLOWED: NO"))
        XCTAssertFalse(contents.contains("CODE_SIGNING_REQUIRED: NO"))
        XCTAssertTrue(contents.contains("QuotaBarIOS:"))
        XCTAssertTrue(contents.contains("CODE_SIGN_STYLE: Automatic"))
    }
}
