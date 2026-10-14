import Foundation
import AudioToolbox
import CoreAudio

public struct AudioOutputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let isVirtual: Bool
    
    public init(id: AudioDeviceID, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
        let lower = name.lowercased()
        self.isVirtual = lower.contains("blackhole") || lower.contains("loopback") || lower.contains("soundflower") || lower.contains("vb-cable") || lower.contains("virtual")
    }
}

public final class AudioEngine {
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private let bufferCount = 4
    private let bufferSize: UInt32 = 1920 // 20ms of 48kHz 16-bit mono PCM (960 samples = 1920 bytes)
    
    private let ringLock = NSLock()
    private var ringBuffer = Data()
    private let maxRingBufferSize = 1920 * 20 // ~400ms maximum buffer to keep latency low
    
    private var isFirstBuffer = true
    private var wasUnderrun = false
    private var lastMeterLevel: Float = 0.0
    
    public var selectedDeviceUID: String? {
        didSet {
            guard selectedDeviceUID != nil else { return }
            if isRunning {
                // Restart queue cleanly with the new device
                _ = restartQueue()
            }
        }
    }
    
    public var volume: Float = 1.0
    public var onLevelMeter: ((Float) -> Void)?
    
    private var isRunning = false
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public static func getOutputDevices() -> [AudioOutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devIDs = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devIDs)
        guard getStatus == noErr else { return [] }
        
        var devices: [AudioOutputDevice] = []
        
        for id in devIDs {
            // Check if device has output streams
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
            if streamStatus != noErr || streamSize == 0 {
                continue // Input only device
            }
            
            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameCF: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &nameCF) { ptr in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, ptr)
            }
            let name = (nameStatus == noErr) ? (nameCF as String) : "Audio Device \(id)"
            
            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, ptr)
            }
            let uid = (uidStatus == noErr) ? (uidCF as String) : "\(id)"
            
            devices.append(AudioOutputDevice(id: id, name: name, uid: uid))
        }
        
        return devices
    }
    
    public func start() -> Bool {
        guard !isRunning else { return true }
        
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        let callback: AudioQueueOutputCallback = { userData, inAQ, inBuffer in
            guard let userData = userData else { return }
            let engine = Unmanaged<AudioEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.handleQueueCallback(inAQ: inAQ, inBuffer: inBuffer)
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(&format, callback, selfPtr, nil, nil, 0, &queue)
        guard status == noErr, let q = queue else {
            print("[AudioEngine] Error creating AudioQueue: \(status)")
            return false
        }
        
        if let uid = selectedDeviceUID {
            var cfUID: CFString = uid as CFString
            _ = withUnsafePointer(to: &cfUID) { ptr in
                AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, ptr, UInt32(MemoryLayout<CFString>.size))
            }
        }
        
        isFirstBuffer = true
        wasUnderrun = false
        lastMeterLevel = 0.0
        
        buffers.removeAll()
        for _ in 0..<bufferCount {
            var buf: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, bufferSize, &buf)
            if let b = buf {
                memset(b.pointee.mAudioData, 0, Int(bufferSize))
                b.pointee.mAudioDataByteSize = bufferSize
                buffers.append(b)
                AudioQueueEnqueueBuffer(q, b, 0, nil)
            }
        }
        
        let startStatus = AudioQueueStart(q, nil)
        guard startStatus == noErr else {
            print("[AudioEngine] Error starting AudioQueue: \(startStatus)")
            return false
        }
        
        isRunning = true
        return true
    }
    
    private func restartQueue() -> Bool {
        guard isRunning else { return true }
        stop()
        return start()
    }
    
    public func stop() {
        guard isRunning, let q = queue else { return }
        isRunning = false
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        queue = nil
        buffers.removeAll()
        ringLock.lock()
        ringBuffer.removeAll()
        isFirstBuffer = true
        wasUnderrun = false
        ringLock.unlock()
    }
    
    public func pushPCMData(_ data: Data) {
        guard isRunning, !data.isEmpty else { return }
        
        // Calculate audio RMS and peak level for meter
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let sampleCount = data.count / 2
            if sampleCount > 0 {
                var sumSquares: Double = 0
                var maxSample: Int16 = 0
                for i in 0..<sampleCount {
                    let s = ptr[i]
                    if abs(s) > maxSample { maxSample = abs(s) }
                    let norm = Double(s) / 32768.0
                    sumSquares += norm * norm
                }
                let rms = sqrt(sumSquares / Double(sampleCount))
                
                // Convert to dBFS with smooth range (-50 dB ... 0 dB)
                let dB = 20.0 * log10(max(0.0001, rms))
                let normalized = Float(max(0.0, min(1.0, (dB + 46.0) / 42.0)))
                
                // Peak decay for fluid, responsive meter
                lastMeterLevel = max(normalized, lastMeterLevel * 0.82)
                let currentLevel = lastMeterLevel
                
                DispatchQueue.main.async { [weak self] in
                    self?.onLevelMeter?(currentLevel)
                }
            }
        }
        
        ringLock.lock()
        if ringBuffer.count + data.count > maxRingBufferSize {
            // Drop oldest data to prevent unbounded latency
            let excess = (ringBuffer.count + data.count) - maxRingBufferSize
            ringBuffer.removeSubrange(0..<min(excess, ringBuffer.count))
        }
        ringBuffer.append(data)
        ringLock.unlock()
    }
    
    private func handleQueueCallback(inAQ: AudioQueueRef, inBuffer: AudioQueueBufferRef) {
        guard isRunning else { return }
        
        let needed = Int(inBuffer.pointee.mAudioDataBytesCapacity)
        ringLock.lock()
        let available = ringBuffer.count
        
        if available >= needed {
            ringBuffer.copyBytes(to: inBuffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: needed)
            ringBuffer.removeSubrange(0..<needed)
            inBuffer.pointee.mAudioDataByteSize = UInt32(needed)
            
            // Smoothly fade-in first 32 samples (0.6ms) after underrun or start to eliminate pops
            if wasUnderrun || isFirstBuffer {
                wasUnderrun = false
                isFirstBuffer = false
                let samplePtr = inBuffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
                let fadeCount = min(32, needed / 2)
                for i in 0..<fadeCount {
                    let gain = Float(i) / Float(fadeCount)
                    samplePtr[i] = Int16(Float(samplePtr[i]) * gain)
                }
            }
        } else if available > 0 {
            // Partial buffer available: copy available samples and smoothly fade-out tail
            ringBuffer.copyBytes(to: inBuffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: available)
            let samplePtr = inBuffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
            let availableSamples = available / 2
            let fadeCount = min(32, availableSamples)
            let startIndex = availableSamples - fadeCount
            for i in 0..<fadeCount {
                let gain = 1.0 - (Float(i) / Float(fadeCount))
                samplePtr[startIndex + i] = Int16(Float(samplePtr[startIndex + i]) * gain)
            }
            
            // Silence remaining gap
            let dst = inBuffer.pointee.mAudioData.advanced(by: available)
            memset(dst, 0, needed - available)
            ringBuffer.removeAll()
            inBuffer.pointee.mAudioDataByteSize = UInt32(needed)
            wasUnderrun = true
        } else {
            // Silence when starving
            memset(inBuffer.pointee.mAudioData, 0, needed)
            inBuffer.pointee.mAudioDataByteSize = UInt32(needed)
            wasUnderrun = true
        }
        ringLock.unlock()
        
        // Apply volume and soft-knee limiter to prevent clipping
        let sampleCount = Int(inBuffer.pointee.mAudioDataByteSize) / 2
        let ptr = inBuffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        let vol = volume
        let threshold: Float = 28000.0
        let ceiling: Float = 32760.0
        
        for i in 0..<sampleCount {
            var s = Float(ptr[i]) * vol
            if s > threshold {
                let excess = s - threshold
                s = threshold + (ceiling - threshold) * Float(tanh(Double(excess / (ceiling - threshold))))
            } else if s < -threshold {
                let excess = -s - threshold
                s = -(threshold + (ceiling - threshold) * Float(tanh(Double(excess / (ceiling - threshold)))))
            }
            ptr[i] = Int16(clamping: Int(s))
        }
        
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
    }
}
