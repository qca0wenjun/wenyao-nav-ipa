// 问爻导航 · iPhone 端（路线 C）
//
// 作用：后台持续取 GPS → 调高德步行路径规划 API 算出下一步转向 →
// 通过 BLE 把指令写给 AI Passport 设备，设备显示大箭头 + 距离 + 路名并语音播报。
//
// 设备侧 UUID（广播里已声明 AA00，App 可精确扫描）：
//   Service 0000AA00-0000-1000-8000-00805F9B34FB  → CBUUID(string: "AA00")
//   RX      0000AA01-...  Write / Write-Without-Response
//   TX      0000AA02-...  Notify（设备回执）
//
// 协议：UTF-8 文本，一行一条，以 \n 结束，按 <=20 字节分片写入（兼容任意 MTU）。
//   W|SSID|PASS|AMAPKEY   配置设备端 WiFi + 高德 Key（可选，设备自主算路）
//   T|lon,lat             设置目的地
//   G|lon,lat|heading|spd 上报当前位置（设备端算路时每秒一次）
//   D|dir|dist|text       转向指令，设备直接显示
//   N|text                通知原文
//   P|text                状态栏文字
// dir: 0 等待 1 直行 2 左转 3 右转 4 左前 5 右前 6 掉头 7 到达 8 环岛
//
// 默认「手机端算路」：只需高德 Key + 目的地，设备不用连 WiFi，开箱即用。
// 打开「设备端自主算路」后，App 下发 W|/T|/G|，设备自己连 WiFi 调高德 API。
import UIKit
import CoreBluetooth
import CoreLocation

private let kServiceUUID = CBUUID(string: "AA00")
private let kRxUUID = CBUUID(string: "AA01")
private let kTxUUID = CBUUID(string: "AA02")

// 已在高德开放平台创建「问爻导航」应用的 Web服务 Key，实测地理编码/步行路径规划均可用。
// 内置后开箱即用；用户如需更换，直接在界面里改「高德 Key」输入框即可。
private let kDefaultAmapKey = "b57786a4a4997c45b1c753f6f96569a9"

final class ViewController: UIViewController,
                            CBCentralManagerDelegate,
                            CBPeripheralDelegate,
                            CLLocationManagerDelegate,
                            UITextFieldDelegate {

    // MARK: - UI
    private let statusLabel = UILabel()
    private let destField = UITextField()
    private let keyField = UITextField()
    private let ssidField = UITextField()
    private let passField = UITextField()
    private let deviceSwitch = UISwitch()
    private let startButton = UIButton(type: .system)
    private let logView = UITextView()
    private let scrollView = UIScrollView()

    // MARK: - BLE
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var chunks: [Data] = []
    private var writing = false
    private var configSent = false

    // MARK: - 定位 / 算路
    private let locationManager = CLLocationManager()
    private var destLonLat: String?
    private var navigating = false
    private var lastGPSSend = Date.distantPast
    private var lastRouteRequest = Date.distantPast

    private let defaults = UserDefaults.standard

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "问爻导航"
        view.backgroundColor = UIColor(red: 0.91, green: 0.87, blue: 0.78, alpha: 1.0)
        buildUI()
        loadPrefs()
        central = CBCentralManager(delegate: self, queue: .main)
        locationManager.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        log("启动完成。高德 Key 已内置，填好目的地点「开始导航」即可。")
        log("请先在设备上开机选「导航·投屏」，App 会自动连接 WenYao Nav。")
    }

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        statusLabel.numberOfLines = 0
        statusLabel.font = .boldSystemFont(ofSize: 15)
        statusLabel.textColor = UIColor(red: 0.70, green: 0.23, blue: 0.18, alpha: 1.0)
        statusLabel.text = "状态：等待蓝牙"
        stack.addArrangedSubview(statusLabel)

        func addField(_ title: String, _ field: UITextField, _ placeholder: String, secure: Bool = false) {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 13)
            label.textColor = .darkGray
            stack.addArrangedSubview(label)

            field.borderStyle = .roundedRect
            field.placeholder = placeholder
            field.font = .systemFont(ofSize: 14)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.isSecureTextEntry = secure
            field.returnKeyType = .done
            field.delegate = self
            field.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(field)
        }

        addField("目的地（地名，或 经度,纬度）", destField, "例如 北京南站 或 116.378,39.902")
        addField("高德 Key（已内置，可直接用；需要时再改）", keyField, "已内置 Web服务 Key")

        let switchRow = UIStackView()
        switchRow.axis = .horizontal
        switchRow.spacing = 8
        switchRow.alignment = .center
        let switchLabel = UILabel()
        switchLabel.text = "设备端自主算路（需填下方 WiFi + Key）"
        switchLabel.font = .systemFont(ofSize: 13)
        switchLabel.numberOfLines = 2
        switchRow.addArrangedSubview(switchLabel)
        deviceSwitch.isOn = false
        switchRow.addArrangedSubview(deviceSwitch)
        stack.addArrangedSubview(switchRow)

        addField("WiFi 名称（仅设备端算路需要）", ssidField, "WIFI_SSID")
        addField("WiFi 密码（仅设备端算路需要）", passField, "WIFI_PASS", secure: true)

        startButton.setTitle("开始导航", for: .normal)
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        startButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        startButton.addTarget(self, action: #selector(onStartTapped), for: .touchUpInside)
        stack.addArrangedSubview(startButton)

        let logTitle = UILabel()
        logTitle.text = "运行日志"
        logTitle.font = .systemFont(ofSize: 13)
        logTitle.textColor = .darkGray
        stack.addArrangedSubview(logTitle)

        logView.isEditable = false
        logView.font = .systemFont(ofSize: 12)
        logView.backgroundColor = UIColor(white: 1.0, alpha: 0.8)
        logView.layer.cornerRadius = 6
        logView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        stack.addArrangedSubview(logView)
    }

    // MARK: - 偏好
    private func loadPrefs() {
        destField.text = defaults.string(forKey: "dest")
        let savedKey = defaults.string(forKey: "amapKey") ?? ""
        keyField.text = savedKey.isEmpty ? kDefaultAmapKey : savedKey
        ssidField.text = defaults.string(forKey: "wifiSSID")
        passField.text = defaults.string(forKey: "wifiPass")
        deviceSwitch.isOn = defaults.bool(forKey: "deviceRoute")
        destLonLat = defaults.string(forKey: "destLonLat")
    }

    // 统一取 Key：界面清空时回退到内置 Web服务 Key，避免「忘记填 Key 就没法导航」。
    private func amapKey() -> String {
        let typed = keyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? kDefaultAmapKey : typed
    }

    private func savePrefs() {
        defaults.set(destField.text, forKey: "dest")
        defaults.set(keyField.text, forKey: "amapKey")
        defaults.set(ssidField.text, forKey: "wifiSSID")
        defaults.set(passField.text, forKey: "wifiPass")
        defaults.set(deviceSwitch.isOn, forKey: "deviceRoute")
    }

    // MARK: - 工具
    private func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logView.text = (logView.text ?? "") + "[\(stamp)] \(message)\n"
        let length = (logView.text as NSString).length
        if length > 0 {
            logView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = "状态：" + text
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - BLE 写入队列
    private func sendLine(_ line: String) {
        guard let characteristic = rxChar,
              let device = peripheral,
              device.state == .connected else { return }
        let clean = line.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
        guard let data = (clean + "\n").data(using: .utf8) else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 20, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        writeNext()
    }

    private func writeNext() {
        guard !writing, !chunks.isEmpty,
              let characteristic = rxChar,
              let device = peripheral,
              device.state == .connected else { return }
        let chunk = chunks.removeFirst()
        writing = true
        device.writeValue(chunk, for: characteristic, type: .withResponse)
    }

    private func pushConfig() {
        let key = amapKey()
        let ssid = ssidField.text ?? ""
        let pass = passField.text ?? ""
        if !configSent {
            if deviceSwitch.isOn && !ssid.isEmpty && !pass.isEmpty {
                sendLine("W|\(ssid)|\(pass)|\(key)")
                log("已下发 WiFi/Key，设备开始联网")
            }
            configSent = true
        }
        if let destination = destLonLat {
            sendLine("T|\(destination)")
        }
    }

    private func rescan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [kServiceUUID],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func attach(_ device: CBPeripheral) {
        peripheral = device
        device.delegate = self
        central.connect(device, options: nil)
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            setStatus("蓝牙就绪，扫描设备")
            log("蓝牙已开启，扫描 AA00 服务…")
            let known = central.retrieveConnectedPeripherals(withServices: [kServiceUUID])
            if let existing = known.first {
                log("发现系统已连接的设备，复用该连接")
                attach(existing)
            }
            rescan()
        } else {
            setStatus("蓝牙不可用 (\(central.state.rawValue))")
            log("蓝牙状态变化：\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let name = peripheral.name ?? localName
        guard name.contains("WenYao") || name.contains("WYNav") else { return }
        if self.peripheral?.identifier == peripheral.identifier { return }
        log("发现 \(name)，连接中…")
        central.stopScan()
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接，发现自定义服务…")
        setStatus("已连接，读取通道")
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        rescan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("设备断开，重新扫描")
        rxChar = nil
        chunks.removeAll()
        writing = false
        configSent = false
        setStatus("设备已断开")
        rescan()
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("服务发现失败：\(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            log("未找到 AA00 服务。请确认设备开机选的是「导航·投屏」，不是算卦。")
            return
        }
        peripheral.discoverCharacteristics([kRxUUID, kTxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("特征发现失败：\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == kRxUUID {
                rxChar = characteristic
                log("写入通道 AA01 就绪")
            }
            if characteristic.uuid == kTxUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if rxChar != nil {
            setStatus("设备已连通，可以开始导航")
            pushConfig()
        } else {
            log("未找到 AA01 写入特征")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error = error {
            log("写入失败：\(error.localizedDescription)")
        }
        writeNext()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        log("设备回执：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: - 目的地解析
    private func resolveDestination(_ text: String, completion: @escaping (Bool) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ",").map(String.init)
        if parts.count == 2, Double(parts[0]) != nil, Double(parts[1]) != nil {
            destLonLat = trimmed
            defaults.set(trimmed, forKey: "destLonLat")
            completion(true)
            return
        }
        let key = amapKey()
        var components = URLComponents(string: "https://restapi.amap.com/v3/geocode/geo")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "address", value: trimmed),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = components.url else { completion(false); return }
        log("正在把地名解析成坐标…")
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.log("地理编码失败：\(error.localizedDescription)")
                    completion(false)
                    return
                }
                guard let data = data,
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let json = object as? [String: Any],
                      let geocodes = json["geocodes"] as? [[String: Any]],
                      let location = geocodes.first?["location"] as? String else {
                    self.log("地名没解析出来，请改用『经度,纬度』格式")
                    completion(false)
                    return
                }
                self.destLonLat = location
                self.defaults.set(location, forKey: "destLonLat")
                self.log("目的地坐标：\(location)")
                completion(true)
            }
        }.resume()
    }

    // MARK: - 高德步行路径规划（手机端算路，默认路径）
    private func requestRoute(origin: String) {
        guard let destination = destLonLat else { return }
        let key = amapKey()
        var components = URLComponents(string: "https://restapi.amap.com/v3/direction/walking")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "steps", value: "1"),
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.log("算路请求失败：\(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let json = object as? [String: Any] else {
                    self.log("算路响应解析失败")
                    return
                }
                if let status = json["status"] as? String, status != "1" {
                    self.log("高德返回：\(json["info"] as? String ?? "未知错误")")
                    return
                }
                guard let route = json["route"] as? [String: Any],
                      let paths = route["paths"] as? [[String: Any]],
                      let firstPath = paths.first,
                      let steps = firstPath["steps"] as? [[String: Any]],
                      let step = steps.first else {
                    self.log("没有更多转向步骤，视为已到达")
                    self.sendLine("D|7|0 米|已到达目的地附近")
                    return
                }
                let action = step["action"] as? String ?? ""
                let instruction = step["instruction"] as? String ?? ""
                let distance = step["distance"] as? String ?? ""
                let road = step["road"] as? String ?? ""
                let text = instruction.isEmpty ? (road.isEmpty ? action : road) : instruction
                let direction = self.mapDirection(action, instruction)
                let safeText = text.replacingOccurrences(of: "|", with: " ")
                self.sendLine("D|\(direction)|\(distance) 米|\(safeText)")
                self.log("→ \(safeText)")
            }
        }.resume()
    }

    private func mapDirection(_ action: String, _ instruction: String) -> Int {
        let text = action + " " + instruction
        if text.contains("掉头") || text.contains("调头") { return 6 }
        if text.contains("到达") || text.contains("终点") || text.contains("抵达") { return 7 }
        if text.contains("环岛") || text.contains("转盘") { return 8 }
        if text.contains("左前方") || text.contains("靠左") || text.contains("向左前方") { return 4 }
        if text.contains("右前方") || text.contains("靠右") || text.contains("向右前方") { return 5 }
        if text.contains("左转") || text.contains("左拐") || text.contains("向左转") { return 2 }
        if text.contains("右转") || text.contains("右拐") || text.contains("向右转") { return 3 }
        if text.contains("直行") || text.contains("沿") || text.contains("保持") || text.contains("步行") { return 1 }
        return 0
    }

    // MARK: - 开始 / 停止
    @objc private func onStartTapped() {
        view.endEditing(true)
        savePrefs()

        if navigating {
            navigating = false
            locationManager.stopUpdatingLocation()
            if CLLocationManager.headingAvailable() { locationManager.stopUpdatingHeading() }
            startButton.setTitle("开始导航", for: .normal)
            setStatus("已停止")
            log("导航已停止")
            return
        }

        guard let destination = destField.text, !destination.isEmpty else {
            log("请填目的地（地名，或 经度,纬度）")
            return
        }

        resolveDestination(destination) { [weak self] ok in
            guard let self = self, ok else { return }
            self.navigating = true
            self.startButton.setTitle("停止导航", for: .normal)
            self.locationManager.requestAlwaysAuthorization()
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
            self.locationManager.distanceFilter = 5
            self.locationManager.allowsBackgroundLocationUpdates = true
            self.locationManager.pausesLocationUpdatesAutomatically = false
            self.locationManager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                self.locationManager.startUpdatingHeading()
            }
            self.lastRouteRequest = Date.distantPast
            self.setStatus("导航中 · 持续上报位置")
            self.log("开始导航 → \(self.destLonLat ?? "-")")
            self.pushConfig()
        }
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard navigating, let location = locations.last else { return }
        let origin = String(format: "%.6f,%.6f",
                            location.coordinate.longitude,
                            location.coordinate.latitude)
        let heading = manager.heading?.trueHeading ?? -1
        let speed = max(0, location.speed)
        let now = Date()

        if deviceSwitch.isOn && now.timeIntervalSince(lastGPSSend) >= 1.0 {
            lastGPSSend = now
            sendLine(String(format: "G|%@|%.1f|%.1f", origin, heading, speed))
        }
        if now.timeIntervalSince(lastRouteRequest) >= 10.0 {
            lastRouteRequest = now
            requestRoute(origin: origin)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log("定位失败：\(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        log("定位授权状态：\(status.rawValue)")
        if navigating && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            manager.startUpdatingLocation()
        }
    }
}
