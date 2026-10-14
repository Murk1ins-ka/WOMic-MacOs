import Foundation
import AudioToolbox

/// High-performance Opus decoder utilizing native macOS AudioToolbox AudioConverter.
/// Decodes 48kHz mono Opus frames sent by the WO Mic client into 16-bit Linear PCM.
public final class OpusDecoder {
    private var converter: AudioConverterRef?
    private let sampleRate: Double = 48000.0
    private let channels: UInt32 = 1
    private let frameSize: UInt32 = 960 // 20ms at 48kHz (960 samples = 1920 bytes)
    
    private final class InputContext {
        var packetData: Data = Data()
        var provided = false
        let packetDescPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        
        deinit {
            packetDescPtr.deallocate()
        }
    }
    
    private let context = InputContext()
    
    public init?() {
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: frameSize,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        let status = AudioConverterNew(&inFormat, &outFormat, &converter)
        guard status == noErr, converter != nil else {
            print("[OpusDecoder] Failed to initialize native AudioConverter: \(status)")
            return nil
        }
    }
    
    deinit {
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
    }
    
    public func reset() {
        if let conv = converter {
            AudioConverterReset(conv)
        }
    }
    
    /// Decodes an Opus packet into 16-bit PCM data.
    /// Returns 1920 bytes (960 samples) of 48kHz 16-bit mono PCM.
    public func decode(packet: Data) -> Data? {
        guard let conv = converter, !packet.isEmpty else { return nil }
        
        context.packetData = packet
        context.provided = false
        context.packetDescPtr.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )
        
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
        
        let inputCallback: AudioConverterComplexInputDataProc = { (converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
            guard let inUserData = inUserData else { return -1 }
            let ctx = Unmanaged<InputContext>.fromOpaque(inUserData).takeUnretainedValue()
            if ctx.provided {
                ioNumberDataPackets.pointee = 0
                return 100 // Signals end of current frame input without triggering EOF
            }
            
            ctx.provided = true
            ioNumberDataPackets.pointee = 1
            
            ioData.pointee.mBuffers.mNumberChannels = 1
            ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.packetData.count)
            ctx.packetData.withUnsafeBytes { raw in
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            }
            
            if let outDesc = outDataPacketDescription {
                outDesc.pointee = ctx.packetDescPtr
            }
            
            return noErr
        }
        
        var pcmBuffer = [Int16](repeating: 0, count: Int(frameSize))
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        outBufferList.mBuffers.mNumberChannels = 1
        outBufferList.mBuffers.mDataByteSize = frameSize * 2
        
        pcmBuffer.withUnsafeMutableBytes { raw in
            outBufferList.mBuffers.mData = raw.baseAddress
        }
        
        var ioOutputPackets: UInt32 = frameSize
        let status = AudioConverterFillComplexBuffer(conv, inputCallback, ctxPtr, &ioOutputPackets, &outBufferList, nil)
        
        if (status == noErr || status == 100) && ioOutputPackets > 0 {
            let byteCount = Int(ioOutputPackets * 2)
            return pcmBuffer.withUnsafeBytes { raw in
                Data(bytes: raw.baseAddress!, count: byteCount)
            }
        }
        
        return nil
    }
}
