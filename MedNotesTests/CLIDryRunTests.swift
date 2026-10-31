import XCTest

final class CLIDryRunTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private var cliPath: String {
        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("bin/mednotes-import").path
    }

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private func requireRunnableCLI() throws {
        if isSandboxed {
            throw XCTSkip("CLI cannot be launched from the sandboxed test host")
        }
        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw XCTSkip("CLI binary not compiled at \(cliPath)")
        }
    }

    func testCLISafetyRefusesBackupsFolder() throws {
        try requireRunnableCLI()

        let backupFakeDir = tempDir.appendingPathComponent("Backups/backup_2026-03-05_00-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: backupFakeDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--source", backupFakeDir.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, "CLI should refuse folders named Backups")
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("SAFETY REFUSAL"), "Expected safety refusal message, got: \(output)")
    }

    func testCLISourceRequiresPath() throws {
        try requireRunnableCLI()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--source"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("--source requires a path"), "got: \(output)")
    }

    func testCLIInterruptRemovesTheDryRunStagingFolder() throws {
        try requireRunnableCLI()

        let source = tempDir.appendingPathComponent("InterruptSource", isDirectory: true)
        let notes = source.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let content = String(repeating: "x", count: 20_000)
        for index in 0..<400 {
            let json = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"note \(index)\",\"content\":\"\(content)\"}"
            try Data(json.utf8).write(
                to: notes.appendingPathComponent("note-\(index).json"))
        }

        let temporary = FileManager.default.temporaryDirectory
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--source", source.path, "--dry-run"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let deadline = Date().addingTimeInterval(20)
        var staging: String?
        while Date() < deadline {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
            staging = names.subtracting(before).first { $0.hasPrefix("mednotes-dryrun-") }
            if staging != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let found = try XCTUnwrap(staging, "the CLI did not start a dry-run staging folder")
        process.interrupt()
        process.waitUntilExit()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()

        XCTAssertNotEqual(process.terminationStatus, 0, "the CLI was interrupted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(found).path),
                       "an interrupted dry run left its plaintext staging folder behind")
    }

    func testCLIDryRunOnEmptySource() throws {
        try requireRunnableCLI()

        let emptySource = tempDir.appendingPathComponent("EmptyStore", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySource, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--source", emptySource.path, "--dry-run"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Patients imported:       0"))
        XCTAssertTrue(output.contains("Integrity check:         ok"))
        XCTAssertTrue(output.contains("Foreign key violations:  0"))
        XCTAssertTrue(output.contains("Staging database deleted successfully"))
    }
}
