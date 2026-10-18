import Foundation
import Testing

/// R11: the GitHub Actions workflows stay pinned and least-privilege. A quick check of the repository's own files
/// from `swift test`; `scripts/check-workflows.py` enforces the full policy (exact permissions per job, checkout
/// credentials, expressions in scripts) and `scripts/test_check_workflows.py` tests that script.
struct WorkflowPolicyTests {
    static let workflows = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".github/workflows")

    static func files() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(atPath: workflows.path).filter { $0.hasSuffix(".yml") }.sorted()
            .map { ($0, try String(contentsOf: workflows.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func workflowsExist() throws {
        #expect(try Self.files().map(\.name) == ["release.yml", "test.yml"])
    }

    /// Every action is pinned to a full commit SHA with its version in a comment, never a tag or branch.
    @Test func actionsPinnedToCommits() throws {
        let pinned = try Regex(#"^\s*(-\s+)?uses:\s*[\w.-]+/[\w.-]+(/[\w./-]+)?@[0-9a-f]{40} # v\d[\w.]*\s*$"#)
        for (name, text) in try Self.files() {
            let uses = text.split(separator: "\n").filter { $0.contains("uses:") }
            #expect(!uses.isEmpty, "\(name)")
            for line in uses {
                #expect(String(line).wholeMatch(of: pinned) != nil, "\(name): \(line)")
            }
        }
    }

    /// Each workflow declares its token permissions; none grants everything; write access only where publishing.
    @Test func permissionsExplicitAndNarrow() throws {
        for (name, text) in try Self.files() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.contains { $0.hasPrefix("permissions:") }, "\(name) has no top-level permissions")
            #expect(!text.contains("write-all") && !text.contains("read-all"), "\(name)")
            #expect(!text.contains("pull_request_target"), "\(name)")
            let writes = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") && $0.contains(": write") }
            #expect(writes == (name == "release.yml" ? ["contents: write"] : []), "\(name): \(writes)")
        }
        let release = try #require(try Self.files().first { $0.name == "release.yml" }?.text)
        #expect(release.contains("permissions: {}"))
    }

    /// The token and secrets go only to the step that uses them (step `env:` is indented 10 spaces), never to a whole
    /// job or workflow.
    @Test func tokenOnlyInSteps() throws {
        for (name, text) in try Self.files() {
            for line in text.split(separator: "\n") where line.contains("github.token") || line.contains("secrets.") {
                let indent = line.prefix { $0 == " " }.count
                #expect(indent >= 10, "\(name): \(line)")
            }
        }
    }

    /// #11: `release.yml` uploads only after `scripts/verify-release.sh` has passed on the DMG, and no workflow tells
    /// users to bypass Gatekeeper. `scripts/check-workflows.py` enforces this per step.
    @Test func releasePublishesOnlyAfterTheGate() throws {
        let release = try #require(try Self.files().first { $0.name == "release.yml" }?.text)
        let gate = try #require(release.range(of: #"scripts/verify-release.sh "build/"#))
        for publish in [#"gh release create "$TAG""#, #"gh release upload "$TAG""#] {
            let at = try #require(release.range(of: publish), "\(publish)")
            #expect(gate.upperBound < at.lowerBound, "\(publish) before the gate")
        }
        // The upload checks the bytes the gate verified, by the hash the gate output.
        #expect(release.contains("id: verify") && release.contains("${{ steps.verify.outputs.sha256 }}"))
        #expect(release.contains(#"| shasum -a 256 -c -"#))
        for (name, text) in try Self.files() {
            #expect(!text.localizedCaseInsensitiveContains("open anyway"), "\(name)")
            #expect(!text.contains("com.apple.quarantine"), "\(name)")
        }
        let script = Self.workflows.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/verify-release.sh").path
        #expect(FileManager.default.isExecutableFile(atPath: script))
    }

    @Test func checkoutDoesNotPersistCredentials() throws {
        for (name, text) in try Self.files() {
            let checkouts = text.components(separatedBy: "actions/checkout@").count - 1
            let off = text.components(separatedBy: "persist-credentials: false").count - 1
            #expect(checkouts > 0 && off == checkouts, "\(name)")
        }
    }
}
