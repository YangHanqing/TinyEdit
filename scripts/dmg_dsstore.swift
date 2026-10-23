// Writes the DMG window layout (.DS_Store) into a mounted, writable DMG volume, without Finder.
// Usage: swift scripts/dmg_dsstore.swift MOUNT_POINT
// The volume holds TinyEdit.app, an Applications link and .background/background.tiff (dmg_background.swift).
// The window is an icon view without toolbar, 660 x 400 pt, 128 pt icons, the app at (170, 190) and
// Applications at (490, 190): icon centres from the top left, the points the background's arrow joins.
// The background is referenced by an Alias Manager record (as Finder writes it, and dmgbuild after it),
// which names the volume, its creation date and the file IDs. hdiutil convert keeps all of them.
import Foundation

let mount = URL(fileURLWithPath: CommandLine.arguments[1])
let volumeName = "TinyEdit"
let background = mount.appendingPathComponent(".background/background.tiff")

// MARK: Big-endian writer

struct Bytes {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func u32(_ v: UInt32) { for shift in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(shift)) & 0xff)) } }
    mutating func code(_ s: String) { precondition(s.utf8.count == 4); data.append(contentsOf: Array(s.utf8)) }
    mutating func raw(_ d: Data) { data.append(d) }
    mutating func zeros(_ n: Int) { data.append(Data(count: n)) }
    /// A Pascal string in a fixed-size field: length byte, MacRoman (ASCII here) bytes, zero padding.
    mutating func pascal(_ s: String, field: Int) {
        let bytes = Array(s.utf8)
        precondition(bytes.count < field)
        u8(UInt8(bytes.count)); data.append(contentsOf: bytes); zeros(field - 1 - bytes.count)
    }
}

// MARK: Alias record (version 2) for the background

func fileID(_ url: URL) -> UInt32 {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return UInt32((attributes[.systemFileNumber] as! NSNumber).uint32Value)
}

/// Seconds since 1904-01-01 UTC.
func hfsTime(_ date: Date) -> UInt32 { UInt32(date.timeIntervalSince1970 + 2_082_844_800) }

func aliasRecord() -> Data {
    let volumeDate = try! mount.resourceValues(forKeys: [.volumeCreationDateKey]).volumeCreationDate!
    let fileDate = try! background.resourceValues(forKeys: [.creationDateKey]).creationDate!
    let folder = background.deletingLastPathComponent()
    let fileName = background.lastPathComponent, folderName = folder.lastPathComponent

    var body = Bytes()
    body.u16(2)                              // version
    body.u16(0)                              // kind: file
    body.pascal(volumeName, field: 28)
    body.u32(hfsTime(volumeDate))
    body.data.append(contentsOf: Array("H+".utf8))   // file system: HFS+
    body.u16(5)                              // disk type: ejectable
    body.u32(fileID(folder))                 // parent directory ID
    body.pascal(fileName, field: 64)
    body.u32(fileID(background))
    body.u32(hfsTime(fileDate))
    body.zeros(8)                            // file type, creator
    body.u16(0xffff); body.u16(0xffff)       // nlvlFrom, nlvlTo
    body.u32(0)                              // volume attributes
    body.u16(0)                              // volume file system ID
    body.zeros(10)

    func tag(_ tag: UInt16, _ value: Data) {
        body.u16(tag); body.u16(UInt16(value.count)); body.raw(value)
        if value.count % 2 == 1 { body.u8(0) }
    }
    func unicode(_ s: String) -> Data {
        var b = Bytes(); let units = Array(s.utf16)
        b.u16(UInt16(units.count)); units.forEach { b.u16($0) }
        return b.data
    }
    tag(0, Data(folderName.utf8))                                    // parent directory name
    var ids = Bytes(); ids.u32(fileID(folder)); tag(1, ids.data)     // directory IDs
    tag(2, Data("\(volumeName):\(folderName):\(fileName)".utf8))     // Carbon path
    tag(14, unicode(fileName))
    tag(15, unicode(volumeName))
    tag(18, Data("/\(folderName)/\(fileName)".utf8))                 // POSIX path on the volume
    tag(19, Data("/Volumes/\(volumeName)".utf8))                     // volume mount point
    body.u16(0xffff); body.u16(0)                                    // end

    var record = Bytes()
    record.zeros(4)                                                  // application creator
    record.u16(UInt16(6 + body.data.count))                          // record size, header included
    record.raw(body.data)
    return record.data
}

// MARK: Records

enum Value {
    case blob(Data), long(UInt32), type(String)
}
struct Record {
    let name: String, code: String, value: Value
}

func plist(_ object: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func iconLocation(x: UInt32, y: UInt32) -> Data {
    var b = Bytes(); b.u32(x); b.u32(y)
    b.data.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0])
    return b.data
}

let windowSettings: [String: Any] = [
    "ContainerShowSidebar": false, "ShowSidebar": false, "ShowStatusBar": false, "ShowTabView": false,
    "ShowToolbar": false, "ShowPathbar": false, "WindowBounds": "{{200, 120}, {660, 400}}",
]
let iconView: [String: Any] = [
    "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": aliasRecord(),
    "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
    "arrangeBy": "none", "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
    "iconSize": 128.0, "textSize": 13.0, "labelOnBottom": true, "showIconPreview": true, "showItemInfo": false,
]
let bookmark = try! background.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

// Sorted by name (case-insensitively), then code.
let records = [
    Record(name: ".", code: "bwsp", value: .blob(plist(windowSettings))),
    Record(name: ".", code: "icvp", value: .blob(plist(iconView))),
    Record(name: ".", code: "pBBk", value: .blob(bookmark)),
    Record(name: ".", code: "vSrn", value: .long(1)),
    Record(name: ".", code: "vstl", value: .type("icnv")),
    Record(name: "Applications", code: "Iloc", value: .blob(iconLocation(x: 490, y: 190))),
    Record(name: "TinyEdit.app", code: "Iloc", value: .blob(iconLocation(x: 170, y: 190))),
]

// MARK: Buddy-allocated file
// Offsets are from byte 4. Blocks: 0 the allocator's own info at 2048 (2048 bytes), 1 the DSDB header at
// 32 (32 bytes), 2 the single leaf node at 4096 (4096 bytes). [0, 32) is the file header. Every other
// buddy of the 2^31 space is on its free list.

var leaf = Bytes()
leaf.u32(0)                                  // no children: a leaf
leaf.u32(UInt32(records.count))
for record in records {
    let units = Array(record.name.utf16)
    leaf.u32(UInt32(units.count)); units.forEach { leaf.u16($0) }
    leaf.code(record.code)
    switch record.value {
    case .blob(let d): leaf.code("blob"); leaf.u32(UInt32(d.count)); leaf.raw(d)
    case .long(let v): leaf.code("long"); leaf.u32(v)
    case .type(let t): leaf.code("type"); leaf.code(t)
    }
}
precondition(leaf.data.count <= 4096, "layout records do not fit one node")

var dsdb = Bytes()
dsdb.u32(2)                                  // root node: block 2
dsdb.u32(0)                                  // levels above the leaves
dsdb.u32(UInt32(records.count))
dsdb.u32(1)                                  // nodes
dsdb.u32(0x1000)                             // page size

var info = Bytes()
let addresses: [UInt32] = [2048 | 11, 32 | 5, 4096 | 12]   // offset | log2(size)
info.u32(UInt32(addresses.count)); info.u32(0)
for i in 0..<256 { info.u32(i < addresses.count ? addresses[i] : 0) }
info.u32(1); info.u8(4); info.code("DSDB"); info.u32(1)    // table of contents
let used: Set<Int> = [5, 11, 12]
for size in 0..<32 {
    // Splitting [0, 2^31) down to the allocated blocks leaves one free buddy at each size from 64 bytes
    // up, at offset 2^size, except the sizes holding the info block and the leaf.
    if size >= 6 && size <= 30 && !used.contains(size) { info.u32(1); info.u32(UInt32(1) << UInt32(size)) }
    else { info.u32(0) }
}
precondition(info.data.count <= 2048)

var file = Data(count: 4 + 8192)
func put(_ d: Data, at offset: Int) { file.replaceSubrange(4 + offset ..< 4 + offset + d.count, with: d) }
var header = Bytes()
header.u32(1); header.code("Bud1"); header.u32(2048); header.u32(2048); header.u32(2048); header.zeros(16)
file.replaceSubrange(0..<header.data.count, with: header.data)
put(dsdb.data, at: 32)
put(info.data, at: 2048)
put(leaf.data, at: 4096)
try! file.write(to: mount.appendingPathComponent(".DS_Store"))
