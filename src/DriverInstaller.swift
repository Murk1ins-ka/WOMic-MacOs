import Cocoa

public final class DriverInstaller {
    public static func isDriverInstalled() -> Bool {
        let halDir = "/Library/Audio/Plug-Ins/HAL"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: halDir) else {
            return false
        }
        return items.contains { name in
            let lower = name.lowercased()
            return lower.contains("vbcable") || lower.contains("blackhole") || lower.contains("cable")
        }
    }
    
    public static func getBundledDriverPath() -> String? {
        // 1. Check in App Bundle Resources/Driver
        if let bundlePath = Bundle.main.path(forResource: "VBCable", ofType: "driver", inDirectory: "Driver") {
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        
        // 2. Check relative to binary directory
        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let candidate1 = execDir + "/driver/VBCable.driver"
        if FileManager.default.fileExists(atPath: candidate1) {
            return candidate1
        }
        
        let candidate2 = execDir + "/WOMic.app/Contents/Resources/Driver/VBCable.driver"
        if FileManager.default.fileExists(atPath: candidate2) {
            return candidate2
        }
        
        let candidate3 = "/Users/murk1ins/Documents/womic-macos/driver/VBCable.driver"
        if FileManager.default.fileExists(atPath: candidate3) {
            return candidate3
        }
        
        return nil
    }
    
    public static func installDriver(completion: @escaping (Bool, String?) -> Void) {
        guard let driverPath = getBundledDriverPath() else {
            completion(false, "Файл встроенного драйвера VBCable.driver не найден.")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            do shell script "mkdir -p /Library/Audio/Plug-Ins/HAL && cp -R '\(driverPath)' /Library/Audio/Plug-Ins/HAL/ && killall -9 coreaudiod" with administrator privileges
            """
            
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(&error)
            
            if let err = error {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Отменено пользователем"
                DispatchQueue.main.async {
                    completion(false, msg)
                }
                return
            }
            
            // Wait for coreaudiod to restart
            Thread.sleep(forTimeInterval: 2.0)
            
            DispatchQueue.main.async {
                completion(true, nil)
            }
        }
    }
}
