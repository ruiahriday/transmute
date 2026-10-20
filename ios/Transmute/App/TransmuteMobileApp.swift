import SwiftUI

@main
struct TransmuteMobileApp: App {
    @StateObject private var queue = JobQueue.shared
    @StateObject private var library = Library.shared

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(queue)
                .environmentObject(library)
                .onOpenURL { library.open($0) }
        }
    }
}

/// The home screen, or the headless self-test and screenshot modes the build server uses.
struct RootView: View {
    @State private var testOutput: String?

    var body: some View {
        if let testOutput {
            ScrollView { Text(testOutput).font(.caption.monospaced()).padding() }
        } else {
            HomeView()
                .task { await startAutomation() }
        }
    }

    private func startAutomation() async {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--selftest"), flag + 1 < args.count {
            testOutput = "Running the self-test…"
            let failures = await IOSSelfTest.run(inputDir: Automation.folder(args[flag + 1]))
            exit(failures == 0 ? 0 : 1)
        }
        if let flag = args.firstIndex(of: "--demo"), flag + 1 < args.count {
            await Automation.demo(Automation.folder(args[flag + 1]), screen: Automation.value(after: "--screen", in: args))
        }
    }
}
