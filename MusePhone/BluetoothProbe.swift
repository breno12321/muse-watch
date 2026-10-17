import SwiftUI
import CoreBluetooth
import Observation

@MainActor @Observable
final class BluetoothProbe: NSObject, @preconcurrency CBCentralManagerDelegate {
    struct Finding: Identifiable {
        let id: UUID
        var name: String
        var signal: Int
        var services: [String]
        var pairedFlag: String
    }
    private(set) var status = "Start a 20-second scan while the Mac helper is pairing."
    private(set) var scanning = false
    private(set) var findings: [Finding] = []
    private(set) var nearbyCount = 0
    private var manager: CBCentralManager?
    private var seen: Set<UUID> = []
    private var timeout: Task<Void, Never>?
    private var requested = false
    private let museService = "7FDD3D1C-38EA-46CF-8B46-314ECF5F240C"

    func start() {
        stop(); findings = []; seen = []; nearbyCount = 0; requested = true
        status = "Waiting for Bluetooth permission…"
        if let manager { beginIfReady(manager) }
        else { manager = CBCentralManager(delegate: self, queue: .main) }
    }
    func stop() {
        timeout?.cancel(); timeout = nil; requested = false
        manager?.stopScan(); scanning = false
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { beginIfReady(central) }
    private func beginIfReady(_ central: CBCentralManager) {
        guard requested else { return }
        switch central.state {
        case .poweredOn:
            guard !scanning else { return }
            scanning = true; status = "Scanning nearby advertisements…"
            // No service filter: this also detects a gadget whose service UUID is
            // missing, shortened, or placed in Apple's overflow advertisement.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                self.stop()
                self.status = self.findings.isEmpty ? "No Muse gadget received. Saw \(self.nearbyCount) nearby Bluetooth devices." : "Received \(self.findings.count) Muse gadget advertisement(s)."
            }
        case .unauthorized: status = "Allow Bluetooth for Muse Phone in iPhone Settings → Privacy & Security → Bluetooth."; stop()
        case .poweredOff: status = "Turn on iPhone Bluetooth, then scan again."; stop()
        case .unsupported: status = "Bluetooth scanning is unavailable on this device."; stop()
        case .resetting: status = "Bluetooth is restarting…"
        default: break
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        if seen.count < 1024 { seen.insert(peripheral.identifier); nearbyCount = seen.count }
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])).map { $0.uuidString.uppercased() }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed gadget"
        guard name.lowercased().hasPrefix("musegad") || services.contains(museService) else { return }
        record(peripheral.identifier, name: name, services: services, data: advertisementData, signal: RSSI.intValue)
    }
    private func record(_ id: UUID, name: String, services: [String], data: [String: Any], signal: Int) {
        let manufacturer = [UInt8](data[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        let flag: String
        if manufacturer.count >= 3, manufacturer[0] == 0xff, manufacturer[1] == 0xff {
            flag = String(format: "SDK flag present: 0x%02X", manufacturer[2])
        } else { flag = "SDK manufacturer flag absent" }
        let finding = Finding(id: id, name: name, signal: signal, services: services, pairedFlag: flag)
        if let index = findings.firstIndex(where: { $0.id == id }) {
            let previous = findings[index]
            findings[index] = Finding(id: id, name: name.count >= previous.name.count ? name : previous.name,
                signal: signal, services: Array(Set(previous.services + services)).sorted(),
                pairedFlag: flag.hasPrefix("SDK flag present") ? flag : previous.pairedFlag)
        }
        else if findings.count < 16 { findings.append(finding) }
    }
}

struct BluetoothProbeView: View {
    @State private var probe = BluetoothProbe()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Checks what this iPhone receives from your Mac. It does not connect, pair, or send account credentials.")
                    Text(probe.status).font(.callout)
                    Button(probe.scanning ? "Stop scan" : "Start Bluetooth check") {
                        if probe.scanning { probe.stop() } else { probe.start() }
                    }
                    Text("Nearby devices seen: \(probe.nearbyCount)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(probe.findings) { finding in
                    Section(finding.name) {
                        Text("Signal: \(finding.signal) dBm")
                        Text(finding.pairedFlag)
                        Text(finding.services.isEmpty ? "No service UUID received" : finding.services.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section {
                    Text("Keep Muse Setup open on the Mac with pairing active. If its setup window expired, create a fresh request before trying again. Only Muse gadget details are shown; other nearby devices are counted without displaying their names.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Bluetooth check")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onDisappear { probe.stop() }
        .onChange(of: phase) { _, phase in if phase == .background { probe.stop() } }
    }
}
