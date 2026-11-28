import ArgumentParser
import Foundation
import LabelKit

/// `labelkit skill` — hand an AI agent its instructions for using labelkit.
/// The guide is compiled in, so it always matches this version's commands.
struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Print or install the guide that teaches an AI agent to use labelkit.",
        discussion: """
        With no options, prints the guide (an Agent Skill, SKILL.md) to stdout.

        Examples:
          labelkit skill                     # read it
          labelkit skill --install           # for every agent client, for your user
          labelkit skill --install --project # for this project only (commit it)
          labelkit skill --install --dir ~/.config/opencode/skills
          labelkit skill --snippet >> AGENTS.md

        --install writes labelkit/SKILL.md into the two places agent clients
        look: .agents/skills (Codex, Cursor, opencode, Gemini CLI, GitHub
        Copilot, Amp, Goose and others) and .claude/skills (Claude Code) —
        under your home directory, or under the current directory with
        --project. Re-run it after upgrading labelkit to refresh the guide.

        --snippet prints a few lines for a project's AGENTS.md instead: enough
        for any agent that can run shell commands, with or without skills.
        """)

    @Flag(name: .long, help: "Install the skill where agent clients look for skills.")
    var install = false

    @Flag(name: .long, help: "With --install: install into the current directory instead of your home directory.")
    var project = false

    @Option(name: .long, help: "With --install: install into this skills directory only.")
    var dir: String?

    @Flag(name: .long, help: "Print a short AGENTS.md snippet instead of the full skill.")
    var snippet = false

    func validate() throws {
        if !install, project || dir != nil {
            throw ValidationError("--project and --dir only apply with --install.")
        }
        if install, snippet {
            throw ValidationError("Use either --install or --snippet, not both.")
        }
        if project, dir != nil {
            throw ValidationError("Use either --project or --dir, not both.")
        }
    }

    func run() throws {
        guard install else {
            print(snippet ? AgentGuide.agentsSnippet : AgentGuide.skill, terminator: "")
            return
        }

        let targets: [URL]
        if let dir {
            targets = [URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)]
        } else {
            let base = project
                ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                : FileManager.default.homeDirectoryForCurrentUser
            targets = AgentGuide.userSkillDirectories.map { base.appendingPathComponent($0) }
        }

        var failed = false
        for target in targets {
            do {
                print(try AgentGuide.install(into: target).path)
            } catch {
                Headless.note("couldn't install into \(target.path): \(Headless.describe(error))")
                failed = true
            }
        }
        if failed { throw ExitCode(1) }
    }
}
