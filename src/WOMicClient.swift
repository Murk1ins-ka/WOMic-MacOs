import Foundation

public enum WOMicState: Equatable {
    case disconnected
    case connecting(String)
    case connected(String)
    case error(String)
}

public enum TransportMode: String, CaseIterable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth"
    case usb = "USB (ADB)"
}

public struct AudioStats {
    public var packetsReceived: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var kbps: Double = 0.0
    public var duration: TimeInterval = 0.0
}

public final class WOMicClient {
    public var state: WOMicState = .disconnected {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(self.state)
            }
        }
    }
    
    public var onStateChange: ((WOMicState) -> Void)?
    public var onStatsUpdate: ((AudioStats) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    
    public let audioEngine: AudioEngine
    private var opusDecoder: OpusDecoder?
    
    private var tcpSocket: Int32 = -1
    private var udpSocket: Int32 = -1
    private var isRunning = false
    private var workerThread: Thread?
    
    private var stats = AudioStats()
    private var startTime: Date?
    private var lastBitrateCalcTime: Date?
    private var bytesSinceLastCalc: UInt64 = 0
    
    public init(audioEngine: AudioEngine = AudioEngine()) {
        self.audioEngine = audioEngine
        self.audioEngine.onLevelMeter = { [weak self] level in
            self?.onAudioLevel?(level)
        }
    }
    
    deinit {
        disconnect()
    }
    
    public func connect(host: String, controlPort: UInt16 = 8125, mediaPort: UInt16 = 49152, transport: TransportMode = .wifi) {
        if state != .disconnected {
            disconnect()
        }
        
        state = .connecting("Connecting to \(host):\(controlPort)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.runConnection(host: host, controlPort: controlPort, mediaPort: mediaPort, transport: transport)
        }
    }
    
    public func disconnect() {
        isRunning = false
        if tcpSocket >= 0 {
            shutdown(tcpSocket, SHUT_RDWR)
            close(tcpSocket)
            tcpSocket = -1
        }
        if udpSocket >= 0 {
            shutdown(udpSocket, SHUT_RDWR)
            close(udpSocket)
            udpSocket = -1
        }
        audioEngine.stop()
        opusDecoder?.reset()
        opusDecoder = nil
        state = .disconnected
    }
    
    private func runConnection(host: String, controlPort: UInt16, mediaPort: UInt16, transport: TransportMode) {
        // 1. Prepare UDP socket for media stream
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpSocket >= 0 else {
            state = .error("Failed to create UDP socket")
            return
        }
        
        var reuse: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var rcvBuf: Int32 = 65536
        setsockopt(udpSocket, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        
        var udpAddr = sockaddr_in()
        udpAddr.sin_family = sa_family_t(AF_INET)
        udpAddr.sin_port = mediaPort.bigEndian
        udpAddr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindRes = withUnsafePointer(to: &udpAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(self.udpSocket, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindRes == 0 else {
            close(udpSocket)
            udpSocket = -1
            state = .error("Failed to bind UDP media port \(mediaPort). Is it in use?")
            return
        }
        
        // 2. Connect TCP control socket to phone
        tcpSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard tcpSocket >= 0 else {
            close(udpSocket)
            udpSocket = -1
            state = .error("Failed to create TCP socket")
            return
        }
        
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(tcpSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(tcpSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = controlPort.bigEndian
        
        let ipConv = inet_pton(AF_INET, host, &serverAddr.sin_addr)
        guard ipConv == 1 else {
            close(tcpSocket)
            close(udpSocket)
            tcpSocket = -1
            udpSocket = -1
            state = .error("Invalid IP address format: \(host)")
            return
        }
        
        let connectRes = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(self.tcpSocket, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard connectRes == 0 else {
            close(tcpSocket)
            close(udpSocket)
            tcpSocket = -1
            udpSocket = -1
            state = .error("Could not connect to WO Mic server at \(host):\(controlPort). Check that WO Mic is running on your phone and Wi-Fi IP is correct.")
            return
        }
        
        // 3. Handshake Step 1 (Version check)
        // Command 0x65, payload length 6: [4, 4, 6, 2, 0, 0]
        let p1: [UInt8] = [
            0x65,
            0x00, 0x00, 0x00, 0x06,
            0x04, 0x04, 0x06, 0x02, 0x00, 0x00
        ]
        guard sendAll(tcpSocket, data: p1) else {
            disconnect()
            state = .error("Connection lost during version handshake")
            return
        }
        
        guard let (resp1Cmd, _, resp1Payload) = readPacket(tcpSocket) else {
            disconnect()
            state = .error("Failed to read version handshake response")
            return
        }
        
        if resp1Cmd != 0x65 || resp1Payload.isEmpty || resp1Payload[0] != 0 {
            disconnect()
            state = .error("Server version mismatch or rejected connection (code: \(resp1Payload.first ?? 255))")
            return
        }
        
        // 4. Handshake Step 2 (Setup media & transport)
        // Command 0x66, payload length 6:
        // [format=2 (48kHz 16bit mono), mode=2 (WiFi), port_hi...port_lo]
        let port32 = UInt32(mediaPort)
        let p2: [UInt8] = [
            0x66,
            0x00, 0x00, 0x00, 0x06,
            0x02, // Format: 48000 Hz, 16-bit PCM Mono
            0x02, // Mode: 2 (WiFi)
            UInt8((port32 >> 24) & 0xFF),
            UInt8((port32 >> 16) & 0xFF),
            UInt8((port32 >> 8) & 0xFF),
            UInt8(port32 & 0xFF)
        ]
        
        guard sendAll(tcpSocket, data: p2) else {
            disconnect()
            state = .error("Connection lost during media configuration")
            return
        }
        
        guard let (resp2Cmd, _, resp2Payload) = readPacket(tcpSocket) else {
            disconnect()
            state = .error("Failed to read media setup response")
            return
        }
        
        if resp2Cmd != 0x66 || resp2Payload.isEmpty || resp2Payload[0] != 0 {
            let errCode = Int8(bitPattern: resp2Payload.first ?? 255)
            disconnect()
            if errCode == -20 {
                state = .error("Cannot start mic on phone. Make sure mic permission is granted in WO Mic app.")
            } else {
                state = .error("Media setup failed with error code: \(errCode)")
            }
            return
        }
        
        // 5. Handshake Step 3 (Start streaming)
        // Command 0x67, length 0
        let p3: [UInt8] = [
            0x67,
            0x00, 0x00, 0x00, 0x00
        ]
        guard sendAll(tcpSocket, data: p3) else {
            disconnect()
            state = .error("Connection lost starting audio stream")
            return
        }
        
        guard let (resp3Cmd, _, resp3Payload) = readPacket(tcpSocket) else {
            disconnect()
            state = .error("Failed to read streaming start response")
            return
        }
        
        if resp3Cmd != 0x67 || (!resp3Payload.isEmpty && resp3Payload[0] != 0) {
            disconnect()
            state = .error("Server failed to start streaming")
            return
        }
        
        // 6. Audio Engine Start
        opusDecoder = OpusDecoder()
        opusDecoder?.reset()
        
        guard audioEngine.start() else {
            disconnect()
            state = .error("Failed to start CoreAudio engine")
            return
        }
        
        isRunning = true
        startTime = Date()
        lastBitrateCalcTime = Date()
        bytesSinceLastCalc = 0
        stats = AudioStats()
        
        state = .connected("Streaming from \(host)")
        
        // 7. Receive Audio Packets Loop
        var udpTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(udpSocket, SOL_SOCKET, SO_RCVTIMEO, &udpTimeout, socklen_t(MemoryLayout<timeval>.size))
        
        let bufCapacity = 4096
        var buffer = [UInt8](repeating: 0, count: bufCapacity)
        
        while isRunning {
            let received = recv(udpSocket, &buffer, bufCapacity, 0)
            if received > 0 {
                stats.packetsReceived += 1
                stats.bytesReceived += UInt64(received)
                bytesSinceLastCalc += UInt64(received)
                
                // Decode incoming WO Mic audio packets
                if received == 1920 {
                    // Direct uncompressed PCM frame fallback
                    audioEngine.pushPCMData(Data(buffer[0..<received]))
                } else if buffer[0] == 4 && received > 11 {
                    // Standard WO Mic UDP audio packet:
                    // Byte 0: 0x04 (CMD_AUDIO)
                    // Bytes 1..3: Length of payload (24-bit big endian integer)
                    // Bytes 4..5: Packet sequence number (16-bit)
                    // Bytes 6..9: Timestamp (32-bit)
                    // Byte 10: Flags / mode (8-bit)
                    // Bytes 11..<received: Opus encoded audio payload
                    let opusPayload = Data(buffer[11..<received])
                    if let pcm = opusDecoder?.decode(packet: opusPayload) {
                        audioEngine.pushPCMData(pcm)
                    } else {
                        // Fallback in case of alternative header offset
                        if let pcm = opusDecoder?.decode(packet: Data(buffer[6..<received])) {
                            audioEngine.pushPCMData(pcm)
                        } else if let pcm = opusDecoder?.decode(packet: Data(buffer[0..<received])) {
                            audioEngine.pushPCMData(pcm)
                        }
                    }
                } else if received > 6 {
                    // Packet without the 4-byte transport header
                    if let pcm = opusDecoder?.decode(packet: Data(buffer[6..<received])) {
                        audioEngine.pushPCMData(pcm)
                    } else if let pcm = opusDecoder?.decode(packet: Data(buffer[0..<received])) {
                        audioEngine.pushPCMData(pcm)
                    }
                } else if received > 0 {
                    let opusFrame = Data(buffer[0..<received])
                    if let pcm = opusDecoder?.decode(packet: opusFrame) {
                        audioEngine.pushPCMData(pcm)
                    }
                }
                
                let now = Date()
                if let lastTime = lastBitrateCalcTime, now.timeIntervalSince(lastTime) >= 1.0 {
                    let elapsed = now.timeIntervalSince(lastTime)
                    stats.kbps = (Double(bytesSinceLastCalc * 8) / elapsed) / 1000.0
                    if let start = startTime {
                        stats.duration = now.timeIntervalSince(start)
                    }
                    bytesSinceLastCalc = 0
                    lastBitrateCalcTime = now
                    
                    let currentStats = stats
                    DispatchQueue.main.async { [weak self] in
                        self?.onStatsUpdate?(currentStats)
                    }
                }
            } else if received < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Timeout, keep listening unless stopped
                    continue
                } else if !isRunning {
                    break
                }
            }
        }
        
        disconnect()
    }
    
    private func sendAll(_ fd: Int32, data: [UInt8]) -> Bool {
        var totalSent = 0
        let count = data.count
        while totalSent < count {
            let sent = data.withUnsafeBufferPointer { ptr in
                send(fd, ptr.baseAddress! + totalSent, count - totalSent, 0)
            }
            if sent <= 0 {
                return false
            }
            totalSent += sent
        }
        return true
    }
    
    private func readExact(_ fd: Int32, count: Int) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count {
            let r = result.withUnsafeMutableBufferPointer { ptr in
                recv(fd, ptr.baseAddress! + totalRead, count - totalRead, 0)
            }
            if r <= 0 {
                return nil
            }
            totalRead += r
        }
        return result
    }
    
    private func readPacket(_ fd: Int32) -> (cmd: UInt8, length: UInt32, payload: [UInt8])? {
        guard let cmdBytes = readExact(fd, count: 1) else { return nil }
        let cmd = cmdBytes[0]
        
        guard let lenBytes = readExact(fd, count: 4) else { return nil }
        let length = (UInt32(lenBytes[0]) << 24) |
                     (UInt32(lenBytes[1]) << 16) |
                     (UInt32(lenBytes[2]) << 8)  |
                     UInt32(lenBytes[3])
        
        var payload: [UInt8] = []
        if length > 0 {
            if length > 65536 {
                // Safeguard against corrupted length
                return nil
            }
            guard let p = readExact(fd, count: Int(length)) else { return nil }
            payload = p
        }
        
        return (cmd, length, payload)
    }
}
