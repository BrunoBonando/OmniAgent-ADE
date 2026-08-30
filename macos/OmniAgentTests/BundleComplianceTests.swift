import AppKit
import XCTest
@testable import OmniAgent

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

    /// Both Help pages ship inside the app. A missing file is a silent
    /// no-op at the menu item — and an unmet MIT attribution obligation.
    func testBothLegalPagesAreBundled() {
        for doc in LegalDocument.allCases { XCTAssertNotNil(doc.url, doc.rawValue) }
    }

    /// …and both are reachable from the Help menu, through the responder
    /// chain. The selectors are built from strings, so only a test catches a
    /// typo — it would show as a permanently greyed-out item.
    func testTheHelpMenuOffersBothLegalPages() throws {
        ApplicationMenus.install()
        let help = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Help")?.submenu)
        XCTAssertTrue(NSApp.helpMenu === help, "the system Help menu, so ⌘? and the search field find it")
        let items = LegalDocument.allCases.map { doc in help.item(withTitle: doc.title) }
        XCTAssertEqual(
            items.map { $0?.action },
            [
                #selector(WorkspaceWindowController.showPrivacyPolicy(_:)),
                #selector(WorkspaceWindowController.showThirdPartyNotices(_:)),
            ]
        )
        XCTAssertTrue(items.allSatisfy { $0?.target == nil }, "they travel the responder chain")
    }
}
