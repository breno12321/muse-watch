import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct MuseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var store = MuseStore.shared
    @State private var audio = AudioController()
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(audio)
                .tint(MuseStyle.accent).preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(MuseStore.self) private var store
    @Environment(AudioController.self) private var audio
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack { HomeView() }
        .task { store.refresh() }
        .onChange(of: audio.finishedDraft?.file) { _, _ in
            if let draft = audio.finishedDraft { store.keepDraft(draft); audio.finishedDraft = nil }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                audio.stop(); audio.stopPlayback()
                if let draft = audio.finishedDraft { store.keepDraft(draft); audio.finishedDraft = nil }
                store.persist()
            }
            else { store.refresh() }
        }
        .alert("A little heads-up", isPresented: Binding(get: { store.error != nil || audio.error != nil }, set: { if !$0 { store.error = nil; audio.error = nil } })) {
            Button("OK") { store.error = nil; audio.error = nil }
        } message: { Text(store.error ?? audio.error ?? "") }
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    private var tasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var pendingObservation: NSKeyValueObservation?
    func applicationDidFinishLaunching() {
        _ = MuseStore.shared
        pendingObservation = WCSession.default.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.completePending() }
        }
    }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask { tasks.append(connectivity) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
        completePending()
    }
    private func completePending() {
        guard !WCSession.default.hasContentPending else { return }
        MuseStore.shared.persist()
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }; tasks = []
    }
}
