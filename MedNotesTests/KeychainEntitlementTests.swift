import Security
import XCTest

/// The data-protection Keychain answers only an app that carries an
/// application identifier, which a provisioning profile grants. An ad-hoc or
/// profile-less build is refused with `errSecMissingEntitlement` (-34018) on
/// every call, so the app could not create or read its device key. Every other
/// test uses `InMemoryKeyManager`, which never reaches the Keychain: this is the
/// one place that does.
final class KeychainEntitlementTests: XCTestCase {
    /// The team the host app was signed by, or nil for an ad-hoc signature.
    private static var hostTeamIdentifier: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.team-identifier" as CFString, nil) as? String
    }

    func testTheDataProtectionKeychainAcceptsThisBuild() throws {
        guard Self.hostTeamIdentifier != nil else {
            throw XCTSkip("Ad-hoc signed build. Set a team in Config/Local.xcconfig to run this.")
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mednotes-entitlement-probe-\(UUID().uuidString)",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true
        ]
        var added = item
        added[kSecValueData as String] = Data(repeating: 7, count: 32)
        let status = SecItemAdd(added as CFDictionary, nil)
        defer { _ = SecItemDelete(item as CFDictionary) }

        XCTAssertNotEqual(status, errSecMissingEntitlement,
                          "the build lacks the application-identifier entitlement")
        XCTAssertEqual(status, errSecSuccess)
    }
}
