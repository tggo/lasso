import HerdrKit
import SwiftUI

@main
struct CowboyHeroApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("No hosts yet", systemImage: "server.rack",
                                   description: Text("Add a machine running herdr over SSH."))
                .navigationTitle("Cowboy Hero")
        }
    }
}
