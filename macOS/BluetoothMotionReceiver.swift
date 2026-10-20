import CoreBluetooth

/// The motion path: a write-without-response characteristic the phone writes sealed
/// `MotionPacket`s to. Writes are not trusted here — `onDatagram` must still open them with the
/// session key.
final class BluetoothMotionReceiver: NSObject, CBPeripheralManagerDelegate {
    var onDatagram: ((Data) -> Void)?
    /// Why the Mac cannot receive Bluetooth motion, or nil once it is advertising.
    var onProblem: ((String?) -> Void)?
    private var manager: CBPeripheralManager?
    private var name = ""
    private var tunedCentrals = Set<UUID>()

    func start(name: String) {
        self.name = name
        if let manager { publish(manager) }
        else { manager = CBPeripheralManager(delegate: self, queue: .main) }
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        tunedCentrals.removeAll()
    }

    private func publish(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: MotionChannel.bluetoothCharacteristic),
                                                     properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: CBUUID(string: MotionChannel.bluetoothService), primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOff: onProblem?("Mac 蓝牙已关闭，鼠标移动改走 Wi-Fi")
        case .unauthorized: onProblem?("未允许使用蓝牙，鼠标移动改走 Wi-Fi；可在系统设置 > 隐私与安全性 > 蓝牙中开启")
        case .unsupported: onProblem?("此 Mac 不支持低功耗蓝牙，鼠标移动走 Wi-Fi")
        default: break
        }
        publish(peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { onProblem?("蓝牙服务注册失败，鼠标移动改走 Wi-Fi：\(error.localizedDescription)"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                     CBAdvertisementDataLocalNameKey: name])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onProblem?(error.map { "蓝牙广播失败，鼠标移动改走 Wi-Fi：\($0.localizedDescription)" })
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            // Ask for the shortest connection interval once per phone; the default is much slower.
            if tunedCentrals.insert(request.central.identifier).inserted {
                peripheral.setDesiredConnectionLatency(.low, for: request.central)
            }
            if let value = request.value { onDatagram?(value) }
        }
    }
}
