import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import Darwin

// CI-only selected application fixture. Its SCStream proves only this fixture.
// Adapted from miha1744/macos-native-menubar-probe ci/CaptureProbe.swift.
final class Frames: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var count = 0
    private var latest: CVPixelBuffer?
    private var streamError: String?
    private var animatedRect = CGRect.zero
    private var animatedChanges = 0
    private var lastAnimatedHash: UInt64?
    func configureAnimationRect(_ rect: CGRect) { lock.lock(); animatedRect = rect; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        count += 1; latest = buffer
        let rect = animatedRect
        if !rect.isEmpty, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess {
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                var hash: UInt64 = 14695981039346656037
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<8 { for col in 0..<8 {
                    let x = max(0, min(width - 1, Int(rect.minX + rect.width * Double(col + 1) / 9)))
                    let y = max(0, min(height - 1, Int(rect.minY + rect.height * Double(row + 1) / 9)))
                    for channel in 0..<3 { hash = (hash ^ UInt64(bytes[y * rowBytes + x * 4 + channel])) &* 1099511628211 }
                }}
                if let previous = lastAnimatedHash, previous != hash { animatedChanges += 1 }
                lastAnimatedHash = hash
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamError = error.localizedDescription; lock.unlock()
    }
    func snapshot() -> (Int, CVPixelBuffer?, String?, Int, String) {
        lock.lock(); defer { lock.unlock() }; return (count, latest, streamError, animatedChanges, lastAnimatedHash.map { String($0, radix: 16) } ?? "")
    }
}

@MainActor
final class ApplicationFixture: NSObject, NSApplicationDelegate {
    let frames = Frames()
    let context = CIContext(options: [.useSoftwareRenderer: true])
    var root: URL!
    var control: [String: Any] = [:]
    var stream: SCStream?
    var window: NSWindow?
    var timer: Timer?
    var bounds = CGRect.zero

    func write(_ name: String, _ object: [String: Any]) {
        guard let root else { return }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }
    func marker(_ name: String) { try? Data().write(to: root.appendingPathComponent(name), options: .atomic) }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let verified = fixtureControl() else { NSApp.terminate(nil); return }
        control = verified
        root = URL(fileURLWithPath: verified["outputDirectory"] as! String)
        write("app-process.json", ["pid": getpid(), "parentPID": getppid(), "bundleID": fixtureBundleID,
          "phase": verified["phase"] ?? "", "executablePath": ProcessInfo.processInfo.arguments[0],
          "captureSubject": "Selected CI fixture own SCStream only", "captureVerified": false, "indicatorVerified": false])
        let panel = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 470, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "QuietBar CI selected application fixture"
        let label = NSTextField(wrappingLabelWithString: "Hosted CI fixture only.\nAnimation verifies changing captured pixels.\nNo third-party application compatibility claim.")
        label.frame = NSRect(x: 20, y: 35, width: 425, height: 100)
        panel.contentView?.addSubview(label)
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window = panel
        var alternate = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            alternate.toggle()
            panel.backgroundColor = alternate ? NSColor(calibratedWhite: 0.85, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
        }
        Task { await run() }
    }
    func windows() -> [[String: Any]] {
        guard let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return all.compactMap { item in
            guard let raw = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  rect.intersects(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 80)) else { return nil }
            let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let name = item[kCGWindowName as String] as? String ?? ""
            let onScreen = item[kCGWindowIsOnscreen as String] as? Bool ?? false
            let alpha = item[kCGWindowAlpha as String] as? Double ?? 1
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            let systemOwner = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.menubaragent"].contains(bundle.lowercased())
            let targetName = name.localizedCaseInsensitiveContains("AudioVideoModule") || name.localizedCaseInsensitiveContains("Audio and Video Controls")
            let target = systemOwner && targetName && onScreen && alpha > 0.05 && layer >= 20 && rect.height <= 80 && rect.width <= 400
            return ["id": item[kCGWindowNumber as String] ?? 0, "bundleID": bundle, "name": name,
              "layer": layer, "onScreen": onScreen, "alpha": alpha, "strictTarget": target,
              "bounds": ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]]
        }
    }
    func purpleCount(_ image: CGImage, rect: CGRect) -> Int {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !clipped.isEmpty, let crop = image.cropping(to: clipped) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let ctx = CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
          bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[i]), green = Int(bytes[i + 1]), blue = Int(bytes[i + 2])
            if blue > 145 && red > 55 && blue > green + 40 && red >= green && blue > red + 20 { count += 1 }
        }
        return count
    }
    func snapshot(_ phase: String) -> [String: Any] {
        let (count, buffer, error, changes, hash) = frames.snapshot()
        let metadata = windows()
        write("\(phase)-windows.json", ["windows": metadata])
        let detected = metadata.filter { $0["strictTarget"] as? Bool == true }.compactMap { $0["bounds"] as? [String: Double] }
        let inherited = control["baselineRects"] as? [[String: Double]] ?? []
        let regions = inherited.isEmpty ? detected : inherited
        var result: [String: Any] = ["completeFrames": count, "animatedPixelChanges": changes, "lastAnimatedRegionHashFNV1a64": hash,
          "streamError": error ?? NSNull(), "strictVisibleTargets": detected.count,
          "detectedRects": detected, "measurementRects": regions, "baselineRectsInherited": !inherited.isEmpty,
          "nativeImageSaved": false, "streamImageSaved": false]
        if let buffer, let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent),
           let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(image.height, Int(80 * Double(image.height) / bounds.height)))),
           let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
            do { try png.write(to: root.appendingPathComponent("\(phase)-stream-menubar.png")); result["streamImageSaved"] = true } catch {}
        }
        // Always keep the complete native 80-point menubar strip. Never use an
        // SCStream image as a fallback: macOS may exclude its own indicator.
        let target = root.appendingPathComponent("\(phase)-native-menubar.png")
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),80", target.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do {
            try task.run(); task.waitUntilExit()
            guard task.terminationStatus == 0, let source = CGImageSourceCreateWithURL(target as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return result }
            result["nativeImageSaved"] = true
            result["nativeImageWidth"] = image.width; result["nativeImageHeight"] = image.height
            let sx = Double(image.width) / bounds.width, sy = Double(image.height) / 80
            result["regionPurplePixels"] = regions.reduce(0) { total, r in
                total + purpleCount(image, rect: CGRect(x: ((r["x"] ?? 0) - bounds.minX) * sx,
                  y: ((r["y"] ?? 0) - bounds.minY) * sy, width: (r["width"] ?? 0) * sx, height: (r["height"] ?? 0) * sy))
            }
            result["wholeNativePurplePixels"] = purpleCount(image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // Scan the entire native strip in 40-point tiles, including areas
            // outside A1 rectangles, so a relocated purple indicator is visible.
            result["wholeNativePurpleTiles"] = stride(from: 0, to: image.width, by: max(1, Int(40 * sx))).map { x in
                ["x": x, "purplePixels": purpleCount(image, rect: CGRect(x: x, y: 0, width: min(Int(40 * sx), image.width - x), height: image.height))]
            }
        } catch {}
        return result
    }
    func finish(_ status: String, _ reason: String, samples: [[String: Any]] = []) async {
        write("capture-result.json", ["schema": 1, "status": status, "reason": reason,
          "phase": control["phase"] ?? "", "bundleID": fixtureBundleID,
          "permissionPreflight": CGPreflightScreenCaptureAccess(), "samples": samples,
          "captureSubject": "Selected CI fixture own SCStream only; no third-party acceptance",
          "manualScreenshotReviewRequired": true])
        marker("measurements-ready")
        // Keep the selected app alive until the driver requests a normal stop.
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-stop").path) { break }
            await pause(1)
        }
        if let stream { try? await stream.stopCapture() }
        timer?.invalidate(); marker("capture-finished"); NSApp.terminate(nil)
    }
    func run() async {
        guard CGPreflightScreenCaptureAccess() else { await finish("INCONCLUSIVE", "Capture preflight denied"); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                await finish("INCONCLUSIVE", "No GUI capture display"); return
            }
            bounds = CGDisplayBounds(display.displayID)
            let config = SCStreamConfiguration()
            config.width = display.width; config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10); config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
            if let frame = window?.frame {
                frames.configureAnimationRect(CGRect(x: (frame.minX - bounds.minX + 10) * Double(display.width) / bounds.width,
                  y: (bounds.height - frame.maxY + 35) * Double(display.height) / bounds.height,
                  width: (frame.width - 20) * Double(display.width) / bounds.width, height: (frame.height - 50) * Double(display.height) / bounds.height))
            }
            let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: frames)
            stream = capture
            try capture.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "quietbar.fixture.frames"))
            try await capture.startCapture()
            let start = DispatchTime.now().uptimeNanoseconds
            var samples: [[String: Any]] = []
            for second in [8, 16, 24] {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                await pause(Double(second) - elapsed)
                var sample = snapshot("sample-\(second)s")
                sample["scheduledSecond"] = second
                write("sample-\(second)s.json", sample); samples.append(sample)
            }
            await finish("MEASUREMENT", "Three observations; automated evidence still requires manual native screenshot review", samples: samples)
        } catch { await finish("INCONCLUSIVE", "ScreenCaptureKit error: \(error.localizedDescription)") }
    }
}

@main
struct FixtureMain {
    @MainActor static func main() {
        guard fixtureControl() != nil else { return }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = ApplicationFixture(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}

