import SwiftUI

@main
struct RemoteControlMacApp: App {
    @State private var server: ConnectionServer
    init() {
        let server = ConnectionServer()
        server.start()
        _server = State(initialValue: server)
    }
    var body: some Scene {
        MenuBarExtra("遥控板", systemImage: server.peerName == nil ? "computermouse" : "computermouse.fill") {
            MacStatusView(server: server)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MacStatusView: View {
    @Bindable var server: ConnectionServer
    @State private var showSecret = false
    @State private var confirmRevoke = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("遥控板 Mac", systemImage: "computermouse.fill").font(.title2.bold())
            Label(server.status, systemImage: server.peerName == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(server.peerName == nil ? .secondary : .primary)
            if server.peerName != nil, !server.motionStatus.isEmpty {
                Text(server.motionStatus)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let problem = server.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !server.permissionGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("允许辅助功能访问后，iPhone 才能控制鼠标和输入文字。")
                    Button("打开辅助功能设置") { server.requestPermission() }
                }.padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            Divider()
            Text("首次连接").font(.headline)
            Text("让 iPhone 和 Mac 使用同一 Wi-Fi，在手机上选择这台 Mac，再输入下方配对码。")
                .foregroundStyle(.secondary)
            DisclosureGroup("显示配对码", isExpanded: $showSecret) {
                Text(server.secret).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(.top, 8)
                Button("复制配对码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.secret, forType: .string)
                }
                Text("配对码相当于控制钥匙，仅提供给你信任的设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("使用粘贴输入文字", isOn: Binding(get: { server.input.useClipboard }, set: { server.input.useClipboard = $0 }))
            Text("个别 App 无法接收中文时开启。会短暂使用剪贴板，再尝试恢复原内容。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(server.running ? "暂停接收" : "开始接收") {
                        if server.running { server.stop() } else { server.start() }
                    }
                    if server.peerName != nil {
                        Button("断开当前设备") { server.disconnectActive() }
                    }
                }
                Button("撤销所有配对", role: .destructive) { confirmRevoke = true }
            }
            Divider()
            Button("退出遥控板") { server.stop(); NSApplication.shared.terminate(nil) }
        }
        .padding(22).frame(width: 360)
        .confirmationDialog("更换配对码并断开所有设备？", isPresented: $confirmRevoke) {
            Button("撤销所有配对", role: .destructive) { server.revokePairing() }
        } message: { Text("之后需要在 iPhone 上输入新的配对码。") }
    }
}
