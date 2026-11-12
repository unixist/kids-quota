#!/usr/bin/env swift
// Create a private, offline QR image after the relay has its real HTTPS address.
// Usage: swift scripts/phone-pairing-qr.swift /private/path/parent-1.json
import Foundation
import CoreFoundation
import CoreImage
import Darwin

struct PairingQRFailure: Error { let message: String }
func fail(_ message: String) throws -> Never { throw PairingQRFailure(message: message) }
let usage = "Usage: swift scripts/phone-pairing-qr.swift /private/path/parent-1.json"

func canonicalPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { try fail("The connection file's directory could not be opened.") }
    defer { free(resolved) }
    return String(cString: resolved)
}
func hasNoACL(_ fd: Int32) -> Bool {
    // Darwin reports ENOENT for an absent extended ACL and EINVAL when an
    // allocated ACL has no first entry. A successful entry lookup returns zero.
    guard let acl = acl_get_fd(fd) else { return errno == ENOENT }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
}
func privateIdentity(_ fd: Int32, directory: Bool) -> Bool {
    var info = stat()
    return fstat(fd, &info) == 0 && info.st_uid == getuid()
        && info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
        && info.st_mode & 0o777 == (directory ? 0o700 : 0o600)
        && hasNoACL(fd)
}
func readDocument(_ fd: Int32) throws -> Data {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { try fail("The private connection file could not be read.") }
        if count == 0 { break }
        guard data.count + count <= 16_384 else { try fail("The connection document is too large.") }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}
func validPort(_ components: URLComponents) -> Bool {
    guard let representation = components.string else { return false }
    if let range = components.rangeOfPort {
        let raw = representation[range]
        return !raw.isEmpty && raw.utf8.allSatisfy { (48...57).contains($0) }
            && Int(raw).map { (1...65535).contains($0) } == true
    }
    return !representation.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(":")
}
func pairingPayload(_ data: Data) throws -> Data {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["schemaVersion", "endpoint", "familyName", "readToken"],
          let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
          let endpoint = object["endpoint"] as? String, endpoint.utf8.count <= 2048,
          !endpoint.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let parts = URLComponents(string: endpoint), parts.scheme == "https", let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/", validPort(parts),
          !host.contains("%"), parts.url != nil,
          let name = object["familyName"] as? String, !name.isEmpty, name.utf16.count <= 100,
          name == name.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let token = object["readToken"] as? String,
          token.range(of: "\\A[A-Za-z0-9_-]{32,512}\\z", options: .regularExpression) != nil else {
        try fail("Use a valid iPhone connection JSON document with an HTTPS origin; a Mac connection document cannot pair a phone.")
    }
    let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let reserved = ["invalid", "example", "test", "localhost", "example.com", "example.net", "example.org"]
    guard !reserved.contains(where: { normalizedHost == $0 || normalizedHost.hasSuffix("." + $0) }) else {
        try fail("Set the real deployed relay address in the connection document before generating its QR code.")
    }
    let compact = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let encoded = compact.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return Data(("kidsquota://pair?data=" + encoded).utf8)
}
func png(_ payload: Data) throws -> Data {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { try fail("QR generation is unavailable on this Mac.") }
    filter.setValue(payload, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = filter.outputImage else { try fail("This connection is too large for a QR code. Use the app's file import instead.") }
    // Four white modules on every side and integer scaling keep camera scans clear.
    let frame = CGRect(x: 0, y: 0, width: code.extent.width + 8, height: code.extent.height + 8)
    let image = code.transformed(by: CGAffineTransform(translationX: 4, y: 4))
        .composited(over: CIImage(color: .white).cropped(to: frame))
        .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let context = CIContext(options: [.useSoftwareRenderer: true])
    guard let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
        try fail("The QR image could not be generated.")
    }
    return data
}
func run() throws {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else { try fail(usage) }
    let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    guard input.pathExtension.lowercased() == "json" else { try fail("Choose an iPhone connection JSON file.") }
    let requestedParent = input.deletingLastPathComponent()
    var parentInfo = stat()
    guard lstat(requestedParent.path, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
        try fail("The connection directory must be a private directory, not a symbolic link.")
    }
    let parentPath = try canonicalPath(requestedParent.path)
    let repository = try canonicalPath(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path)
    guard parentPath != repository, !parentPath.hasPrefix(repository + "/") else {
        try fail("Connection documents and QR images must be stored outside the repository.")
    }
    let directory = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { try fail("The private connection directory could not be opened.") }
    defer { close(directory) }
    guard privateIdentity(directory, directory: true) else {
        try fail("The connection directory must belong to you, have permissions 0700, and have no shared access entries.")
    }
    let source = openat(directory, input.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard source >= 0 else { try fail("The private connection file could not be opened; symbolic links are not allowed.") }
    defer { close(source) }
    guard privateIdentity(source, directory: false) else {
        try fail("The connection file must belong to you, have permissions 0600, and have no shared access entries.")
    }
    let payload = try pairingPayload(readDocument(source))
    let data = try png(payload)
    let outputName = input.deletingPathExtension().lastPathComponent + ".png"
    let output = openat(directory, outputName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard output >= 0 else { try fail("The QR output already exists or cannot be created. Existing files and symbolic links are never overwritten.") }
    var complete = false
    defer { close(output); if !complete { unlinkat(directory, outputName, 0) } }
    guard fchmod(output, 0o600) == 0, let emptyACL = acl_init(0) else { try fail("The QR image's private permissions could not be set.") }
    defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
    guard acl_set_fd(output, emptyACL) == 0 else { try fail("The QR image's private permissions could not be set.") }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { try fail("The private QR image could not be saved.") }
            offset += count
        }
    }
    guard fsync(output) == 0 else { try fail("The private QR image could not be saved.") }
    complete = true
    print("Created a private PNG beside the connection JSON. Open it on this Mac and scan it with the parent's iPhone Camera. Keep the image private.")
}
do { try run() }
catch let error as PairingQRFailure { fputs(error.message + "\n", stderr); exit(1) }
catch { fputs("The private QR image could not be generated.\n", stderr); exit(1) }
