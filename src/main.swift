import Cocoa
import Foundation

func printUsage() {
    print("""
Usage: womic [OPTIONS] [ADDRESS]
Options:
   -w [IP]      - to connect via WiFi (e.g. 192.168.1.100)
   -b [ADDR]    - to connect via Bluetooth
   -d [DEVICE]  - route audio to specific output device (e.g. 'BlackHole 2ch')
   -l           - list all available CoreAudio output devices
   -k           - to disconnect any running background instance
   -g           - launch Graphical User Interface (GUI)
   -h           - help (this message)

Running 'womic' without options will launch the macOS GUI application.
""")
}

func listDevices() {
    let devices = AudioEngine.getOutputDevices()
    print("Available macOS Audio Output Devices:")
    for (i, d) in devices.enumerated() {
        let tag = d.isVirtual ? " [VIRTUAL MIC TARGET]" : ""
        print("  [\(i + 1)] \(d.name)\(tag) (UID: \(d.uid))")
    }
    print("")
    let hasBlackHole = devices.contains { $0.isVirtual }
    if hasBlackHole {
        print("✅ Virtual microphone device detected! WO Mic will route audio to it.")
    } else {
        print("💡 Tip: Install BlackHole ('brew install blackhole-2ch') to use your phone as a microphone in Discord, Zoom, etc.")
    }
}

func killRunningInstances() {
    let currentPID = getpid()
    let pipe = Pipe()
    let process = Process()
    process.launchPath = "/bin/bash"
    process.arguments = ["-c", "ps aux | grep '[w]omic' | awk '{print $2}'"]
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != currentPID }
    
    if pids.isEmpty {
        print("WO Mic is not running!")
        exit(1)
    } else {
        for pid in pids {
            kill(pid, SIGINT)
        }
        print("Sent disconnect signal to WO Mic (PID: \(pids.map { String($0) }.joined(separator: ", "))).")
        exit(0)
    }
}

func runCLI(mode: TransportMode, targetAddress: String?, deviceName: String?) {
    var address = targetAddress ?? ""
    if address.isEmpty {
        if mode == .wifi {
            print("(Example: 192.168.0.100)")
            print("Enter device IP: ", terminator: "")
            fflush(stdout)
            address = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else if mode == .bluetooth {
            print("(Format: xx:xx:xx:xx:xx:xx)")
            print("Enter device address: ", terminator: "")
            fflush(stdout)
            address = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
    
    guard !address.isEmpty else {
        print("Error: Device address cannot be empty.")
        exit(1)
    }
    
    let client = WOMicClient()
    
    // Choose output device
    let devices = AudioEngine.getOutputDevices()
    if let devName = deviceName {
        if let match = devices.first(where: { $0.name.lowercased().contains(devName.lowercased()) }) {
            client.audioEngine.selectedDeviceUID = match.uid
            print("Routing audio to specified device: \(match.name)")
        } else {
            print("Warning: Device '\(devName)' not found. Using default output.")
        }
    } else if let virtual = devices.first(where: { $0.isVirtual }) {
        client.audioEngine.selectedDeviceUID = virtual.uid
        print("Routing audio to virtual microphone: \(virtual.name)")
    } else {
        print("Routing audio to default output. (Install BlackHole 2ch for virtual mic support)")
    }
    
    // Setup signal handler for clean Ctrl+C
    signal(SIGINT) { _ in
        print("\nDisconnecting...")
        exit(0)
    }
    
    client.onStateChange = { state in
        switch state {
        case .disconnected:
            print("Status: Disconnected")
        case .connecting(let msg):
            print("Status: \(msg)")
        case .connected(let msg):
            print("Status: ✅ \(msg) (48kHz Mono 16-bit PCM)")
            print("Press Ctrl+C or run 'womic -k' to disconnect.\n")
        case .error(let err):
            print("Status: ❌ Error: \(err)")
            exit(1)
        }
    }
    
    client.onStatsUpdate = { stats in
        let secs = Int(stats.duration)
        let m = (secs % 3600) / 60
        let s = secs % 60
        let timeStr = String(format: "%02d:%02d", m, s)
        let kbpsStr = String(format: "%.1f", stats.kbps)
        print("\r[Streaming \(timeStr)] Bitrate: \(kbpsStr) kbps | Packets: \(stats.packetsReceived) ", terminator: "")
        fflush(stdout)
    }
    
    client.connect(host: address, transport: mode)
    
    // Keep CLI runloop alive
    RunLoop.main.run()
}

// MARK: - Entry Point
let args = CommandLine.arguments

if args.count == 1 {
    // No arguments: launch GUI
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    var mode: TransportMode?
    var address: String?
    var deviceName: String?
    var shouldLaunchGUI = false
    
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-l", "--list-devices":
            listDevices()
            exit(0)
        case "-k":
            killRunningInstances()
            exit(0)
        case "-g", "--gui":
            shouldLaunchGUI = true
        case "-w":
            mode = .wifi
            if i + 1 < args.count && !args[i + 1].starts(with: "-") {
                address = args[i + 1]
                i += 1
            }
        case "-b":
            mode = .bluetooth
            if i + 1 < args.count && !args[i + 1].starts(with: "-") {
                address = args[i + 1]
                i += 1
            }
        case "-d":
            if i + 1 < args.count {
                deviceName = args[i + 1]
                i += 1
            }
        default:
            if !arg.starts(with: "-") && address == nil {
                address = arg
            } else {
                print("Unknown option: \(arg)")
                printUsage()
                exit(1)
            }
        }
        i += 1
    }
    
    if shouldLaunchGUI || (mode == nil) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    } else if let m = mode {
        runCLI(mode: m, targetAddress: address, deviceName: deviceName)
    }
}
