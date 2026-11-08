import AppKit

/// Finder's saved icon locations. Only names of visible folders and their icon coordinates
/// are read. No folder contents are opened, and Finder's store is never modified.
enum DesktopFolders {
    static func savedPositions() -> [CGPoint] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
                  at: desktop, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles),
              let data = try? Data(contentsOf: desktop.appendingPathComponent(".DS_Store")),
              data.count >= 8, data.prefix(8) == Data([0, 0, 0, 1, 66, 117, 100, 49])
        else { return [] }

        return entries.compactMap { entry in
            guard let info = try? entry.resourceValues(forKeys: keys),
                  info.isDirectory == true, info.isPackage != true, info.isHidden != true
            else { return nil }
            return location(of: entry.lastPathComponent, in: data)
        }
    }

    static func location(of name: String, in data: Data) -> CGPoint? {
        for spelling in [name, name.precomposedStringWithCanonicalMapping,
                         name.decomposedStringWithCanonicalMapping] {
            guard let utf16 = spelling.data(using: .utf16BigEndian) else { continue }
            var units = UInt32(utf16.count / 2).bigEndian
            var key = withUnsafeBytes(of: &units) { Data($0) }
            key.append(utf16)
            // Filename, Iloc record type, blob type, and a 16-byte payload.
            key.append(contentsOf: "Ilocblob".utf8)
            key.append(contentsOf: [0, 0, 0, 16])
            guard let match = data.range(of: key), match.upperBound + 16 <= data.endIndex else { continue }
            let i = match.upperBound
            func int32(at index: Int) -> Int32 {
                Int32(bitPattern: data[index..<(index + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            }
            let x = int32(at: i), y = int32(at: i + 4)
            if abs(Int(x)) < 30_000 && abs(Int(y)) < 30_000 {
                return CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
        }
        return nil
    }

    /// Desktop positions use the Finder/Quartz top-left coordinate system.
    static func onScreen(_ raw: [CGPoint], frame: CGRect, primaryTop: CGFloat) -> [CGPoint] {
        raw.map { CGPoint(x: $0.x, y: primaryTop - $0.y) }.filter { frame.contains($0) }
    }
}
