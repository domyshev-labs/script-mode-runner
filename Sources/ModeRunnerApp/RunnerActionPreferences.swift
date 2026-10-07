import Foundation
import SwiftUI

@MainActor
final class RunnerActionPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var showConfirmation: Bool {
        didSet { defaults.set(showConfirmation, forKey: "runner.showExitConfirmation") }
    }
    @Published var savedTerminateProcesses: Bool {
        didSet { defaults.set(savedTerminateProcesses, forKey: "runner.terminateProcessesOnExit") }
    }
    @Published var pendingAction: RunnerAction?
    @Published var terminateProcesses = false
    @Published var rememberChoice = false
    private var confirmedAction: RunnerAction?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showConfirmation = defaults.object(forKey: "runner.showExitConfirmation") as? Bool ?? true
        savedTerminateProcesses = defaults.bool(forKey: "runner.terminateProcessesOnExit")
    }

    func request(_ action: RunnerAction, perform: (RunnerAction, Bool) -> Void) {
        guard pendingAction == nil, confirmedAction == nil else { return }
        if showConfirmation {
            terminateProcesses = savedTerminateProcesses
            rememberChoice = false
            pendingAction = action
        } else {
            perform(action, savedTerminateProcesses)
        }
    }

    func confirm(_ action: RunnerAction) {
        guard pendingAction == action else { return }
        if rememberChoice {
            savedTerminateProcesses = terminateProcesses
            showConfirmation = false
        }
        confirmedAction = action
        pendingAction = nil
    }

    func finishConfirmation(perform: (RunnerAction, Bool) -> Void) {
        guard let action = confirmedAction else { return }
        confirmedAction = nil
        perform(action, terminateProcesses)
    }
}

struct RunnerSettingsView: View {
    @ObservedObject var preferences: RunnerActionPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quit and restart").font(.title2.bold())
            Toggle("Ask for confirmation", isOn: $preferences.showConfirmation)
                .toggleStyle(.checkbox)
            Toggle("Terminate processes", isOn: $preferences.savedTerminateProcesses)
                .toggleStyle(.checkbox)
            Text("Applies to both Quit and Quit&Start. When confirmation is disabled, the saved process choice is used automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
