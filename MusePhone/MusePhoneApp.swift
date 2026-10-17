import SwiftUI
import PhotosUI
import UIKit

@main struct MusePhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @State private var state = PhoneState.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneView().environment(state).preferredColorScheme(.dark).tint(Color(red: 0.66, green: 0.24, blue: 0.28))
                .onOpenURL { url in Task { await state.importCredentials(url) } }
                .onChange(of: phase) { _, phase in if phase == .active { state.becameActive() } else if phase == .background { state.becameBackground() } }
                .task { state.becameActive() }
        }
    }
}
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { _ = PhoneState.shared; return true }
}
struct PhoneView: View {
    @Environment(PhoneState.self) private var state
    @State private var setup = false
    @State private var disconnect = false
    @State private var photo: PhotosPickerItem?
    @State private var newChat: RelayChat?
    var body: some View {
        @Bindable var state = state
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        if let image = UIImage(contentsOfFile: state.avatarURL.path) { Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle()) }
                        else { Image("CalAvatar").resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle()) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.museName).font(.title2.bold())
                            Label(state.status, systemImage: state.paired ? "checkmark.shield" : "lock").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    if let error = state.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if state.paired {
                        Label(state.watchReachable ? "Watch connected" : "Watch updates when available", systemImage: "applewatch")
                        Button("Sync Watch & retry connection") { state.becameActive(); state.retryConnection() }.disabled(state.busy)
                    } else { Button("Connect your Muse") { setup = true } }
                }
                if state.paired {
                    Section("Conversations") {
                        Button {
                            newChat = state.createChat()
                        } label: { Label("New chat", systemImage: "plus.bubble") }
                            .accessibilityIdentifier("newChat")
                        ForEach(state.chats) { chat in NavigationLink { PhoneChatView(chat: chat) } label: { Label(chat.title, systemImage: chat.symbol) } }
                    }
                    Section("Your Watch") {
                        TextField("Muse name", text: $state.museName).onSubmit { state.updateProfile() }
                        TextField("Your name", text: $state.personName).onSubmit { state.updateProfile() }
                        Button("Save names") { state.updateProfile() }
                        PhotosPicker(selection: $photo, matching: .images) { Label("Choose your Muse avatar", systemImage: "photo") }
                        Text("Use a picture of your Muse. Avatar changes are sent to your Watch.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Text and voice notes travel through your nearby iPhone to Muse. Recent conversations stay readable on your Watch offline.")
                        Text("You can leave this app on your iPhone’s Home screen. Avoid swiping it away. For a longer reply, reopen it so Muse can keep replying.").foregroundStyle(.secondary)
                        Text("Start a new chat here or on your Watch. Existing conversations stay available. Find saved Watch messages in Settings → Saved messages.").foregroundStyle(.secondary)
                    }.font(.footnote)
                    Section("Connection") {
                        Button("Renew Muse connection") { Task { await state.testRefresh() } }.disabled(state.busy)
                        Button("Disconnect account", role: .destructive) { disconnect = true }.disabled(state.busy)
                    }
                }
            }.navigationTitle("Muse Watch")
            .navigationDestination(item: $newChat) { chat in PhoneChatView(chat: chat) }
            .sheet(isPresented: $setup) { SetupView() }
            .onChange(of: photo) { _, selected in Task {
                do { if let data = try await selected?.loadTransferable(type: Data.self) { try state.chooseAvatar(data) } }
                catch { state.error = error.localizedDescription }
            } }
            .confirmationDialog("Disconnect your Muse account?", isPresented: $disconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await state.disconnectPairing() } }
            } message: { Text("Removes this iPhone’s credentials. You can revoke the gadget in official Muse too. Your local history is kept.") }
        }
    }
}
struct PhoneChatView: View {
    let chat: RelayChat
    @Environment(PhoneState.self) private var state
    @State private var text = ""
    var body: some View {
        List {
            if !state.messages.contains(where: { $0.chatID == chat.id }) {
                Text("Start a new conversation with \(state.museName). You can also send a voice note from your Watch.")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.messages.filter { $0.chatID == chat.id }) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.role == "user" ? "YOU" : state.museName.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    if message.role == "muse" {
                        MuseRichText(text: message.text.isEmpty ? "Replying…" : message.text).textSelection(.enabled)
                    } else { Text(verbatim: message.text).textSelection(.enabled) }
                    if let delivery = message.delivery { Text(delivery.label).font(.caption).foregroundStyle(.secondary) }
                    if let detail = message.detail { Text(detail).font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 5)
            }
        }.navigationTitle(chat.title)
        .safeAreaInset(edge: .bottom) {
            HStack { TextField("Message \(state.museName)", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Send") { state.sendText(text, to: chat.id); text = "" }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().background(.bar)
        }
    }
}
struct SetupView: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                if let error = state.error { Text(error).foregroundStyle(.red) }
                Text(state.status)
                if state.paired { Label("Your Muse is connected", systemImage: "checkmark.shield"); Button("Done") { dismiss() } }
                else {
                    if state.hasCandidate { Button("Retry imported setup") { Task { await state.retrySetup() } }.disabled(state.busy) }
                    Section("1 · Request") {
                        Text("Create a request on this iPhone and AirDrop it to your pairing helper. The Raspberry Pi helper is the verified setup option.")
                        Button("Create a fresh request") { state.createRequest() }.disabled(state.busy)
                        if let url = state.requestURL { ShareLink(item: url) { Label("Share setup request", systemImage: "square.and.arrow.up") } }
                        if let request = state.setupRequest { Text("Expires \(request.expiresAt.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    }
                    Section("2 · Pair & import") {
                        Text("Pair the gadget in official Muse, then return the encrypted .musepair file to this iPhone. The helper is only needed once.")
                        Button("Import encrypted setup") { importing = true }.disabled(state.busy || state.setupRequest == nil)
                    }
                }
            }.navigationTitle("Connect Muse").toolbar { Button("Close") { dismiss() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.musePair, .json]) { result in
                switch result { case .success(let url): Task { await state.importCredentials(url) }; case .failure(let error): state.error = error.localizedDescription }
            }
        }
    }
}
