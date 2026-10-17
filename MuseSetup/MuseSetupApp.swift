import SwiftUI
import AppKit

@main struct MuseSetupApp: App {
    var body: some Scene { WindowGroup("Muse Watch Setup") { SetupView() }.defaultSize(width: 620, height: 610) }
}
struct SetupView: View {
    @State private var pairer = BLEPairer()
    @State private var request: SetupRequest?
    @State private var token = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: SetupFile?
    @State private var error: String?
    @State private var exported = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Muse Watch Setup", systemImage: "applewatch").font(.largeTitle.bold())
            Text("Connect once. Then your iPhone handles Muse for your Watch.").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1 · Import the iPhone setup request").font(.headline)
                    Text("In Muse Phone, create a request and AirDrop it to this Mac. Open the .muserequest file here.")
                    Button(request == nil ? "Import setup request…" : "Replace setup request…") { importing = true }.disabled(pairer.advertising || pairer.credentials != nil)
                    if let request { Text("Request expires \(request.expiresAt.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("2 · Pair using the official Muse app").font(.headline)
                    Text("Muse SDK token (mgst_…)").font(.caption).foregroundStyle(.secondary)
                    SecureField("", text: $token).textFieldStyle(.roundedBorder).disabled(pairer.advertising || pairer.credentials != nil)
                    Link("Get an SDK token from Muse", destination: URL(string: "https://gadgets.muse.ai/settings/sdk-tokens")!)
                    Text("In Muse on iPhone: Settings → Devices → Developer mode → Add Device. Select the MuseGadget name shown below. Accept Muse’s SDK terms yourself before using the token.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Start pairing") { start() }.disabled(request == nil || token.isEmpty || pairer.advertising || pairer.credentials != nil)
                        Button("Stop") { pairer.stop(); token = "" }.disabled(!pairer.advertising && pairer.credentials == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Label(exported ? "Encrypted setup exported. AirDrop it to your iPhone, then quit this helper." : pairer.status, systemImage: exported ? "checkmark.circle" : "antenna.radiowaves.left.and.right").font(.callout).textSelection(.enabled)
            if let message = error ?? pairer.error { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Button("3 · Export encrypted setup file…") { prepareExport() }.disabled(pairer.credentials == nil)
            Text("AirDrop the exported .musepair file back to your iPhone and import it in Muse Phone. This is a protocol compatibility test; live account access is confirmed only on the phone.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(minWidth: 580, minHeight: 600)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.museRequest, .json]) { result in
            do { try load(result.get()) } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .musePair, defaultFilename: "MuseWatch.musepair") { result in
            switch result {
            case .success:
                pairer.stop(); token = ""; exportFile = nil; exported = true
                error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .onOpenURL { url in do { try load(url) } catch { self.error = error.localizedDescription } }
    }
    private func load(_ url: URL) throws {
        guard !pairer.advertising, pairer.credentials == nil else { throw MuseError.invalid("Stop the current setup before replacing its request.") }
        let value = try JSONDecoder().decode(SetupRequest.self, from: readSetupFile(url)); try value.validate()
        request = value; exported = false; error = nil
    }
    private func start() {
        guard let request else { return }
        do { try pairer.start(sdkToken: token, request: request); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func prepareExport() {
        guard let request, let credentials = pairer.credentials else { return }
        do { exportFile = SetupFile(data: try JSONEncoder().encode(SetupEnvelope.seal(credentials, for: request))); exporting = true }
        catch { self.error = error.localizedDescription }
    }
}
