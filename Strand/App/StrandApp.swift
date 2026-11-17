import SwiftUI

/// macOS target exists to host StrandTests. Band is iOS-only.
@main
struct StrandApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Band test host")
                .padding()
                .frame(minWidth: 320, minHeight: 200)
        }
    }
}
