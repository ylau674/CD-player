import CDKit
import SwiftUI

enum AudioLevelsCommand {
    static let shortcut = KeyboardShortcut("l")

    static func title(showsAudioLevels: Bool) -> String {
        showsAudioLevels ? "Hide Audio Levels" : "Show Audio Levels"
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerModel
    let transparency: PanelTransparency
    let appearance: PanelAppearance

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(replacing: .newItem) {
            Button("Insert Demo Disc") {
                Task { await player.insertDemoDisc() }
            }
            .keyboardShortcut("o")
            .disabled(player.isBusy)
            Button("Use Optical Drive") {
                Task { await player.useOpticalDrive() }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!player.opticalDriveSelectionEnabled)
            if !player.opticalSnapshot.drives.isEmpty {
                Menu("Select Optical Drive") {
                    ForEach(player.opticalSnapshot.drives) { drive in
                        Button(drive.name) {
                            Task { await player.useOpticalDrive(id: drive.id) }
                        }
                    }
                }
                .disabled(!player.opticalDriveSelectionEnabled)
            }
            Button("Refresh Optical Drives") { player.refreshOpticalDrives() }
                .disabled(player.isBusy)
        }
        CommandMenu("Playback") {
            Button(player.state == .playing ? "Pause" : "Play") {
                Task { await player.togglePlayback() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!player.controlsEnabled)
            Button("Previous Track") { Task { await player.previousTrack() } }
                .keyboardShortcut(.leftArrow)
                .disabled(!player.controlsEnabled)
            Button("Next Track") { Task { await player.nextTrack() } }
                .keyboardShortcut(.rightArrow)
                .disabled(!player.controlsEnabled)
            Divider()
            Button("Back 10 Seconds") { Task { await player.scan(.backward) } }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .disabled(!player.controlsEnabled)
            Button("Forward 10 Seconds") { Task { await player.scan(.forward) } }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .disabled(!player.controlsEnabled)
            Button(player.stopOrEjectLabel) { Task { await player.stopOrEject() } }
                .keyboardShortcut("e")
                .disabled(!player.stopOrEjectEnabled)
            Divider()
            Toggle("Decode HDCD", isOn: Binding(
                get: { player.isHDCDDecodingEnabled },
                set: { player.setHDCDDecodingEnabled($0) }
            ))
            .help("Decode HDCD packets that enable Peak Extend or gain adjustment when the output carries at least 20 bits. Changes apply at the next Play, track start or seek.")
        }
        CommandMenu("View") {
            Button(AudioLevelsCommand.title(showsAudioLevels: player.showsAudioLevels)) {
                player.toggleAudioLevels()
            }
            .keyboardShortcut(AudioLevelsCommand.shortcut)
            Divider()
            PanelAppearanceCommands(appearance: appearance)
            PanelTransparencyCommands(transparency: transparency)
        }
    }
}

struct PanelAppearanceCommands: View {
    @ObservedObject var appearance: PanelAppearance

    var body: some View {
        Picker("Appearance", selection: Binding(
            get: { appearance.selection },
            set: { appearance.setSelection($0) }
        )) {
            Text("Follow System").tag(PanelAppearance.Selection.system)
            Text("Light").tag(PanelAppearance.Selection.light)
            Text("Dark").tag(PanelAppearance.Selection.dark)
        }
        .pickerStyle(.menu)
        .help("Choose the appearance of the Liquid Glass player window without changing macOS.")
    }
}
