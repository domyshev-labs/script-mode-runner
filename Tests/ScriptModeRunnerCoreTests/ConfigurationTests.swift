import Foundation
import Testing
@testable import ScriptModeRunnerCore

@Test func decodesBothCommandFormsAndDefaults() throws {
    let yaml = """
    tabs:
      - id: dev
        title: Development
        buttons:
          - id: all
            title: All
            on_deactivate:
              sigint: true
              timeout: 250ms
            scripts:
              - id: shell
                title: Shell
                command: yarn dev
              - id: direct
                title: Direct
                executable: /bin/echo
                arguments: [hello]
    """
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let config = try ConfigurationLoader().load(from: url)
    #expect(config.tabs[0].buttons[0].scripts.count == 2)
    #expect(config.tabs[0].buttons[0].onDeactivate.timeout.seconds == 0.25)
    #expect(config.tabs[0].buttons[0].onDeactivate.sigkill == false)
    #expect(config.tabs[0].buttons[0].scripts[0].launchSpec().executable == "/bin/zsh")
}

@Test func rejectsDuplicateIDs() throws {
    let script = RunnerScript(id: "echo", title: "Echo", executable: "/bin/echo")
    let config = RunnerConfiguration(tabs: [
        RunnerTab(id: "same", title: "One", buttons: [RunnerMode(id: "mode", title: "Mode", scripts: [script])]),
        RunnerTab(id: "same", title: "Two", buttons: []),
    ])
    #expect(throws: ConfigurationError.duplicateID(kind: "tab", id: "same")) {
        try config.validated()
    }
}
