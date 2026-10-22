import CoreBluetooth

/// The motion path: a write-without-response characteristic the phone writes sealed
/// `MotionPacket`s to. The phone also subscribes to it, though nothing is ever notified: macOS
/// drops a central's link about once a minute as unused unless an app on the Mac holds it, and
/// receiving writes does not count. Writes are not trusted here — `onDatagram` must still open
/// them with the session key. CoreBluetooth calls back on its own queue so each write is
/// timestamped the moment it lands, before it waits behind anything on the main thread; every
/// callback here then hops to main.
final class BluetoothMotionReceiver: NSObject, CBPeripheralManagerDelegate {
    /// A datagram and its arrival time on the uptime clock.
    var onDatagram: ((Data, TimeInterval) -> Void)?
    /// Why the Mac cannot receive Bluetooth motion, or nil once it is advertising.
    var onProblem: ((String?) -> Void)?
    private var manager: CBPeripheralManager?
    private var name = ""
    private let queue = DispatchQueue(label: "BluetoothMotionReceiver", qos: .userInteractive)

    func start(name: String) {
        self.name = name
        if let manager { publish(manager) }
        else { manager = CBPeripheralManager(delegate: self, queue: queue) }
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
    }

    private func publish(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: MotionChannel.bluetoothCharacteristic),
                                                     properties: [.writeWithoutResponse, .notify], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: CBUUID(string: MotionChannel.bluetoothService), primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
    }

    private func report(_ problem: String?) {
        DispatchQueue.main.async { [weak self] in self?.onProblem?(problem) }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self, peripheral === self.manager else { return }
            switch peripheral.state {
            case .poweredOff: self.onProblem?("Mac 蓝牙已关闭，鼠标移动改走 Wi-Fi")
            case .unauthorized: self.onProblem?("未允许使用蓝牙，鼠标移动改走 Wi-Fi；可在系统设置 > 隐私与安全性 > 蓝牙中开启")
            case .unsupported: self.onProblem?("此 Mac 不支持低功耗蓝牙，鼠标移动走 Wi-Fi")
            default: break
            }
            self.publish(peripheral)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, peripheral === self.manager else { return }
            if let error { self.onProblem?("蓝牙服务注册失败，鼠标移动改走 Wi-Fi：\(error.localizedDescription)"); return }
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                         CBAdvertisementDataLocalNameKey: self.name])
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        report(error.map { "蓝牙广播失败，鼠标移动改走 Wi-Fi：\($0.localizedDescription)" })
    }

    /// The phone subscribes once per link, so this is where each link gets tuned.
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        DispatchQueue.main.async { [weak self] in
            guard let self, peripheral === self.manager else { return }
            // Ask for the shortest connection interval; the default is much slower.
            peripheral.setDesiredConnectionLatency(.low, for: central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        let arrival = ProcessInfo.processInfo.systemUptime
        let values = requests.compactMap(\.value)
        DispatchQueue.main.async { [weak self] in
            guard let self, peripheral === self.manager else { return }
            for value in values { self.onDatagram?(value, arrival) }
        }
    }
}
