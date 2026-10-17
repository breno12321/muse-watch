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
    @State private var newChat: RelayChat?
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let image = UIImage(contentsOfFile: state.avatarURL.path) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle())
                        } else { Image("CalAvatar").resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle()) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.museName).font(.title2.bold())
                            Text(state.paired ? (state.watchReachable ? "Watch connected" : "Ready for your Watch") : "Connect your Muse")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                    if !state.paired {
                        Button("Connect your Muse") { setup = true }
                    } else if !state.transcriptionAuthorized || state.blockedVoiceNotes > 0 {
                        Button { settings = true } label: {
                            Label(state.transcriptionAuthorized ? "Voice note needs attention" : "Enable voice transcription", systemImage: "waveform.badge.mic")
                        }.foregroundStyle(.orange)
                    } else if state.error != nil {
                        Button { settings = true } label: {
                            Label("Connection needs attention", systemImage: "exclamationmark.circle")
                        }.foregroundStyle(.orange)
                    }
                }
                if state.paired {
                    Section("Chats") {
                        Button { newChat = state.createChat() } label: { Label("New chat", systemImage: "plus.bubble") }
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("newChat")
                            .listRowBackground(chatBackground).listRowSeparator(.hidden)
                        ForEach(state.visibleChats) { chat in
                            NavigationLink { PhoneChatView(chat: chat) } label: {
                                Label(chat.displayTitle, systemImage: chat.symbol).padding(.vertical, 6)
                            }.listRowBackground(chatBackground).listRowSeparator(.hidden)
                        }
                    }
                }
            }.listStyle(.insetGrouped).listRowSpacing(8)
            .navigationTitle("Muse Watch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(.white)
                    }.accessibilityLabel("Settings").accessibilityIdentifier("phoneSettings")
                }
            }
            .navigationDestination(item: $newChat) { chat in PhoneChatView(chat: chat) }
            .navigationDestination(isPresented: $settings) { PhoneSettingsView() }
            .sheet(isPresented: $setup) { SetupView() }
        }
    }
    private var chatBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
struct PhoneSettingsView: View {
    @Environment(PhoneState.self) private var state
    @State private var setup = false
    @State private var disconnect = false
    @State private var photo: PhotosPickerItem?
    @State private var earlierChats = false
    var body: some View {
        @Bindable var state = state
        Form {
            Section("Connection") {
                Label(state.status, systemImage: state.paired ? "checkmark.shield" : "lock")
                if let error = state.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if state.unavailableReplyCount > 0 {
                    Text("Some earlier replies can’t be reopened. Read them in Muse. They won’t be resent or retried automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.paired {
                    Label(state.watchReachable ? "Watch connected" : "Watch updates when available", systemImage: "applewatch")
                    Button("Sync Watch & retry connection") { state.becameActive(); state.retryConnection() }.disabled(state.busy)
                    Button("Check Muse connection") { Task { await state.testConnection() } }.disabled(state.busy)
                    Button("Renew Muse connection") { Task { await state.testRefresh() } }.disabled(state.busy)
                } else { Button("Connect your Muse") { setup = true } }
            }
            if state.paired {
                Section("Voice notes") {
                    Text("Your iPhone transcribes recordings locally. Only the text is sent to Muse. Saved voice replies stay playable on Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Voice language", selection: $state.transcriptionLocale) {
                        // Include the current preference even if this device no longer supports its locale.
                        let locales = Set(VoiceTranscriber.locales.map(\.identifier) + [state.transcriptionLocale]).sorted()
                        ForEach(locales, id: \.self) { identifier in
                            Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                        }
                    }.disabled(state.busy).onChange(of: state.transcriptionLocale) { _, _ in state.saveTranscriptionLocale() }
                    if state.transcriptionAuthorized {
                        Label("Speech Recognition allowed", systemImage: "checkmark.circle")
                    } else if state.transcriptionPermissionDenied {
                        Button("Allow Speech Recognition in iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    } else {
                        Button("Enable transcription") { Task { await state.enableTranscription() } }
                    }
                    if state.blockedVoiceNotes > 0 {
                        Text("\(state.blockedVoiceNotes) saved voice note(s) waiting. Nothing was sent for these notes.").font(.caption)
                        Button("Retry saved voice notes") { state.retryVoiceNotes() }.disabled(state.busy || !state.transcriptionAuthorized)
                    }
                    Text("Your voice notes are transcribed on iPhone. Muse replies in text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Your Muse") {
                    TextField("Muse name", text: $state.museName).onSubmit { state.updateProfile() }
                    TextField("Your name", text: $state.personName).onSubmit { state.updateProfile() }
                    Button("Save names") { state.updateProfile() }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose your Muse avatar", systemImage: "photo") }
                }
                if !state.earlierChats.isEmpty {
                    Section {
                        Button { earlierChats = true } label: { Label("Earlier chats", systemImage: "archivebox") }
                        Text("Conversations from the earlier prototype are kept here. Rename one to return it to your main chats.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("Voice notes from Watch use your iPhone’s internet. You can leave this app on the Home screen; avoid swiping it away. Open it for longer replies.")
                Text("Create independent chats on either device. Saved Watch messages are under Watch Settings → Saved messages.")
            }.font(.footnote).foregroundStyle(.secondary)
            if state.paired {
                Section {
                    Button("Disconnect account", role: .destructive) { disconnect = true }.disabled(state.busy)
                }
            }
        }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $earlierChats) { EarlierChatsView() }
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
struct EarlierChatsView: View {
    @Environment(PhoneState.self) private var state
    var body: some View {
        List(state.earlierChats) { chat in
            NavigationLink { PhoneChatView(chat: chat) } label: { Label(chat.displayTitle, systemImage: chat.symbol) }
        }.navigationTitle("Earlier chats").navigationBarTitleDisplayMode(.inline)
    }
}
struct PhoneChatView: View {
    let chat: RelayChat
    @Environment(PhoneState.self) private var state
    @State private var text = ""
    @State private var renaming: RelayChat?
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
                    if let detail = message.detail, message.role == "user" { Text(detail).font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 5)
            }
        }.navigationTitle(state.chats.first(where: { $0.id == chat.id })?.displayTitle ?? chat.displayTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") {
                    renaming = state.chats.first(where: { $0.id == chat.id }) ?? chat
                }.foregroundStyle(.white)
                    .accessibilityLabel("Edit chat name").accessibilityIdentifier("editChatName")
            }
        }
        .sheet(item: $renaming) { value in RenameChatView(chat: value) }
        .safeAreaInset(edge: .bottom) {
            HStack { TextField("Message \(state.museName)", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Send") { state.sendText(text, to: chat.id); text = "" }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().background(.bar)
        }
    }
}
struct RenameChatView: View {
    let chat: RelayChat
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    init(chat: RelayChat) { self.chat = chat; _title = State(initialValue: chat.displayTitle) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Chat name", text: $title).autocorrectionDisabled().onSubmit { save() }
                    .accessibilityIdentifier("chatNameField")
                Text("Saved on this iPhone and synced to your Watch. Your name takes priority over Muse’s topic.")
                    .font(.caption).foregroundStyle(.secondary)
                if chat.customTitle != nil {
                    Button(chat.serverTitle == nil ? "Use default name" : "Use Muse topic") {
                        if state.renameChat(chat.id, title: nil) { dismiss() }
                    }
                }
            }.navigationTitle("Chat name").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 80)
                }
            }
        }
    }
    private func save() { if state.renameChat(chat.id, title: title) { dismiss() } }
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
