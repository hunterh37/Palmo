import SwiftUI

/// A macOS app that watches your webcam for an open palm held up to the
/// camera. When it sees one, a command orb descends from the top of the
/// frame and pops out into a 3D radial menu of orbs, one per app. Pinch an
/// orb to open that app. Make a fist (or drop your hand) to dismiss.
@main
struct HandOrbMenuApp: App {
    @StateObject private var model = HandMenuModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Hand Orb Menu", systemImage: "hand.raised.circle.fill") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
