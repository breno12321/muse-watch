import Foundation
import CoreBluetooth
import Network
import Observation

@MainActor @Observable
final class BLEPairer: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    private(set) var status = "Import the setup request from your iPhone."
    private(set) var advertising = false
    private(set) var credentials: DeviceCredentials?
    private(set) var error: String?
    private var manager: CBPeripheralManager?
    private var tx: CBMutableCharacteristic?
    private var central: CBCentral?
    private var packets: [Data] = []
    private let assembler = BLEChunks()
    private var pairing: PairingV5?
    private var token = ""
    private var windowTask: Task<Void, Never>?
    private var provisioningTask: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var online = false
    private var blockedPlaintext = false
    private let serviceID = CBUUID(string: "7fdd3d1c-38ea-46cf-8b46-314ecf5f240c")
    private let rxID = CBUUID(string: "4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01")
    private let txID = CBUUID(string: "d75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c")

    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.online = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "MuseSetup.network"))
    }
    func start(sdkToken: String, request: SetupRequest) throws {
        try request.validate()
        let trimmed = sdkToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mgst_"), trimmed.count <= 2048 else { throw MuseError.invalid("Enter an SDK token beginning with mgst_.") }
        stop(); error = nil; token = trimmed
        let identity = try GadgetIdentity.generate()
        pairing = PairingV5(identity: identity, sdkToken: trimmed)
        status = "Preparing Bluetooth…"
        manager = CBPeripheralManager(delegate: self, queue: .main)
        windowTask = Task { [weak self] in
            let remaining = max(0, min(600, request.expiresAt.timeIntervalSinceNow))
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }; self?.stop(); self?.status = "Setup window expired. Create a new request on your iPhone."
        }
    }
    func stop() {
        windowTask?.cancel(); windowTask = nil; provisioningTask?.cancel(); provisioningTask = nil
        manager?.stopAdvertising(); manager?.removeAllServices(); manager?.delegate = nil; manager = nil
        pairing?.reset(); pairing = nil; token = ""; packets = []; assembler.reset(); tx = nil; central = nil
        advertising = false; blockedPlaintext = false; credentials = nil
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let rx = CBMutableCharacteristic(type: rxID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
            let tx = CBMutableCharacteristic(type: txID, properties: [.read, .notify], value: nil, permissions: [.readable]); self.tx = tx
            let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [rx, tx]; peripheral.add(service)
        case .unauthorized: error = "Allow Bluetooth for Muse Setup in System Settings → Privacy & Security → Bluetooth."; status = "Bluetooth permission needed."
        case .poweredOff: status = "Turn on Bluetooth on this Mac."
        case .unsupported: error = "This Mac does not support Bluetooth peripheral advertising."
        default: status = "Waiting for Bluetooth…"
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, let pairing else { self.error = "Couldn’t publish the Muse pairing service."; return }
        // CoreBluetooth only permits local name and service UUIDs here. The SDK's
        // optional Linux manufacturer-data advertisement cannot be reproduced on macOS.
        // Official-app discovery is therefore an explicit physical compatibility gate.
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: pairing.identity.bluetoothName, CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard error == nil else { self.error = "Bluetooth advertising failed. Stop setup and try again."; return }
        advertising = true; status = "In Muse on your iPhone, add \(pairing?.identity.bluetoothName ?? "this gadget")."
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == txID, self.central == nil || self.central?.identifier == central.identifier else { return }
        self.central = central; drain()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard self.central?.identifier == central.identifier else { return }
        self.central = nil; pairing?.reset(); blockedPlaintext = false; packets = []; assembler.reset()
        provisioningTask?.cancel(); provisioningTask = nil
        if credentials == nil { status = "Phone disconnected. Try adding the gadget again." }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { drain() }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == txID, request.offset == 0 else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = Data(); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard central?.identifier == first.central.identifier,
              requests.allSatisfy({ $0.central.identifier == first.central.identifier }) else { peripheral.respond(to: first, withResult: .insufficientAuthorization); return }
        guard requests.allSatisfy({ $0.characteristic.uuid == rxID && $0.offset == 0 && $0.value != nil }) else { peripheral.respond(to: first, withResult: .requestNotSupported); return }
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            do { if let value = try assembler.feed(request.value ?? Data()) { try handle(jsonObject(value), encrypted: false) } }
            catch { handleProtocolFailure(error) }
        }
    }
    private func handleProtocolFailure(_ error: Error) {
        self.error = (error as? MuseError)?.localizedDescription ?? "Pairing failed. Stop setup and try again."
        if let pairing, pairing.state != .idle { try? send(pairing.status("error_pairing_decrypt")) }
        else { try? send(["type": "status", "status": "error_pairing_decrypt"]) }
        pairing?.reset(); packets = []; assembler.reset(); blockedPlaintext = true
    }
    private func handle(_ command: [String: Any], encrypted: Bool) throws {
        guard let pairing, credentials == nil else { return }
        let action = command["action"] as? String ?? ""
        if !encrypted, action == "pairing_client_hello" {
            provisioningTask?.cancel(); packets = []
            let ready = try pairing.hello(command); blockedPlaintext = true
            try send(ready); status = "Muse is confirming the encrypted pairing."; return
        }
        if !encrypted, action == "pairing_encrypted" { try handle(pairing.decrypt(command), encrypted: true); return }
        if action == "get_device_info" {
            var info = pairing.deviceInfo; info["network_ready"] = online; try send(info); return
        }
        if !encrypted {
            if !blockedPlaintext { try send(["type": "status", "status": "error_encryption_required"]) }; return
        }
        if action == "pairing_client_finished" { try pairing.confirm(command); try send(pairing.status("pairing_confirmed")); return }
        guard pairing.state == .ready || pairing.state == .provisioning else { try send(pairing.status("error_pairing_confirm_required")); return }
        if action == "wifi_scan" {
            let networks: [[String: Any]] = online ? [["ssid": "Mac internet (already connected)", "rssi": -40, "secure": false]] : []
            try send(pairing.encrypt(["type": "wifi_scan_result", "networks": networks])); return
        }
        if action == "provision_v2" {
            guard provisioningTask == nil else { try send(pairing.status("error_operation_in_progress")); return }
            guard command["ssid"] is String, command["password"] is String else { try send(pairing.status("error_missing_credentials")); return }
            let credentials = try DeviceCredentials(identity: pairing.identity, sdkToken: token, provision: command)
            let generation = try pairing.beginProvisioning()
            try send(pairing.status("wifi_connecting"))
            guard online else { try send(pairing.status("wifi_failed")); return }
            try send(pairing.status("wifi_connected")); status = "Checking the paired Muse credentials…"
            provisioningTask = Task { [weak self] in
                do {
                    _ = try await MuseAPI.fetchVMs(credentials); try Task.checkCancellation()
                    guard let self, self.pairing === pairing, pairing.validProvisioning(generation) else { return }
                    try self.send(pairing.status("auth_ok")); self.credentials = credentials
                    self.manager?.stopAdvertising(); self.advertising = false
                    self.status = "Paired. Export the encrypted setup file to your iPhone."
                } catch {
                    guard let self, self.pairing === pairing, pairing.validProvisioning(generation), !Task.isCancelled else { return }
                    try? self.send(pairing.status("auth_failed"))
                    self.error = "Muse credential validation failed. Pairing has not been marked successful."
                    self.status = "Stop setup and try again."
                }
            }
            return
        }
        try send(pairing.status("error_unknown_action"))
    }
    private func send(_ value: [String: Any]) throws {
        guard packets.count < 512 else { throw MuseError.invalid("Bluetooth notification queue is full.") }
        packets += try BLEChunks.encode(jsonData(value), maximumPacket: central?.maximumUpdateValueLength ?? 20)
        drain()
    }
    private func drain() {
        guard let manager, let tx, let central else { return }
        while let packet = packets.first {
            guard manager.updateValue(packet, for: tx, onSubscribedCentrals: [central]) else { return }
            packets.removeFirst()
        }
    }
}
