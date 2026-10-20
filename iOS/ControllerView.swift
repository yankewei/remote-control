import SwiftUI

private let ink = Color(red: 0.12, green: 0.20, blue: 0.29)
private let accent = Color(red: 0.18, green: 0.37, blue: 0.78)
private let paper = Color(red: 0.93, green: 0.95, blue: 0.98)

struct ControllerView: View {
    @Bindable var connection: MacConnection
    @Bindable var speech: SpeechInput
    @State private var showConnection = false
    @GestureState private var holdingMic = false
    @State private var editing = false
    @State private var draftBeforeSpeech = ""
    @State private var sentToast = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let showTextPanel = editing || speech.recording || speech.preparing || speech.finishing || !connection.draft.isEmpty || connection.sendingText
            ZStack {
                TouchpadCanvas(
                    sensitivity: connection.sensitivity,
                    send: connection.send,
                    isConnected: connection.connectedName != nil,
                    inputAllowed: connection.inputAllowed,
                    cornerRadius: landscape ? 28 : 38,
                    onConnect: { showConnection = true }
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

                VStack(spacing: 10) {
                    header(landscape: landscape)
                    Spacer(minLength: 0)
                    if let notice = speechNotice {
                        speechNoticeView(notice)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if sentToast {
                        sentToastView
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if showTextPanel {
                        textPanel
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    dock(landscape: landscape)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), value: showTextPanel)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.85), value: speechNotice)
            }
            .background(paper.ignoresSafeArea())
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showConnection) { ConnectionView(connection: connection, speech: speech) }
        .sheet(isPresented: $editing) { TextEntryView(connection: connection) }
        .onChange(of: holdingMic) { _, pressed in
            if pressed { beginSpeech() } else { speech.end() }
        }
        .onChange(of: speech.transcript) { _, text in
            guard !connection.sendingText else { return }
            connection.draft = mergedDraft(base: draftBeforeSpeech, transcript: text)
        }
        .onChange(of: connection.textStatus) { _, status in
            if status == "Mac 已接收文字" { flashSentToast() }
        }
        .task { connection.discover() }
        .onDisappear { speech.cancel() }
    }

    private var inputEnabled: Bool {
        connection.connectedName != nil && connection.inputAllowed
    }

    private var statusColor: Color {
        if connection.connectedName == nil { return Color(red: 0.45, green: 0.58, blue: 0.75) }
        return connection.inputAllowed
            ? Color(red: 0.18, green: 0.78, blue: 0.56)
            : Color(red: 1.00, green: 0.62, blue: 0.22)
    }

    private var speechNotice: String? {
        guard !speech.recording, !speech.preparing, !speech.finishing else { return nil }
        let status = speech.status
        guard !status.isEmpty,
              status != "按住说话，松开后预览文字",
              status != "识别完成，确认后发送" else { return nil }
        return status
    }

    private var controlBackground: Color {
        Color.white.opacity(reduceTransparency ? 1 : 0.78)
    }

    private func flashSentToast() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { sentToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { sentToast = false }
        }
    }

    private var sentToastView: some View {
        Label("已发送到 Mac", systemImage: "checkmark.circle.fill")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background { GlassSurface(cornerRadius: 14, reduceTransparency: reduceTransparency) }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
            )
    }

    private func beginSpeech() {
        guard !connection.sendingText else { return }
        draftBeforeSpeech = connection.draft
        speech.begin()
    }

    /// Keep whatever the user already typed. A dictation session appends to it instead of
    /// replacing it; ASCII words get a space between them.
    private func mergedDraft(base: String, transcript: String) -> String {
        guard !base.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return base }
        if let last = base.last, let first = transcript.first,
           last.isASCII, first.isASCII,
           last.isLetter || last.isNumber, first.isLetter || first.isNumber {
            return base + " " + transcript
        }
        return base + transcript
    }

    private func header(landscape: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.7), radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.connectedName ?? "遥控板")
                    .font(.system(landscape ? .subheadline : .headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(connection.status)
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.55))
                    .lineLimit(landscape ? 1 : 2)
            }
            Spacer(minLength: 8)
            Button { showConnection = true } label: {
                Image(systemName: connection.connectedName == nil ? "link" : "slider.horizontal.3")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(reduceTransparency ? 1 : 0.55), in: Circle())
            }
            .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("连接与设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background { GlassSurface(cornerRadius: 22, reduceTransparency: reduceTransparency) }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    @ViewBuilder
    private func dock(landscape: Bool) -> some View {
        VStack(spacing: 8) {
            if landscape {
                HStack(spacing: 8) {
                    leftButton
                    rightButton
                    keyButton(.escape, compact: true)
                    keyButton(.tab, compact: true)
                    keyButton(.delete, compact: true)
                    keyButton(.enter, compact: true)
                    keyboardButton
                    micCapsule
                }
            } else {
                HStack(spacing: 8) {
                    keyButton(.escape)
                    keyButton(.tab)
                    keyButton(.delete)
                    keyButton(.enter)
                }
                HStack(spacing: 8) {
                    leftButton
                    rightButton
                    keyboardButton
                    micCapsule
                }
            }
        }
        .padding(10)
        .background { GlassSurface(cornerRadius: 24, reduceTransparency: reduceTransparency) }
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var leftButton: some View {
        actionButton("左键") { editing = false; connection.send(.click(button: .left, count: 1)) }
    }

    private var rightButton: some View {
        actionButton("右键") { editing = false; connection.send(.click(button: .right, count: 1)) }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 54, height: 44)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
        .disabled(!inputEnabled)
        .opacity(inputEnabled ? 1 : 0.35)
    }

    private var keyboardButton: some View {
        Button { editing = true } label: {
            Image(systemName: "keyboard")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
        .disabled(!inputEnabled)
        .opacity(inputEnabled ? 1 : 0.35)
        .accessibilityLabel("输入文字")
    }

    private func keyButton(_ key: RemoteKey, compact: Bool = false) -> some View {
        Button { editing = false; connection.send(.key(key)) } label: {
            keyLabel(key, compact: compact)
        }
        .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
        .disabled(!inputEnabled)
        .opacity(inputEnabled ? 1 : 0.35)
        .accessibilityLabel(keyAccessibilityLabel(key))
    }

    @ViewBuilder
    private func keyLabel(_ key: RemoteKey, compact: Bool) -> some View {
        if compact {
            Text(keyText(key))
                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: 46, height: 34)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text(keyText(key))
                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func keyText(_ key: RemoteKey) -> String {
        switch key {
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .delete: return "⌫"
        case .enter: return "↵"
        default: return ""
        }
    }

    private func keyAccessibilityLabel(_ key: RemoteKey) -> String {
        switch key {
        case .enter: return "回车"
        case .delete: return "删除"
        case .escape: return "退出键"
        case .tab: return "制表键"
        default: return ""
        }
    }

    private var micCapsule: some View {
        HStack(spacing: 7) {
            Image(systemName: speech.recording ? "waveform" : "mic.fill")
                .font(.system(.subheadline, weight: .semibold))
            Text(speech.recording ? "松开，预览文字" : speech.preparing ? "正在准备…" : speech.finishing ? "正在识别…" : "按住说话")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(Capsule().fill(speech.recording ? Color.red : accent))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: (speech.recording ? Color.red : accent).opacity(0.35), radius: 12, y: 4)
        .contentShape(Capsule())
        .scaleEffect(holdingMic ? 0.97 : (speech.recording ? 1.02 : 1))
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: holdingMic)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: speech.recording)
        .gesture(DragGesture(minimumDistance: 0)
            .updating($holdingMic) { _, pressed, _ in pressed = true })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if speech.recording { speech.end() } else { beginSpeech() } }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Button { editing = true } label: {
                    Text(connection.draft.isEmpty ? "说点什么，或直接输入…" : connection.draft)
                        .foregroundStyle(connection.draft.isEmpty ? ink.opacity(0.55) : ink)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .disabled(speech.recording || speech.preparing || speech.finishing || connection.sendingText)
                Button { editing = false; connection.sendText() } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(accent))
                        .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("发送文字到 Mac")
                .disabled(connection.draft.isEmpty || connection.sendingText || speech.recording || speech.finishing || connection.connectedName == nil || !connection.inputAllowed)
            }
            if !connection.textStatus.isEmpty, !connection.draft.isEmpty {
                Text(connection.textStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background { GlassSurface(cornerRadius: 20, reduceTransparency: reduceTransparency) }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private func speechNoticeView(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(ink.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { GlassSurface(cornerRadius: 14, reduceTransparency: reduceTransparency) }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
            )
    }
}

struct ConnectionView: View {
    @Bindable var connection: MacConnection
    @Bindable var speech: SpeechInput
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var host = ""
    @State private var selected: DiscoveredMac?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(connection.status, systemImage: connection.connectedName == nil ? "wifi" : "checkmark.shield.fill")
                    if connection.connectedName != nil {
                        Button("断开连接") { connection.disconnect() }
                    } else {
                        if connection.isConnecting {
                            Button("取消连接") { connection.disconnect() }
                        }
                        if connection.hasSavedConnection {
                            Button("重新连接已保存的 Mac") { connection.reconnectSaved() }
                        }
                    }
                }
                Section("选择同一 Wi-Fi 下的 Mac") {
                    if connection.devices.isEmpty {
                        Text("正在寻找… 请打开 Mac 菜单栏中的遥控板。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.devices) { device in
                        HStack(spacing: 8) {
                            Button {
                                selected = device
                                host = ""
                            } label: {
                                HStack {
                                    Label(device.id, systemImage: "desktopcomputer")
                                    Spacer()
                                    if selected?.id == device.id { Image(systemName: "checkmark") }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if connection.canConnectSaved(device) {
                                Button("连接") { connection.connectSaved(device) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    TextField("或输入 Mac 局域网 IP", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Mac 局域网 IP")
                        .onChange(of: host) { _, value in if !value.isEmpty { selected = nil } }
                }
                Section {
                    TextField("Mac 上显示的配对码", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Mac 上显示的配对码")
                    Button("配对并连接") { connection.pair(device: selected, host: host, code: code) }
                        .disabled(code.isEmpty || (selected == nil && host.isEmpty))
                } header: { Text("首次配对") } footer: {
                    Text("在 Mac 菜单栏打开遥控板，展开“显示配对码”。配对后会保存控制钥匙，下次自动连接。手动 IP 使用端口 19847。")
                }
                Section("操作偏好") {
                    LabeledContent("指针速度", value: String(format: "%.1f×", connection.sensitivity))
                    Slider(value: $connection.sensitivity, in: 0.5...3, step: 0.1).accessibilityLabel("指针速度")
                    Toggle("仅使用离线语音识别", isOn: $speech.offlineOnly)
                        .disabled(speech.recording || speech.preparing || speech.finishing)
                    Text("关闭后，语音可能发送至 Apple 进行识别。语音结果始终先预览，再由你发送到 Mac。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("快捷操作") {
                    HStack {
                        Button("复制 ⌘C") { connection.send(.key(.copy)) }
                        Spacer()
                        Button("粘贴 ⌘V") { connection.send(.key(.paste)) }
                    }
                    Button("Spotlight ⌘Space") { connection.send(.key(.spotlight)) }
                }.disabled(connection.connectedName == nil || !connection.inputAllowed)
                Section { Button("忘记已保存的 Mac", role: .destructive) { connection.forget() } }
            }
            .navigationTitle("连接 Mac")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: connection.connectedName) { _, name in if name != nil { code = ""; dismiss() } }
        }
    }
}

struct TextEntryView: View {
    @Bindable var connection: MacConnection
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("文字会输入到 Mac 当前选中的文本框。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $connection.draft).focused($focused)
                    .disabled(connection.sendingText)
                    .accessibilityLabel("要发送到 Mac 的文字")
                Text(connection.textStatus).font(.caption).foregroundStyle(.secondary)
                Button("发送到 Mac") { focused = false; connection.sendText() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(connection.draft.isEmpty || connection.sendingText || connection.connectedName == nil || !connection.inputAllowed)
            }
            .padding().navigationTitle("输入文字").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { focused = true }
            .onChange(of: connection.sendingText) { _, sending in
                if !sending && connection.draft.isEmpty { dismiss() }
            }
        }
    }
}
