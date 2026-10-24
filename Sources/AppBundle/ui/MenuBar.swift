import Common
import Foundation
import SwiftUI

@MainActor
public func menuBar(viewModel: TrayMenuModel) -> some Scene { // todo should it be converted to "SwiftUI struct"?
    MenuBarExtra(isInserted: Binding(get: { shouldInsertStockMenuBarItem(viewModel) }, set: { _ in })) {
        let shortIdentification = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitShortHash)"
        let identification      = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitHash)"
        Text(shortIdentification)
        Button("Copy to clipboard") { identification.copyToClipboard() }
            .keyboardShortcut("C", modifiers: .command)
        Divider()

        if viewModel.axPermissionStatus == .granted {
            if let token: RunSessionGuard = .isServerEnabled, viewModel.lastReloadConfigContainedWarnings {
                Button {
                    Task.startUnstructured {
                        try await runLightSession(.menuBarButton, token) {
                            let args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []).copy(\.warningsAsErrors, true)
                            _ = await reloadConfig_nonCancellable(args: args)
                        }
                    }
                } label: {
                    Label("Config contains warnings...", systemImage: "exclamationmark.triangle.fill")
                }
                Divider()
            }
            if let token: RunSessionGuard = .isServerEnabled {
                Text("Workspaces:")
                ForEach(viewModel.workspaces, id: \.name) { workspace in
                    Button {
                        Task.startUnstructured {
                            try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: workspace.name).focusWorkspace() }
                        }
                    } label: {
                        Toggle(isOn: .constant(workspace.isFocused)) {
                            Text(workspace.name + workspace.suffix).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                Divider()
            }
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/nikitabobko").orDie())
                viewModel.sponsorshipMessage = sponsorshipPrompts.randomElement().orDie()
            } label: {
                Text("Sponsor AeroSpace on GitHub")
                Text(viewModel.sponsorshipMessage)
            }
            Divider()
            Button(viewModel.isEnabled ? "Disable" : "Enable") { toggleEnabledFromMenu() }.keyboardShortcut("E", modifiers: .command)
            getExperimentalUISettingsMenu(viewModel: viewModel)
            openConfigButton()
            reloadConfigButton(warningsAsErrors: false)
        } else {
            Button("AeroSpace requires accessibility permission to move windows") {
                viewModel.axPermissionStatus = .waitingWithPrompt
            }
        }
        Button("Quit \(aeroSpaceAppName)") { quitFromMenu() }.keyboardShortcut("Q", modifiers: .command)
    } label: {
        switch (viewModel.axPermissionStatus, viewModel.isEnabled) {
            case (.granted, true) where viewModel.menuBarClickable:
                Image(systemName: "rectangle.split.3x1")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case (.granted, true):
                MenuBarLabel().environmentObject(viewModel)
            case (.granted, false):
                Image(systemName: "pause.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case (_, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
        }
    }
}

@MainActor @ViewBuilder
func openConfigButton(showShortcutGroup: Bool = false) -> some View {
    let editor = getTextEditorToOpenConfig()
    let button = Button("Open config in '\(editor.lastPathComponent)'") { openConfigInEditor() }.keyboardShortcut(",", modifiers: .command)
    switch showShortcutGroup {
        case true: shortcutGroup(label: Text("⌘ ,"), content: button)
        case false: button
    }
}

@MainActor @ViewBuilder
func reloadConfigButton(showShortcutGroup: Bool = false, warningsAsErrors: Bool) -> some View {
    if let token: RunSessionGuard = .isServerEnabled {
        let button = Button("Reload config") { reloadConfigFromMenu(token, warningsAsErrors: warningsAsErrors) }.keyboardShortcut("R", modifiers: .command)
        switch showShortcutGroup {
            case true: shortcutGroup(label: Text("⌘ R"), content: button)
            case false: button
        }
    }
}

func shortcutGroup(label: some View, content: some View) -> some View {
    GroupBox {
        VStack(alignment: .trailing, spacing: 6) {
            label
                .foregroundStyle(Color.secondary)
            content
        }
    }
}

func getTextEditorToOpenConfig() -> URL {
    NSWorkspace.shared.urlForApplication(toOpen: findCustomConfigUrl().urlOrNil ?? defaultConfigUrl)?
        .takeIf { $0.lastPathComponent != "Xcode.app" } // Blacklist Xcode. It is too heavy to open plain text files
        ?? URL(filePath: "/System/Applications/TextEdit.app")
}

// Actions shared by the stock menu and the clickable workspace bar menu (ClickableWorkspaceBar.swift)

@MainActor func openConfigInEditor() {
    let editor = getTextEditorToOpenConfig()
    let fallbackConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
    switch findCustomConfigUrl() {
        case .file(let url):
            url.open(with: editor)
        case .noCustomConfigExists:
            _ = try? FileManager.default.copyItem(atPath: defaultConfigUrl.path, toPath: fallbackConfig.path)
            fallbackConfig.open(with: editor)
        case .ambiguousConfigError:
            fallbackConfig.open(with: editor)
    }
}

@MainActor func reloadConfigFromMenu(_ token: RunSessionGuard, warningsAsErrors: Bool = false) {
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) {
            let args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []).copy(\.warningsAsErrors, warningsAsErrors)
            _ = await reloadConfig_nonCancellable(args: args)
        }
    }
}

@MainActor func toggleEnabledFromMenu() {
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, .forceRun) {
            _ = await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: .toggle))
                .run(.defaultEnv, .emptyStdin)
        }
    }
}

@MainActor func quitFromMenu() {
    lifecycleLog("QUIT requested from a menu")
    Task.startUnstructured {
        terminationHandler?.beforeTermination()
        terminateApp()
    }
}

@MainActor func shouldInsertStockMenuBarItem(_ m: TrayMenuModel) -> Bool {
    stockMenuBarItemVisible(
        clickable: m.menuBarClickable, hideStock: m.menuBarHideStockItem, axGranted: m.axPermissionStatus == .granted,
        enabled: m.isEnabled, pillsInstalled: m.pillsInstalled,
    )
}

/// The stock item is hidden only while the pills are really shown; in every other case it is the fallback
/// (no Accessibility permission, disabled, clickable off, pill item not installed): there is always one item.
func stockMenuBarItemVisible(clickable: Bool, hideStock: Bool, axGranted: Bool, enabled: Bool, pillsInstalled: Bool) -> Bool {
    !(hideStock && clickable && axGranted && enabled && pillsInstalled)
}
