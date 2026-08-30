import XCTest

/// The App Store / notarisation bundle facts a reviewer would check first.
/// Tests are hosted in OmniAgent.app, so `Bundle.main` *is* the bundle.
final class BundleComplianceTests: XCTestCase {
    func testThePrivacyManifestIsBundledAndDeclaresTheAPIsTheAppUses() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let types = apis.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertEqual(Set(types), ["NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryFileTimestamp"])
    }

    func testTheInfoPlistCarriesTheStoreFacingKeys() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.developer-tools")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "© 2026 Bruno Bonando. All rights reserved.")
        for key in ["NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription", "NSDownloadsFolderUsageDescription"] {
            XCTAssertFalse((info[key] as? String ?? "").isEmpty, key)
        }
    }
}
