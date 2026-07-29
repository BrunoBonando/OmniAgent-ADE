import AppKit

let application = NSApplication.shared
let applicationDelegate: AppDelegate?
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    applicationDelegate = AppDelegate()
    application.delegate = applicationDelegate
} else {
    applicationDelegate = nil
}
application.run()
