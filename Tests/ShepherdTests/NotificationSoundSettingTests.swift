import Foundation
import XCTest
@testable import Shepherd

final class NotificationSoundSettingTests: XCTestCase {
    @MainActor
    func testDefaultsToNoSoundForBothKinds() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let setting = NotificationSoundSetting(defaults: defaults)

        XCTAssertEqual(setting.choice(for: .done), .none)
        XCTAssertEqual(setting.choice(for: .blocked), .none)
    }

    @MainActor
    func testChoicesPersistAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let setting = NotificationSoundSetting(defaults: defaults)
        setting.doneSound = .named("Glass")
        setting.blockedSound = .systemDefault

        let reloaded = NotificationSoundSetting(defaults: defaults)
        XCTAssertEqual(reloaded.choice(for: .done), .named("Glass"))
        XCTAssertEqual(reloaded.choice(for: .blocked), .systemDefault)
    }

    @MainActor
    func testUnknownStoredValueFallsBackToNoSound() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("mystery", forKey: NotificationSoundSetting.doneKey)

        let setting = NotificationSoundSetting(defaults: defaults)

        XCTAssertEqual(setting.choice(for: .done), .none)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "NotificationSoundSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
