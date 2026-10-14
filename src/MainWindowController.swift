import Cocoa

// MARK: - Modern Gradient & Segmented VU Meter View
public final class ModernVUMeterView: NSView {
    public var level: Float = 0.0 {
        didSet {
            let clamped = max(0.0, min(1.0, level))
            if clamped > peakLevel {
                peakLevel = clamped
            }
            needsDisplay = true
        }
    }
    
    private var peakLevel: Float = 0.0
    private var decayTimer: Timer?
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        startPeakDecay()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        startPeakDecay()
    }
    
    deinit {
        decayTimer?.invalidate()
    }
    
    private func startPeakDecay() {
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.peakLevel > self.level {
                self.peakLevel = max(self.level, self.peakLevel - 0.035)
                self.needsDisplay = true
            }
        }
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let bounds = self.bounds
        
        // Dark track background
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.85).cgColor)
        let path = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.addPath(path)
        context.fillPath()
        
        // Draw segments
        let segmentCount = 28
        let spacing: CGFloat = 2.0
        let totalSpacing = spacing * CGFloat(segmentCount - 1)
        let segmentWidth = (bounds.width - 8.0 - totalSpacing) / CGFloat(segmentCount)
        let segHeight = bounds.height - 6.0
        let y = 3.0
        
        let activeCount = Int(round(CGFloat(level) * CGFloat(segmentCount)))
        let peakIndex = min(segmentCount - 1, Int(round(CGFloat(peakLevel) * CGFloat(segmentCount - 1))))
        
        for i in 0..<segmentCount {
            let x = 4.0 + CGFloat(i) * (segmentWidth + spacing)
            let segRect = CGRect(x: x, y: y, width: segmentWidth, height: segHeight)
            let segPath = CGPath(roundedRect: segRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            
            let progress = Float(i) / Float(segmentCount)
            let segColor: NSColor
            if progress < 0.65 {
                segColor = NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.44, alpha: 1.0) // Green
            } else if progress < 0.85 {
                segColor = NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.16, alpha: 1.0) // Yellow/Amber
            } else {
                segColor = NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.25, alpha: 1.0) // Red/Clip
            }
            
            if i < activeCount {
                context.setFillColor(segColor.cgColor)
                context.addPath(segPath)
                context.fillPath()
            } else {
                // Dim unlit segment
                context.setFillColor(segColor.withAlphaComponent(0.15).cgColor)
                context.addPath(segPath)
                context.fillPath()
            }
            
            // Peak hold dot
            if i == peakIndex && peakLevel > 0.05 {
                context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                let peakRect = CGRect(x: x, y: y, width: segmentWidth, height: segHeight)
                context.addPath(CGPath(roundedRect: peakRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.fillPath()
            }
        }
    }
}

// MARK: - Modern Glass Card Container View
public final class ModernCardView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        updateColors()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        updateColors()
    }
    
    public override func updateLayer() {
        super.updateLayer()
        updateColors()
    }
    
    private func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.65).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.35, alpha: 0.35).cgColor
        } else {
            layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.75).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.85, alpha: 0.8).cgColor
        }
    }
}

// MARK: - Main Window Controller
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let client = WOMicClient()
    private var devices: [AudioOutputDevice] = []
    
    // UI Elements
    private let statusBadge = NSTextField(labelWithString: "Готов к подключению")
    private let transportControl = NSSegmentedControl(labels: ["Wi-Fi", "Bluetooth", "USB (ADB)"], trackingMode: .selectOne, target: nil, action: nil)
    private let ipField = NSTextField()
    private let devicePopup = NSPopUpButton()
    private let vuMeter = ModernVUMeterView()
    private let vuDbLabel = NSTextField(labelWithString: "-∞ dB")
    private let connectButton = NSButton()
    private let statsLabel = NSTextField(labelWithString: "Время: 00:00:00  •  Битрейт: 0.0 kbps  •  Opus 48 kHz")
    private let volumeSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.5, target: nil, action: nil)
    private let volumePercentLabel = NSTextField(labelWithString: "100%")
    private let routingStatusLabel = NSTextField(labelWithString: "Маршрутизация")
    private let quickVirtualBtn = NSButton()
    private let quickSpeakerBtn = NSButton()
    private let logLabel = NSTextField(labelWithString: "Введите IP телефона из приложения WO Mic и нажмите Подключить.")
    
    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.delegate = self
        setupUI()
        setupBindings()
        refreshDevices()
    }
    
    private func setupUI() {
        guard let window = window else { return }
        window.title = "WO Mic"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        
        // Visual Effect Background (macOS Blur Glass)
        let visualEffectView = NSVisualEffectView(frame: window.contentRect(forFrameRect: window.frame))
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]
        window.contentView = visualEffectView
        
        let root = NSView(frame: visualEffectView.bounds)
        root.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(root)
        
        var y: CGFloat = 540
        
        // Header Icon & Title
        let iconLabel = NSTextField(labelWithString: "🎙")
        iconLabel.font = NSFont.systemFont(ofSize: 26)
        iconLabel.frame = NSRect(x: 24, y: y - 2, width: 36, height: 34)
        root.addSubview(iconLabel)
        
        let titleLabel = NSTextField(labelWithString: "WO Mic")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.frame = NSRect(x: 64, y: y + 4, width: 120, height: 26)
        root.addSubview(titleLabel)
        
        let subtitleLabel = NSTextField(labelWithString: "macOS Studio Edition")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 65, y: y - 10, width: 150, height: 16)
        root.addSubview(subtitleLabel)
        
        statusBadge.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusBadge.alignment = .right
        statusBadge.textColor = .secondaryLabelColor
        statusBadge.frame = NSRect(x: 220, y: y + 4, width: 216, height: 22)
        root.addSubview(statusBadge)
        
        y -= 25
        
        // ==========================================
        // CARD 1: Connection Settings
        // ==========================================
        let card1Height: CGFloat = 115
        y -= card1Height
        let card1 = ModernCardView(frame: NSRect(x: 20, y: y, width: 420, height: card1Height))
        root.addSubview(card1)
        
        let c1Title = NSTextField(labelWithString: "📡  ПОДКЛЮЧЕНИЕ К ТЕЛЕФОНУ")
        c1Title.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        c1Title.textColor = .secondaryLabelColor
        c1Title.frame = NSRect(x: 14, y: card1Height - 24, width: 280, height: 14)
        card1.addSubview(c1Title)
        
        transportControl.frame = NSRect(x: 14, y: card1Height - 56, width: 392, height: 24)
        transportControl.selectedSegment = 0
        transportControl.target = self
        transportControl.action = #selector(transportChanged)
        card1.addSubview(transportControl)
        
        let ipLabel = NSTextField(labelWithString: "IP адрес:")
        ipLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        ipLabel.frame = NSRect(x: 14, y: 18, width: 70, height: 18)
        card1.addSubview(ipLabel)
        
        ipField.frame = NSRect(x: 90, y: 15, width: 316, height: 24)
        ipField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var savedIP = UserDefaults.standard.string(forKey: "womic_last_ip") ?? "192.168.1.102"
        if savedIP == "192.168.1.100" || savedIP == "192.168.1.103" {
            savedIP = "192.168.1.102"
            UserDefaults.standard.set("192.168.1.102", forKey: "womic_last_ip")
        }
        ipField.stringValue = savedIP
        ipField.placeholderString = "Например: 192.168.1.102"
        card1.addSubview(ipField)
        
        y -= 14
        
        // ==========================================
        // CARD 2: Audio Routing (Output Target)
        // ==========================================
        let card2Height: CGFloat = 135
        y -= card2Height
        let card2 = ModernCardView(frame: NSRect(x: 20, y: y, width: 420, height: card2Height))
        root.addSubview(card2)
        
        let c2Title = NSTextField(labelWithString: "🎙  МАРШРУТИЗАЦИЯ ЗВУКА")
        c2Title.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        c2Title.textColor = .secondaryLabelColor
        c2Title.frame = NSRect(x: 14, y: card2Height - 24, width: 280, height: 14)
        card2.addSubview(c2Title)
        
        // Quick switch buttons
        quickVirtualBtn.title = "🎙 В микрофон (VB-Cable)"
        quickVirtualBtn.bezelStyle = .rounded
        quickVirtualBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        quickVirtualBtn.frame = NSRect(x: 14, y: card2Height - 56, width: 192, height: 26)
        quickVirtualBtn.target = self
        quickVirtualBtn.action = #selector(selectVirtualMic)
        card2.addSubview(quickVirtualBtn)
        
        quickSpeakerBtn.title = "🎧 В динамики/наушники"
        quickSpeakerBtn.bezelStyle = .rounded
        quickSpeakerBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        quickSpeakerBtn.frame = NSRect(x: 214, y: card2Height - 56, width: 192, height: 26)
        quickSpeakerBtn.target = self
        quickSpeakerBtn.action = #selector(selectSpeakers)
        card2.addSubview(quickSpeakerBtn)
        
        let devDropLabel = NSTextField(labelWithString: "Устройство:")
        devDropLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        devDropLabel.textColor = .secondaryLabelColor
        devDropLabel.frame = NSRect(x: 14, y: 44, width: 75, height: 16)
        card2.addSubview(devDropLabel)
        
        devicePopup.frame = NSRect(x: 90, y: 40, width: 316, height: 24)
        devicePopup.target = self
        devicePopup.action = #selector(deviceSelected)
        card2.addSubview(devicePopup)
        
        routingStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        routingStatusLabel.textColor = .systemGreen
        routingStatusLabel.frame = NSRect(x: 14, y: 14, width: 392, height: 18)
        card2.addSubview(routingStatusLabel)
        
        y -= 14
        
        // ==========================================
        // CARD 3: Signal Levels & Volume
        // ==========================================
        let card3Height: CGFloat = 110
        y -= card3Height
        let card3 = ModernCardView(frame: NSRect(x: 20, y: y, width: 420, height: card3Height))
        root.addSubview(card3)
        
        let c3Title = NSTextField(labelWithString: "🎚  УРОВЕНЬ СИГНАЛА И ГРОМКОСТЬ")
        c3Title.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        c3Title.textColor = .secondaryLabelColor
        c3Title.frame = NSRect(x: 14, y: card3Height - 24, width: 280, height: 14)
        card3.addSubview(c3Title)
        
        // VU Meter View
        vuMeter.frame = NSRect(x: 14, y: card3Height - 52, width: 330, height: 18)
        card3.addSubview(vuMeter)
        
        vuDbLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        vuDbLabel.textColor = .secondaryLabelColor
        vuDbLabel.alignment = .right
        vuDbLabel.frame = NSRect(x: 348, y: card3Height - 52, width: 58, height: 18)
        card3.addSubview(vuDbLabel)
        
        let volLabel = NSTextField(labelWithString: "Усиление:")
        volLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        volLabel.textColor = .secondaryLabelColor
        volLabel.frame = NSRect(x: 14, y: 16, width: 65, height: 16)
        card3.addSubview(volLabel)
        
        volumeSlider.frame = NSRect(x: 82, y: 13, width: 275, height: 20)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        card3.addSubview(volumeSlider)
        
        volumePercentLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        volumePercentLabel.alignment = .right
        volumePercentLabel.frame = NSRect(x: 358, y: 16, width: 48, height: 16)
        card3.addSubview(volumePercentLabel)
        
        y -= 20
        
        // ==========================================
        // Action Area: Big Connect Button
        // ==========================================
        connectButton.title = "🟢  Подключить микрофон"
        connectButton.bezelStyle = .regularSquare
        connectButton.isBordered = false
        connectButton.wantsLayer = true
        connectButton.layer?.cornerRadius = 10
        connectButton.layer?.masksToBounds = true
        connectButton.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        connectButton.frame = NSRect(x: 20, y: y - 44, width: 420, height: 44)
        connectButton.target = self
        connectButton.action = #selector(connectToggled)
        updateConnectButtonAppearance(connected: false)
        root.addSubview(connectButton)
        
        y -= 60
        
        // Live Telemetry bar
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .center
        statsLabel.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        root.addSubview(statsLabel)
        
        y -= 26
        
        // Bottom Hint / Log Label
        logLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        logLabel.textColor = .tertiaryLabelColor
        logLabel.alignment = .center
        logLabel.frame = NSRect(x: 20, y: y, width: 420, height: 28)
        root.addSubview(logLabel)
    }
    
    private func updateConnectButtonAppearance(connected: Bool) {
        connectButton.wantsLayer = true
        let title = connected ? "🔴   Отключить" : "🟢   Подключить микрофон"
        let color = connected ? NSColor(calibratedRed: 0.88, green: 0.22, blue: 0.25, alpha: 1.0) : NSColor(calibratedRed: 0.05, green: 0.50, blue: 0.98, alpha: 1.0)
        connectButton.layer?.backgroundColor = color.cgColor
        
        let attrTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .bold)
            ]
        )
        connectButton.attributedTitle = attrTitle
    }
    
    private func setupBindings() {
        client.onStateChange = { [weak self] state in
            self?.updateStateUI(state)
        }
        
        client.onAudioLevel = { [weak self] level in
            self?.vuMeter.level = level
            if level > 0.01 {
                let dB = 20.0 * log10(Double(level))
                self?.vuDbLabel.stringValue = String(format: "%.0f dB", dB)
            } else {
                self?.vuDbLabel.stringValue = "-∞ dB"
            }
        }
        
        client.onStatsUpdate = { [weak self] stats in
            let secs = Int(stats.duration)
            let h = secs / 3600
            let m = (secs % 3600) / 60
            let s = secs % 60
            let timeStr = String(format: "%02d:%02d:%02d", h, m, s)
            let kbpsStr = String(format: "%.1f", stats.kbps)
            self?.statsLabel.stringValue = "Время: \(timeStr)  •  Битрейт: \(kbpsStr) kbps  •  Opus 48 kHz"
        }
    }
    
    private func updateStateUI(_ state: WOMicState) {
        switch state {
        case .disconnected:
            statusBadge.stringValue = "⚪  Отключено"
            statusBadge.textColor = .secondaryLabelColor
            updateConnectButtonAppearance(connected: false)
            connectButton.isEnabled = true
            ipField.isEnabled = true
            transportControl.isEnabled = true
            vuMeter.level = 0.0
            vuDbLabel.stringValue = "-∞ dB"
            logLabel.stringValue = "Отключено. Нажмите 'Подключить микрофон' для начала."
        case .connecting(let msg):
            statusBadge.stringValue = "🟡  Подключение..."
            statusBadge.textColor = .systemYellow
            connectButton.attributedTitle = NSAttributedString(
                string: "🟡   Подключение...",
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .bold)]
            )
            connectButton.isEnabled = false
            ipField.isEnabled = false
            transportControl.isEnabled = false
            logLabel.stringValue = msg
        case .connected(let msg):
            statusBadge.stringValue = "🟢  Онлайн (Передача звука)"
            statusBadge.textColor = .systemGreen
            updateConnectButtonAppearance(connected: true)
            connectButton.isEnabled = true
            ipField.isEnabled = false
            transportControl.isEnabled = false
            logLabel.stringValue = "\(msg) • Поток Opus 48000 Hz 16-bit Mono активен"
        case .error(let err):
            statusBadge.stringValue = "🔴  Ошибка"
            statusBadge.textColor = .systemRed
            updateConnectButtonAppearance(connected: false)
            connectButton.isEnabled = true
            ipField.isEnabled = true
            transportControl.isEnabled = true
            vuMeter.level = 0.0
            vuDbLabel.stringValue = "-∞ dB"
            logLabel.stringValue = "Ошибка: \(err)"
        }
    }
    
    @objc private func transportChanged() {
        let seg = transportControl.selectedSegment
        if seg == 0 { // WiFi
            ipField.isEnabled = true
            ipField.placeholderString = "Например: 192.168.1.102"
            if ipField.stringValue == "127.0.0.1" {
                ipField.stringValue = UserDefaults.standard.string(forKey: "womic_last_ip") ?? "192.168.1.102"
            }
        } else if seg == 1 { // Bluetooth
            ipField.isEnabled = true
            ipField.placeholderString = "Например: 04:02:1F:2A:95:78"
        } else if seg == 2 { // USB (ADB)
            ipField.stringValue = "127.0.0.1"
            ipField.isEnabled = false
            logLabel.stringValue = "Для USB требуется: 'adb forward tcp:8125 tcp:8125'"
        }
    }
    
    @objc private func volumeChanged() {
        let val = volumeSlider.floatValue
        client.audioEngine.volume = val
        volumePercentLabel.stringValue = "\(Int(round(val * 100)))%"
    }
    
    @objc private func selectVirtualMic() {
        if let idx = devices.firstIndex(where: { $0.isVirtual }) {
            devicePopup.selectItem(at: idx)
            deviceSelected()
        }
    }
    
    @objc private func selectSpeakers() {
        let preferred = devices.firstIndex(where: {
            let lower = $0.name.lowercased()
            return lower.contains("built-in output") || lower.contains("headphone") || lower.contains("speakers")
        }) ?? devices.firstIndex(where: { !$0.isVirtual })
        
        if let idx = preferred {
            devicePopup.selectItem(at: idx)
            deviceSelected()
        }
    }
    
    @objc private func deviceSelected() {
        let idx = devicePopup.indexOfSelectedItem
        guard idx >= 0, idx < devices.count else { return }
        let selected = devices[idx]
        client.audioEngine.selectedDeviceUID = selected.uid
        
        if selected.isVirtual {
            routingStatusLabel.stringValue = "✅ Режим виртуального микрофона (для Discord, Telegram, Zoom)"
            routingStatusLabel.textColor = .systemGreen
        } else {
            routingStatusLabel.stringValue = "🎧 Режим прослушивания: звук выводится в динамики / наушники"
            routingStatusLabel.textColor = .systemOrange
        }
    }
    
    private func refreshDevices() {
        devices = AudioEngine.getOutputDevices()
        devicePopup.removeAllItems()
        
        var virtualIndex = -1
        for (i, d) in devices.enumerated() {
            let label = d.isVirtual ? "⭐ \(d.name) [Виртуальный микрофон]" : "🔊 \(d.name)"
            devicePopup.addItem(withTitle: label)
            if d.isVirtual && virtualIndex == -1 {
                virtualIndex = i
            }
        }
        
        if virtualIndex != -1 {
            devicePopup.selectItem(at: virtualIndex)
            client.audioEngine.selectedDeviceUID = devices[virtualIndex].uid
            routingStatusLabel.stringValue = "✅ Режим виртуального микрофона (для Discord, Telegram, Zoom)"
            routingStatusLabel.textColor = .systemGreen
        } else {
            if let first = devices.first {
                client.audioEngine.selectedDeviceUID = first.uid
            }
            routingStatusLabel.stringValue = "🎧 Звук выводится в динамики / наушники"
            routingStatusLabel.textColor = .systemOrange
        }
    }
    
    @objc private func connectToggled() {
        if client.state != .disconnected {
            client.disconnect()
            return
        }
        
        let ip = ipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            logLabel.stringValue = "Пожалуйста, введите IP адрес телефона."
            return
        }
        
        UserDefaults.standard.set(ip, forKey: "womic_last_ip")
        
        let transport: TransportMode
        switch transportControl.selectedSegment {
        case 1: transport = .bluetooth
        case 2: transport = .usb
        default: transport = .wifi
        }
        
        client.connect(host: ip, transport: transport)
    }
    
    public func windowWillClose(_ notification: Notification) {
        client.disconnect()
        NSApp.terminate(nil)
    }
}
