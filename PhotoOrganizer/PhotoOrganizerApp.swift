import SwiftUI

@main
struct PhotoOrganizerApp: App {
    init() {
        #if DEBUG
        // CI 里带 -PODiag 启动时跑一次缩略图自检；正常启动什么都不做
        DebugSelfCheck.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
