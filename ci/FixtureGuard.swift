import Foundation
import Darwin

func fixtureHostname() -> String {
    var bytes = [CChar](repeating: 0, count: 256)
    guard gethostname(&bytes, bytes.count) == 0 else { return "" }
    return String(cString: bytes)
}
func fixtureReadObject(_ path: String) -> [String: Any]? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o077 == 0,
      let data = FileManager.default.contents(atPath: path), data.count < 65536,
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return result
}
func fixtureControl() -> [String: Any]? {
    guard fixtureRunID != "compile-only", getuid() != 0, getuid() == geteuid(),
      fixtureHostname() == fixtureExpectedHostname,
      URL(fileURLWithPath: fixtureRunRoot).resolvingSymlinksInPath().path == fixtureRunRoot,
      let guardObject = fixtureReadObject(fixtureRunRoot + "/guard.json"),
      guardObject["runID"] as? String == fixtureRunID,
      guardObject["token"] as? String == fixtureToken,
      guardObject["uid"] as? UInt32 == getuid(),
      guardObject["host"] as? String == fixtureExpectedHostname,
      guardObject["githubHosted"] as? Bool == true,
      guardObject["runnerOS"] as? String == "macOS",
      let object = fixtureReadObject(fixtureControlPath),
      object["token"] as? String == fixtureToken,
      object["runID"] as? String == fixtureRunID,
      object["bundleID"] as? String == fixtureBundleID,
      let phase = object["phase"] as? String, ["A1", "B", "A2"].contains(phase),
      let output = object["outputDirectory"] as? String,
      output.hasPrefix(fixtureRunRoot + "/evidence/"),
      URL(fileURLWithPath: output).resolvingSymlinksInPath().path == output,
      FileManager.default.fileExists(atPath: output),
      Bundle(path: fixtureAppPath)?.bundleIdentifier == fixtureBundleID else { return nil }
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0,
      fixtureExecutablePaths.contains(URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path) else { return nil }
    return object
}
