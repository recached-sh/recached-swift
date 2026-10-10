import Recached
import SwiftUI

@main
struct RecachedDemoApp: App {
    @StateObject private var checklist = Checklist.open()

    var body: some Scene {
        WindowGroup { ContentView(checklist: checklist) }
    }
}
