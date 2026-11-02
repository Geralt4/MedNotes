import XCTest
@testable import MedNotes

/// A file panel that answers at once.
private final class AnsweringPanels: FilePanels {
    var answer: URL?
    private(set) var asked = 0
    func run(_ request: FilePanelRequest) -> URL? { asked += 1; return answer }
    func cancelRunning() {}
}

/// "Generate" in the Back Up sheet: what a generated passphrase is, that it is
/// never logged, and that no backup is made with one until the user has said
/// it is saved.
@MainActor
final class GeneratedPassphraseTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.GeneratedPassphrase"
    private var tempDir: URL!
    private var panels: AnsweringPanels!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-genpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        panels = AnsweringPanels()
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        SecurityLog.observer = nil
        TestDefaults.clear(Self.defaultsName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        let session = AppSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName),
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)), panels: panels)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    // MARK: - What is generated

    func testAGeneratedPassphraseHasTheLengthTheGroupsAndTheAlphabet() throws {
        let generated = try BackupPassphrasePolicy.generate()
        XCTAssertEqual(generated.count, 28 + 6)
        let groups = generated.split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [4, 4, 4, 4, 4, 4, 4], "seven short groups")
        let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(generated.replacingOccurrences(of: "-", with: "").allSatisfy(alphabet.contains))
    }

    /// Nothing that looks like something else: no 0 or O, no 1, I or l (and not L).
    func testNoCharacterCanBeMistakenForAnother() throws {
        let alphabet = String(BackupPassphrasePolicy.generatedAlphabet)
        for confusable in "0O1IlL" { XCTAssertFalse(alphabet.contains(confusable), "“\(confusable)” is in the alphabet") }
        XCTAssertEqual(Set(alphabet).count, alphabet.count, "no repeated character")
        // And none appears in what is generated.
        for _ in 0..<200 {
            let generated = try BackupPassphrasePolicy.generate()
            XCTAssertNil(generated.first { "0O1IlL".contains($0) }, generated)
        }
    }

    func testAGeneratedPassphraseHasAtLeast128BitsOfStrength() {
        XCTAssertGreaterThanOrEqual(BackupPassphrasePolicy.generatedBits, 128)
        XCTAssertEqual(BackupPassphrasePolicy.generatedBits, 28 * log2(30.0), accuracy: 0.0001)
    }

    func testTwoGenerationsDifferAndSoDoTwoHundred() throws {
        XCTAssertNotEqual(try BackupPassphrasePolicy.generate(), try BackupPassphrasePolicy.generate())
        let many = try (0..<200).map { _ in try BackupPassphrasePolicy.generate() }
        XCTAssertEqual(Set(many).count, 200)
    }

    func testEveryGeneratedPassphraseIsAcceptedByThePolicy() throws {
        for _ in 0..<50 {
            XCTAssertTrue(BackupPassphrasePolicy.isAcceptable(try BackupPassphrasePolicy.generate()))
        }
    }

    /// Characters are drawn evenly: bytes the alphabet cannot share out evenly
    /// are thrown away, and each of the others picks one character.
    func testBytesAreSampledWithoutBias() throws {
        // 30 characters; 240 = 8 × 30 is the largest usable multiple.
        let rejectedThenUsed: [UInt8] = [255, 250, 240] + Array(0..<30) + [29, 28]
        var supplied = false
        let generated = try BackupPassphrasePolicy.generate { _ in
            defer { supplied = true }
            return supplied ? Array(repeating: 0, count: 64) : rejectedThenUsed
        }
        let characters = generated.replacingOccurrences(of: "-", with: "")
        let alphabet = BackupPassphrasePolicy.generatedAlphabet
        let expected = (Array(0..<30) + [29, 28]).prefix(28).map { alphabet[$0 % 30] }
        XCTAssertEqual(Array(characters), Array(expected), "255, 250 and 240 were rejected, the rest used in order")
    }

    func testAFailingRandomSourceThrowsInsteadOfFallingBack() {
        struct Broken: Error {}
        XCTAssertThrowsError(try BackupPassphrasePolicy.generate { _ in throw Broken() })
        XCTAssertThrowsError(try BackupPassphrasePolicy.generate { _ in [] }, "a source that gives nothing")
    }

    // MARK: - Never logged

    func testAGeneratedPassphraseNeverReachesTheLog() async throws {
        var recorded: [String] = []
        SecurityLog.observer = { event, count, detail in
            recorded.append("\(event.rawValue) \(count.map(String.init) ?? "") \(detail ?? "")")
        }
        let session = try await makeSession()
        let passphrase = try BackupPassphrasePolicy.generate()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MedNotesTests.genpass-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        PassphraseClipboard(pasteboard: pasteboard).copy(passphrase, after: 0.1)
        panels.answer = tempDir.appendingPathComponent("Logged.mednotesbackup")

        try await session.performBackup(name: "Logged", passphrase: passphrase, source: .generated(confirmedSaved: true))
        // A failure on the same screen logs its detail, and a lock logs its event.
        _ = UserFacingFailure.message(for: SQLiteError.step("disk I/O error", sql: ""), during: .backup)
        await session.lockNow(reason: "idle")

        XCTAssertTrue(FileManager.default.fileExists(atPath: panels.answer!.path), "precondition: the backup ran")
        XCTAssertFalse(recorded.isEmpty, "precondition: events were recorded")
        for entry in recorded {
            XCTAssertFalse(entry.contains(passphrase), entry)
            for group in passphrase.split(separator: "-") {
                XCTAssertFalse(entry.contains(String(group)), "a group of the passphrase is in the log: \(entry)")
            }
        }
    }

    // MARK: - The backup waits for the user's word

    func testABackupWithAnUnconfirmedGeneratedPassphraseIsRefusedAndWritesNothing() async throws {
        let session = try await makeSession()
        let archive = tempDir.appendingPathComponent("Refused.mednotesbackup")
        panels.answer = archive
        let passphrase = try BackupPassphrasePolicy.generate()

        do {
            try await session.performBackup(name: "Refused", passphrase: passphrase, source: .generated(confirmedSaved: false))
            XCTFail("the backup went ahead before the passphrase was confirmed as saved")
        } catch {
            XCTAssertTrue(error is PassphraseNotConfirmedError, "\(error)")
            XCTAssertEqual(error.localizedDescription,
                           String(localized: "Confirm that you have saved the passphrase before the backup is made."))
        }
        XCTAssertEqual(panels.asked, 0, "not even the save panel was shown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertNil(session.notice)
    }

    func testAConfirmedGeneratedPassphraseMakesABackupOnlyItOpens() async throws {
        let session = try await makeSession()
        let archive = tempDir.appendingPathComponent("Confirmed.mednotesbackup")
        panels.answer = archive
        let passphrase = try BackupPassphrasePolicy.generate()

        try await session.performBackup(name: "Confirmed", passphrase: passphrase, source: .generated(confirmedSaved: true))

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let manifest = try await session.inspectBackup(at: archive, passphrase: passphrase)
        XCTAssertEqual(manifest.name, "Confirmed")
        do {
            _ = try await session.inspectBackup(at: archive, passphrase: passphrase + "x")
            XCTFail("another passphrase opened the backup")
        } catch { /* expected */ }
    }

    /// A typed passphrase is not held back by the gate.
    func testATypedPassphraseNeedsNoConfirmation() async throws {
        let session = try await makeSession()
        let archive = tempDir.appendingPathComponent("Typed.mednotesbackup")
        panels.answer = archive

        try await session.performBackup(name: "Typed", passphrase: "a long enough passphrase")

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    // MARK: - The sheet's button

    func testTheBackUpButtonWaitsForTheConfirmationOfAGeneratedPassphrase() throws {
        let passphrase = try BackupPassphrasePolicy.generate()
        func enabled(generated: String?, confirmed: Bool, name: String = "Backup", working: Bool = false,
                     confirmation: String? = nil) -> Bool {
            BackupFlowSheet.canBackUp(name: name, passphrase: passphrase, confirmation: confirmation ?? passphrase,
                                      generated: generated, confirmedSaved: confirmed, isWorking: working)
        }
        XCTAssertFalse(enabled(generated: passphrase, confirmed: false), "generated and not confirmed")
        XCTAssertTrue(enabled(generated: passphrase, confirmed: true))
        XCTAssertTrue(enabled(generated: nil, confirmed: false), "a typed passphrase needs no confirmation")
        XCTAssertFalse(enabled(generated: passphrase, confirmed: true, name: "  "))
        XCTAssertFalse(enabled(generated: passphrase, confirmed: true, working: true))
        XCTAssertFalse(enabled(generated: passphrase, confirmed: true, confirmation: "other"))
    }
}
