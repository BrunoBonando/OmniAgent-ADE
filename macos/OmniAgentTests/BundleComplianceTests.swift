import AppKit
import XCTest
@testable import OmniAgent

/// The App Store / notarisation bundle facts a reviewer would check first.
/// Tests are hosted in OmniAgent.app, so `Bundle.main` *is* the bundle.
final class BundleComplianceTests: XCTestCase {
    /// Every required-reason API the app touches, with the *exact* reason
    /// code that matches how it touches it — App Review rejects a manifest
    /// that declares a reason the code does not fit:
    ///   - `CA92.1` — UserDefaults read/written only by this app.
    ///   - `3B52.1` — file timestamps of files the user granted access to
    ///     through an open panel (`EditorPaneView`), *not* `C617.1`, which
    ///     is for files inside the app's own container.
    ///   - `35F9.1` — `ProcessInfo.systemUptime` timing elapsed time between
    ///     in-app events (`ReviewPanelFilesView`'s double-press to pin).
    /// Asserting the exact sets, not just membership, is the point: a new
    /// required-reason API added to the app fails here until it is declared.
    func testThePrivacyManifestIsBundledAndDeclaresTheAPIsTheAppUses() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasonsByType = Dictionary(
            uniqueKeysWithValues: apis.map {
                ($0["NSPrivacyAccessedAPIType"] as? String ?? "", $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
            }
        )
        XCTAssertEqual(
            reasonsByType,
            [
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["3B52.1"],
                "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            ]
        )
    }

    /// The app collects exactly what signing in hands it — an email address
    /// and a display name, linked to the account, for app functionality —
    /// and nothing is used for tracking. Anything new sent off-device has to
    /// be declared here before it ships.
    func testThePrivacyManifestDeclaresExactlyTheDataSignInCollects() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(
            Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
            ["NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeName"]
        )
        XCTAssertTrue(
            collected.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false },
            "nothing the app collects may be declared as tracking"
        )
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
