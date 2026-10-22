import CoreBluetooth

/// Writes sealed motion datagrams to the paired Mac over Bluetooth LE. A datagram that cannot go
/// out right now is held until the write queue drains or its pacing slot comes, replaced by any
/// newer one: each carries the running total, so only the latest matters, but the last one of a
/// stroke must still arrive. Datagrams are sealed at write time, so the one that goes out carries
/// the newest totals.
final class BluetoothMotionSender: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Why motion cannot reach the Mac right now, or nil once the characteristic is writable.
    var onNotice: ((String?) -> Void)?
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic? {
        didSet {
            guard characteristic == nil else { return }
            pending = nil
            paceTimer?.invalidate()
            paceTimer = nil
        }
    }
    /// The newest datagram that found the write queue full or came before its slot.
    private var pending: (() -> Data?)?
    /// Writes go out no closer together than this. Touch samples arrive faster than the link
    /// drains, and every datagram waiting inside CoreBluetooth's queue is pure latency. The queue
    /// only reports full once many are waiting, so it cannot set the pace: measured on an iPhone
    /// to Mac link (≈30 ms connection events, ≥100 datagrams/s), 7.5 ms built a 60+ ms backlog
    /// while 45 ms built none. 15 ms stays well under the link and still lands about two fresh
    /// datagrams in each event.
    private static let spacing: TimeInterval = 0.015
    private var lastWrite: TimeInterval = 0
    private var paceTimer: Timer?
    /// Peripherals whose connection `stop()` cancelled but whose disconnect callback has not
    /// arrived yet. CoreBluetooth reuses one CBPeripheral per device, so a late callback would
    /// otherwise tear down the new link to the same Mac.
    private var cancelling = Set<UUID>()
    /// The Mac's serverID, which it advertises as its local name.
    private var target: String?
    private let service = CBUUID(string: MotionChannel.bluetoothService)
    private let characteristicID = CBUUID(string: MotionChannel.bluetoothCharacteristic)

    /// True while datagrams can be written; otherwise motion should take the Wi-Fi path.
    var isLinked: Bool { peripheral != nil && characteristic != nil }

    func start(serverID: String) {
        target = serverID
        if let manager {
            if manager.state == .poweredOn { onNotice?("正在通过蓝牙连接 Mac…") }
            scan(manager)
        }
        else { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    func stop() {
        target = nil
        manager?.stopScan()
        if let peripheral {
            if peripheral.state != .disconnected { cancelling.insert(peripheral.identifier) }
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        characteristic = nil
    }

    func send(_ datagram: @escaping () -> Data?) {
        guard let peripheral, let characteristic else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = lastWrite + Self.spacing - now
        guard peripheral.canSendWriteWithoutResponse, wait <= 0 else {
            pending = datagram
            if wait > 0, paceTimer == nil {
                // Common modes, so the slot still fires while UIKit is tracking the touch.
                let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.paceTimer = nil
                    if let datagram = self.pending { self.send(datagram) }
                }
                RunLoop.main.add(timer, forMode: .common)
                paceTimer = timer
            }
            return
        }
        pending = nil
        guard let data = datagram(), peripheral.maximumWriteValueLength(for: .withoutResponse) >= data.count else { return }
        lastWrite = now
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, let datagram = pending else { return }
        send(datagram)
    }

    private func scan(_ manager: CBCentralManager) {
        guard target != nil, peripheral == nil, manager.state == .poweredOn else { return }
        // Duplicates on: the local name may only arrive in a later scan response, and a Mac whose
        // previous link is still being torn down must be reported again once it is. Scanning
        // stops as soon as the Mac is found.
        manager.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: onNotice?("正在通过蓝牙连接 Mac…")
        case .poweredOff: onNotice?("蓝牙已关闭，移动和滚动暂走 Wi-Fi，可能不够平稳")
        case .unauthorized: onNotice?("未允许使用蓝牙，移动和滚动暂走 Wi-Fi；可在“设置 > 遥控板”中开启")
        case .unsupported: onNotice?("此设备不支持蓝牙，移动和滚动走 Wi-Fi")
        default: break
        }
        if central.state != .poweredOn {
            peripheral = nil
            characteristic = nil
            cancelling.removeAll()
        }
        scan(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, let target, !cancelling.contains(peripheral.identifier),
              advertisementData[CBAdvertisementDataLocalNameKey] as? String == target else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        linkEnded(peripheral, central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        linkEnded(peripheral, central)
    }

    private func linkEnded(_ ended: CBPeripheral, _ central: CBCentralManager) {
        // A link `stop()` cancelled: the scan still running for the current target rediscovers it.
        if cancelling.remove(ended.identifier) != nil { return }
        guard ended === peripheral else { return }
        peripheral = nil
        characteristic = nil
        if target != nil, central.state == .poweredOn { onNotice?("蓝牙连接中断，移动和滚动暂走 Wi-Fi，正在重连…") }
        scan(central)
    }

    /// Drops a link that cannot carry motion; the disconnect callback then rescans.
    private func abandon(_ peripheral: CBPeripheral) {
        characteristic = nil
        manager?.cancelPeripheralConnection(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let match = peripheral.services?.first(where: { $0.uuid == service }) else {
            abandon(peripheral); return
        }
        peripheral.discoverCharacteristics([characteristicID], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let found = service.characteristics?.first(where: { $0.uuid == characteristicID }) else {
            abandon(peripheral); return
        }
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= MotionPacket.sealedSize else {
            onNotice?("蓝牙连接不支持所需的数据包大小，移动和滚动暂走 Wi-Fi")
            return
        }
        characteristic = found
        onNotice?(nil)
        // Never notified; the subscription is what keeps the Mac from dropping the link as unused.
        if found.properties.contains(.notify) { peripheral.setNotifyValue(true, for: found) }
    }

    /// The Mac re-registers its service when its Bluetooth restarts; find the new one.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral, invalidatedServices.contains(where: { $0.uuid == service }) else { return }
        characteristic = nil
        peripheral.discoverServices([service])
    }
}
