// vzrun: minimal Apple Virtualization.framework launcher for UEFI guests.
//
//   vzrun --disk build/esp.img [--nvram build/vz-nvram.bin] [--gui]
//         [--timeout N] [--width W --height H] [--cpus N] [--mem MiB]
//         [--screenshot SECS FILE.png] [--no-gpu] [--no-input]
//
// The serial port (virtio-console) is wired to our stdin/stdout.  Status
// messages from the launcher go to stderr, prefixed with "[vzrun]".
import AppKit
import Foundation
import Virtualization

func log(_ s: String) {
    FileHandle.standardError.write(("[vzrun] " + s + "\n").data(using: .utf8)!)
}

struct Options {
    var disk = "build/esp.img"
    var nvram = "build/vz-nvram.bin"
    var gui = false
    var timeout = 0
    var width = 1024
    var height = 768
    var cpus = 2
    var memMiB = 1024
    var gpu = true
    var input = true
    var shots: [(Int, String)] = []
}

func usage() -> Never {
    log("usage: vzrun --disk IMG [--nvram FILE] [--gui] [--timeout N] [--width W --height H] [--cpus N] [--mem MiB] [--screenshot SECS FILE]... [--no-gpu] [--no-input]")
    exit(2)
}

func parseArgs() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    func next() -> String {
        if a.isEmpty { usage() }
        return a.removeFirst()
    }
    while !a.isEmpty {
        let k = a.removeFirst()
        switch k {
        case "--disk": o.disk = next()
        case "--nvram": o.nvram = next()
        case "--gui": o.gui = true
        case "--timeout": o.timeout = Int(next()) ?? 0
        case "--width": o.width = Int(next()) ?? 1024
        case "--height": o.height = Int(next()) ?? 768
        case "--cpus": o.cpus = Int(next()) ?? 2
        case "--mem": o.memMiB = Int(next()) ?? 1024
        case "--no-gpu": o.gpu = false
        case "--no-input": o.input = false
        case "--screenshot":
            let secs = Int(next()) ?? 0
            o.shots.append((secs, next()))
        default: usage()
        }
    }
    return o
}

func makeConfig(_ o: Options) throws -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    c.cpuCount = o.cpus
    c.memorySize = UInt64(o.memMiB) * 1024 * 1024
    c.platform = VZGenericPlatformConfiguration()

    let nvramURL = URL(fileURLWithPath: o.nvram)
    let store: VZEFIVariableStore
    if FileManager.default.fileExists(atPath: o.nvram) {
        store = VZEFIVariableStore(url: nvramURL)
    } else {
        store = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL, options: [])
        log("created EFI variable store \(o.nvram)")
    }
    let boot = VZEFIBootLoader()
    boot.variableStore = store
    c.bootLoader = boot

    let att = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: o.disk), readOnly: false)
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: att)]

    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput)
    c.serialPorts = [serial]

    if o.gpu {
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: o.width, heightInPixels: o.height)]
        c.graphicsDevices = [gpu]
    }
    if o.input {
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }
    try c.validate()
    return c
}

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) {
        log("guest stopped (powered off)")
        exit(0)
    }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)")
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

// Screenshot our own window with the system screencapture tool (-l WINDOWID).
// Note: NSView.cacheDisplay and the VM view's IOSurface come back black/blank
// for the Metal-backed VZVirtualMachineView, so they are not used.
func takeScreenshot(window: NSWindow, view: NSView, file: String) {
    let wid = window.windowNumber
    // screencapture can fail with "could not create image from window" when the
    // window is not currently on screen; bring it forward and retry.
    for attempt in 1...4 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(wid), file]
        do {
            try p.run()
            p.waitUntilExit()
            log("screencapture -l \(wid) attempt \(attempt) exit=\(p.terminationStatus) -> \(file)")
            if p.terminationStatus == 0 { break }
        } catch {
            log("screencapture failed: \(error)")
            break
        }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Thread.sleep(forTimeInterval: 0.5)
    }
    log("window visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace) occlusion=\(window.occlusionState.rawValue) frame=\(window.frame)")
}

@main
struct Main {
    static func main() {
        let o = parseArgs()
        let config: VZVirtualMachineConfiguration
        do { config = try makeConfig(o) } catch {
            log("configuration error: \(error)")
            exit(1)
        }
        let vm = VZVirtualMachine(configuration: config)
        let del = Delegate()
        vm.delegate = del

        if o.timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(o.timeout)) {
                log("timeout \(o.timeout)s reached, stopping VM")
                if vm.canStop {
                    vm.stop { err in
                        log("stop -> \(err.map { "\($0)" } ?? "ok")")
                        exit(3)
                    }
                } else {
                    exit(3)
                }
            }
        }

        func start() {
            vm.start { result in
                switch result {
                case .success: log("VM started")
                case .failure(let e):
                    log("start failed: \(e)")
                    exit(1)
                }
            }
        }

        if o.gui {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let appDel = AppDelegate()
            app.delegate = appDel
            let rect = NSRect(x: 100, y: 100, width: o.width, height: o.height)
            let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "vzrun"
            let view = VZVirtualMachineView(frame: rect)
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            for (secs, file) in o.shots {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs)) {
                    takeScreenshot(window: win, view: view, file: file)
                }
            }
            DispatchQueue.main.async { start() }
            app.run()
        } else {
            DispatchQueue.main.async { start() }
            dispatchMain()
        }
    }
}
