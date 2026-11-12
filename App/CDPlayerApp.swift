import AppKit
import CDKit
import SwiftUI

@main
struct CDPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                PlayerCommands(
                    player: appDelegate.player, transparency: appDelegate.transparency,
                    appearance: appDelegate.appearance
                )
            }
    }
}
