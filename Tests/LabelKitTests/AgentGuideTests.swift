import XCTest
@testable import LabelKit

final class AgentGuideTests: XCTestCase {
    /// Repo root, found from this file: Tests/LabelKitTests/AgentGuideTests.swift.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `skills/labelkit/SKILL.md` is what repository-based installers serve
    /// (`npx skills add`, plugin marketplaces); `labelkit skill` serves the
    /// compiled-in text. They must not drift. To refresh the file after editing
    /// the guide: `swift run labelkit skill > skills/labelkit/SKILL.md`.
    func testRepoSkillFileMatchesTheBuiltInGuide() throws {
        let file = repoRoot.appendingPathComponent("skills/labelkit/SKILL.md")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, AgentGuide.skill,
                       "regenerate with: swift run labelkit skill > skills/labelkit/SKILL.md")
    }

    /// The Agent Skills specification: `name` is lowercase letters, digits and
    /// single hyphens, at most 64 characters, and equals the folder name;
    /// `description` is 1–1024 characters. Only spec fields are used, so every
    /// client accepts the file.
    func testFrontmatterFollowsTheAgentSkillsSpecification() throws {
        let lines = AgentGuide.skill.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---")
        let end = try XCTUnwrap(lines.dropFirst().firstIndex(of: "---"))
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(parts.count, 2, "unexpected frontmatter line: \(line)")
            fields[parts[0]] = parts[1]
        }
        XCTAssertEqual(Set(fields.keys), ["name", "description"])

        let name = try XCTUnwrap(fields["name"])
        XCTAssertEqual(name, AgentGuide.skillName)
        XCTAssertNotNil(name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression))
        XCTAssertLessThanOrEqual(name.count, 64)

        let description = try XCTUnwrap(fields["description"])
        XCTAssertFalse(description.isEmpty)
        XCTAssertLessThanOrEqual(description.count, 1024)
        XCTAssertLessThan(lines.count, 500, "the spec recommends keeping SKILL.md under 500 lines")
    }

    func testInstallWritesTheSkillIntoItsOwnFolderAndOverwritesAnOldCopy() throws {
        let skills = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-skills-\(UUID().uuidString)/nested/skills")
        defer { try? FileManager.default.removeItem(at: skills.deletingLastPathComponent().deletingLastPathComponent()) }

        let file = try AgentGuide.install(into: skills)
        XCTAssertEqual(file.path, skills.appendingPathComponent("labelkit/SKILL.md").path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), AgentGuide.skill)

        try Data("stale".utf8).write(to: file)
        try AgentGuide.install(into: skills)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), AgentGuide.skill)
    }

    func testBothGuidesEndWithExactlyOneNewline() {
        for text in [AgentGuide.skill, AgentGuide.agentsSnippet] {
            XCTAssertTrue(text.hasSuffix("\n"))
            XCTAssertFalse(text.hasSuffix("\n\n"))
        }
    }

    func testUserSkillDirectoriesCoverTheSharedConventionAndClaudeCode() {
        XCTAssertEqual(AgentGuide.userSkillDirectories, [".agents/skills", ".claude/skills"])
    }
}
