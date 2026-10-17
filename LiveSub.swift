// LiveSub — 맥에서 재생되는 모든 소리를 듣고 실시간으로 한국어 자막을 화면 위에 띄워 줍니다.
// 시스템 오디오 캡처(ScreenCaptureKit) + 자막 오버레이 + Python 인식/번역 워커 관리.
// 빌드: swiftc -O -swift-version 5 LiveSub.swift -o LiveSub \
//        -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

let SUPPORT = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LiveSub")
let LOG_PATH = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/LiveSub.log").path

func logLine(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    if let h = FileHandle(forWritingAtPath: LOG_PATH) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    }
}

// MARK: - 설정 (Python 워커와 공유하는 config.json)

enum Config {
    static var url: URL { SUPPORT.appendingPathComponent("config.json") }

    static func load() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func set(_ key: String, _ value: Any) {
        var c = load()
        c[key] = value
        if let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted]) {
            try? d.write(to: url)
            chmod(url.path, 0o600)
        }
    }
}

// MARK: - 자막 오버레이 창

final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor
final class Overlay: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let box = NSView()
    let jaLabel = PassthroughLabel(wrappingLabelWithString: "")
    let koLabel = PassthroughLabel(wrappingLabelWithString: "")
    var hideTimer: Timer?
    var shownId = -1
    var moveMode = false
    var koIsStatus = false

    var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "fontSize")
        return v > 0 ? CGFloat(v) : 30
    }
    var showOriginal: Bool {
        UserDefaults.standard.object(forKey: "showOriginal") as? Bool ?? true
    }

    override init() {
        let scr = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let w = min(scr.width * 0.85, 1400)
        let h: CGFloat = 260
        var origin = NSPoint(x: scr.midX - w / 2, y: scr.minY + 40)
        if let x = UserDefaults.standard.object(forKey: "posX") as? Double,
           let y = UserDefaults.standard.object(forKey: "posY") as? Double {
            origin = NSPoint(x: x, y: y)
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver                      // 전체화면 영상 위에도 표시
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true                 // 클릭은 아래 플레이어로 통과
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        panel = p
        super.init()
        panel.delegate = self

        let content = DragView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = content

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        box.layer?.cornerRadius = 14
        box.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(box)

        let stack = NSStackView(views: [jaLabel, koLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        for l in [jaLabel, koLabel] {
            l.alignment = .center
            l.isEditable = false
            l.isSelectable = false
            l.isBordered = false
            l.drawsBackground = false
            l.maximumNumberOfLines = 3
            l.lineBreakMode = .byWordWrapping
            l.preferredMaxLayoutWidth = w - 48
            l.shadow = shadow
        }
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        applyStyle()
        box.isHidden = true
        panel.orderFrontRegardless()

    }

    func windowDidMove(_ notification: Notification) {
        let f = panel.frame
        UserDefaults.standard.set(Double(f.origin.x), forKey: "posX")
        UserDefaults.standard.set(Double(f.origin.y), forKey: "posY")
    }

    @objc func hideBox() { box.isHidden = true }

    func applyStyle() {
        koLabel.font = NSFont.boldSystemFont(ofSize: fontSize)
        koLabel.textColor = .white
        jaLabel.font = NSFont.systemFont(ofSize: max(13, fontSize * 0.58))
        jaLabel.textColor = NSColor(white: 0.85, alpha: 1)
        jaLabel.isHidden = !showOriginal || jaLabel.stringValue.isEmpty
    }

    private func reveal(seconds: Double) {
        box.isHidden = false
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        if moveMode { return }
        hideTimer = Timer.scheduledTimer(timeInterval: seconds, target: self, selector: #selector(hideBox),
                                         userInfo: nil, repeats: false)
    }

    /// 인식된 일본어 원문 (번역 전)
    func showOriginalLine(id: Int, text: String) {
        guard id > shownId else { return }
        shownId = id
        jaLabel.stringValue = text
        jaLabel.isHidden = !showOriginal
        if koIsStatus { koLabel.stringValue = ""; koIsStatus = false }
        koLabel.alphaValue = 0.45            // 이전 번역은 흐리게 유지 (깜빡임 방지)
        if !showOriginal && koLabel.stringValue.isEmpty { return }
        reveal(seconds: 4 + Double(text.count) * 0.12)
    }

    /// 번역된 한국어 자막
    func showTranslation(id: Int, text: String) {
        guard id >= shownId else { return }   // 이미 다음 줄이 나온 늦은 번역은 무시
        shownId = id
        koLabel.stringValue = text
        koLabel.alphaValue = 1
        koIsStatus = false
        if text == jaLabel.stringValue { jaLabel.isHidden = true }   // 번역 없이 원문만 온 경우
        reveal(seconds: 3.5 + Double(text.count) * 0.18)
    }

    func showStatus(_ text: String, seconds: Double = 4) {
        jaLabel.isHidden = true
        koLabel.alphaValue = 1
        koLabel.stringValue = text
        koIsStatus = true
        reveal(seconds: seconds)
    }

    func setMoveMode(_ on: Bool) {
        moveMode = on
        panel.ignoresMouseEvents = !on
        if on {
            showStatus("이 자막을 끌어서 원하는 위치로 옮기세요")
            box.layer?.borderWidth = 2
            box.layer?.borderColor = NSColor.systemYellow.cgColor
        } else {
            box.layer?.borderWidth = 0
            box.isHidden = true
        }
    }

    func resetPosition() {
        let scr = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: scr.midX - panel.frame.width / 2, y: scr.minY + 40))
    }
}

// MARK: - Python 워커 (음성 인식 + 번역)

final class Worker {
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let writeQueue = DispatchQueue(label: "livesub.write")
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { proc?.isRunning ?? false }

    func start() throws {
        let p = Process()
        p.executableURL = SUPPORT.appendingPathComponent("venv/bin/python")
        p.arguments = ["-u", SUPPORT.appendingPathComponent("worker.py").path]
        p.currentDirectoryURL = SUPPORT
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        if let errHandle = FileHandle(forWritingAtPath: LOG_PATH) {
            errHandle.seekToEndOfFile()
            p.standardError = errHandle
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        p.terminationHandler = { [weak self] pr in
            let code = pr.terminationStatus
            DispatchQueue.main.async {
                guard let self = self, self.proc === pr else { return }   // 의도적으로 끈 경우는 무시
                self.onExit?(code)
            }
        }
        try p.run()
        proc = p
        input = inPipe.fileHandleForWriting
    }

    func stop() {
        try? input?.close()
        input = nil
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                DispatchQueue.main.async { self.onMessage?(o) }
            }
        }
    }

    /// 헤더(샘플레이트 UInt32, 샘플 수 UInt32) + Float32 모노 PCM
    func send(rate: Int, samples: [Float]) {
        guard let h = input, !samples.isEmpty else { return }
        var header: [UInt32] = [UInt32(rate), UInt32(samples.count)]
        var d = Data(bytes: &header, count: 8)
        samples.withUnsafeBufferPointer { d.append($0) }
        writeQueue.async {
            do { try h.write(contentsOf: d) } catch { /* 워커 종료 시 무시 */ }
        }
    }
}

// MARK: - 시스템 오디오 캡처 (ScreenCaptureKit)

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "livesub.audio")
    var onAudio: ((Int, [Float]) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "LiveSub", code: 1, userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾을 수 없습니다."])
        }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // 화면은 필요 없으므로 최소 크기·최저 프레임으로
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logLine("stream stopped: \(error)")
        DispatchQueue.main.async { self.onError?(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatFlags & UInt32(kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 else { return }

        var needed = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block)
        guard st == noErr else { return }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        let channels = Int(max(1, asbd.mChannelsPerFrame))
        let nonInterleaved = asbd.mFormatFlags & UInt32(kAudioFormatFlagIsNonInterleaved) != 0
        var mono: [Float] = []

        if nonInterleaved || channels == 1 {
            // 버퍼별 채널 → 평균
            var acc: [Float] = []
            var n = 0
            for buf in abl {
                guard let p = buf.mData else { continue }
                let count = Int(buf.mDataByteSize) / 4
                let f = p.bindMemory(to: Float.self, capacity: count)
                if acc.isEmpty { acc = Array(UnsafeBufferPointer(start: f, count: count)) }
                else { for i in 0..<min(count, acc.count) { acc[i] += f[i] } }
                n += 1
            }
            if n > 1 { let k = 1 / Float(n); for i in 0..<acc.count { acc[i] *= k } }
            mono = acc
        } else {
            // 인터리브 → 다운믹스
            guard let buf = abl.first, let p = buf.mData else { return }
            let total = Int(buf.mDataByteSize) / 4
            let f = p.bindMemory(to: Float.self, capacity: total)
            let frames = total / channels
            mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += f[i * channels + c] }
                mono[i] = s / Float(channels)
            }
        }
        onAudio?(Int(asbd.mSampleRate), mono)
    }
}

// MARK: - 앱 / 메뉴 막대

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var overlay: Overlay!
    let worker = Worker()
    let capture = AudioCapture()
    var running = false
    var stopping = false
    var statusText = "꺼짐"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !FileManager.default.fileExists(atPath: LOG_PATH) {
            FileManager.default.createFile(atPath: LOG_PATH, contents: nil)
        }
        overlay = Overlay()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        worker.onMessage = { [weak self] m in self?.handle(m) }
        worker.onExit = { [weak self] code in
            guard let self = self else { return }
            if self.running && !self.stopping {
                self.overlay.showStatus("자막 엔진이 멈췄어요 (코드 \(code)). 메뉴에서 다시 시작해 주세요.", seconds: 8)
                Task { await self.stop() }
            }
        }
        capture.onAudio = AppDelegate.audioHandler(worker)
        capture.onError = { [weak self] _ in
            guard let self = self, self.running, !self.stopping else { return }
            self.overlay.showStatus("오디오 캡처가 중단됐어요. 다시 시작해 주세요.", seconds: 6)
            Task { await self.stop() }
        }

        let hasKey = !((Config.load()["api_key"] as? String) ?? "").isEmpty
        Task {
            await self.start()
            if !hasKey { self.askKey() }
        }
    }

    /// 오디오 스레드에서 호출되므로 메인 액터와 분리된 클로저로 만듦
    nonisolated static func audioHandler(_ w: Worker) -> (Int, [Float]) -> Void {
        return { rate, samples in w.send(rate: rate, samples: samples) }
    }

    func applicationWillTerminate(_ notification: Notification) { worker.stop() }

    func updateIcon() {
        let name = running ? "captions.bubble.fill" : "captions.bubble"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "실시간 자막") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = running ? "자막●" : "자막"
        }
    }

    // 메뉴는 열 때마다 새로 구성
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = NSMenuItem(title: "상태: \(statusText)", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())
        menu.addItem(item(running ? "자막 끄기" : "자막 켜기", #selector(toggleRun), "s"))
        menu.addItem(.separator())

        let orig = item("일본어 원문도 표시", #selector(toggleOriginal))
        orig.state = overlay.showOriginal ? .on : .off
        menu.addItem(orig)

        let sizeMenu = NSMenu()
        for (label, v) in [("작게", 22.0), ("보통", 30.0), ("크게", 40.0), ("아주 크게", 52.0)] {
            let it = item(label, #selector(setFont(_:)))
            it.representedObject = v
            it.state = abs(Double(overlay.fontSize) - v) < 0.1 ? .on : .off
            sizeMenu.addItem(it)
        }
        let sizeItem = NSMenuItem(title: "글자 크기", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let mv = item(overlay.moveMode ? "위치 조정 끝내기" : "자막 위치 옮기기…", #selector(toggleMove))
        menu.addItem(mv)
        menu.addItem(item("위치 초기화", #selector(resetPos)))
        menu.addItem(.separator())
        menu.addItem(item("Claude API 키 설정…", #selector(askKey)))
        menu.addItem(item("로그 보기", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("종료", #selector(quit), "q"))
    }

    func item(_ t: String, _ a: Selector, _ k: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
        i.target = self
        return i
    }

    // MARK: 동작

    func start() async {
        guard !running else { return }
        stopping = false
        statusText = "시작 중…"
        do {
            if !worker.isRunning { try worker.start() }
            try await capture.start()
            running = true
            updateIcon()
        } catch {
            logLine("start failed: \(error)")
            worker.stop()
            statusText = "꺼짐"
            updateIcon()
            permissionAlert(error)
        }
    }

    func stop() async {
        stopping = true
        await capture.stop()
        worker.stop()
        running = false
        statusText = "꺼짐"
        updateIcon()
    }

    @objc func toggleRun() {
        Task {
            if running { await stop() } else { await start() }
        }
    }

    @objc func toggleOriginal() {
        UserDefaults.standard.set(!overlay.showOriginal, forKey: "showOriginal")
        overlay.applyStyle()
    }

    @objc func setFont(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double {
            UserDefaults.standard.set(v, forKey: "fontSize")
            overlay.applyStyle()
            overlay.showStatus("자막 크기 미리보기")
        }
    }

    @objc func toggleMove() { overlay.setMoveMode(!overlay.moveMode) }
    @objc func resetPos() { overlay.resetPosition() }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH)) }
    @objc func quit() { worker.stop(); NSApp.terminate(nil) }

    @objc func askKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Claude API 키"
        a.informativeText = "일본어 → 한국어 번역에 사용합니다. console.anthropic.com 에서 발급받을 수 있어요.\n키가 없으면 일본어 원문만 표시됩니다."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        a.accessoryView = field
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            Config.set("api_key", key)
            if running {   // 새 키로 워커 재시작
                Task { await stop(); await start() }
            }
        }
    }

    func permissionAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "시스템 오디오를 들을 권한이 필요해요"
        a.informativeText = "시스템 설정 > 개인정보 보호 및 보안 > ‘화면 및 시스템 오디오 녹음’에서 LiveSub을 켠 뒤, 앱을 다시 실행해 주세요.\n\n(LiveSub은 화면을 녹화하지 않고 소리만 사용합니다.)\n\n오류: \(error.localizedDescription)"
        a.addButton(withTitle: "시스템 설정 열기")
        a.addButton(withTitle: "닫기")
        if a.runModal() == .alertFirstButtonReturn {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    // MARK: 워커 메시지

    func handle(_ m: [String: Any]) {
        let t = m["t"] as? String ?? ""
        switch t {
        case "status":
            statusText = m["msg"] as? String ?? ""
            if m["show"] as? Bool == true { overlay.showStatus(statusText) }
        case "ja":
            overlay.showOriginalLine(id: m["id"] as? Int ?? 0, text: m["text"] as? String ?? "")
        case "ko":
            overlay.showTranslation(id: m["id"] as? Int ?? 0, text: m["text"] as? String ?? "")
        default:
            break
        }
    }
}

@main
struct LiveSubMain {
    @MainActor static var delegate: AppDelegate?

    @MainActor static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
