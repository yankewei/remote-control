import AVFoundation
import Speech
import Observation

@Observable
final class SpeechInput {
    var transcript = ""
    var status = "按住说话，松开后预览文字"
    var recording = false
    var preparing = false
    var finishing = false
    var offlineOnly = UserDefaults.standard.object(forKey: "offlineSpeech") as? Bool ?? true {
        didSet { UserDefaults.standard.set(offlineOnly, forKey: "offlineSpeech") }
    }
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var sessionID = UUID()
    private var tapInstalled = false
    private var holding = false
    private var finishTimeout: Timer?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began,
                  self.recording || self.preparing || self.finishing || self.holding else { return }
            self.cancel()
            self.status = "录音被打断，请重新按住说话"
        }
    }

    func begin() {
        guard !recording, !preparing, !finishing else { return }
        holding = true
        preparing = true
        let id = UUID()
        sessionID = id
        Task { @MainActor [self] in
            let speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
            guard self.sessionID == id else { return }
            self.preparing = false
            guard speechAllowed, microphoneAllowed else { self.status = "请在系统设置中允许麦克风和语音识别"; return }
            guard self.holding else { self.status = "权限已就绪，请重新按住说话"; return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
                self.status = "中文语音识别暂不可用，请稍后重试"; return
            }
            guard !self.offlineOnly || recognizer.supportsOnDeviceRecognition else {
                self.status = "此设备不支持离线中文识别，可在连接设置中允许在线识别"; return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = self.offlineOnly
                self.request = request
                self.transcript = ""
                self.recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal ?? false
                    let errorText = error?.localizedDescription
                    DispatchQueue.main.async {
                        guard let self, self.sessionID == id else { return }
                        if let text { self.transcript = text }
                        if final || errorText != nil {
                            self.stopAudio()
                            self.finishing = false
                            self.finishTimeout?.invalidate()
                            self.recognition = nil
                            self.request = nil
                            self.status = errorText.map { "识别结束：\($0)，请检查预览文字" } ?? "识别完成，确认后发送"
                        }
                    }
                }
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noMicrophone }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
                self.tapInstalled = true
                self.engine.prepare()
                try self.engine.start()
                self.recording = true
                self.status = self.offlineOnly ? "正在聆听 · 本机识别" : "正在聆听 · 可能使用 Apple 在线服务"
            } catch {
                self.cancel()
                self.status = "无法开始录音：\(error.localizedDescription)"
            }
        }
    }

    func end() {
        holding = false
        guard recording else { return }
        stopAudio()
        finishing = true
        status = "正在整理识别结果"
        request?.endAudio()
        finishTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.finishing else { return }
            self.cancel()
            self.status = "已保留当前识别结果，请检查后发送"
        }
    }

    private func stopAudio() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cancel() {
        holding = false
        sessionID = UUID()
        preparing = false
        finishing = false
        stopAudio()
        finishTimeout?.invalidate()
        recognition?.cancel()
        recognition = nil
        request = nil
        // Callers that have a more specific message (interruption, failure, timeout) set it after
        // calling cancel; otherwise returning to the app should not show a stale "正在聆听".
        status = "按住说话，松开后预览文字"
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }
}

enum SpeechError: Error { case noMicrophone }
