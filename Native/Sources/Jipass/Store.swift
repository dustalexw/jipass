import Foundation
import AppKit
import CSQLite

struct NativeStorage {
    let directory: URL
    var file: URL { directory.appendingPathComponent("native-state.json") }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["native-clips","artwork","category-images","artist-photos","demo"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
    }
    func load() throws -> LocalState {
        if FileManager.default.fileExists(atPath: file.path) { return try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file)) }
        var state = LocalState()
        let legacy = directory.appendingPathComponent("needle.sqlite3")
        if FileManager.default.fileExists(atPath: legacy.path) { state = try importLegacy(legacy) }
        state.imported = true; try save(state); return state
    }
    func save(_ state: LocalState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
    func importLegacy(_ path: URL) throws -> LocalState {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw GameError(message: "Could not read the existing library database") }
        defer { sqlite3_close(database) }
        func rows(_ sql: String) -> [[String: String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }; var result: [[String: String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: String] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    if let key = sqlite3_column_name(statement,index), let value = sqlite3_column_text(statement,index) { row[String(cString:key)] = String(cString:value) }
                }; result.append(row)
            }; return result
        }
        var state = LocalState()
        for row in rows("SELECT * FROM tracks") {
            guard let path = row["path"] else { continue }
            state.tracks.append(Track(path:path, source:row["source"] ?? "nas", size:Int64(row["size"] ?? "0") ?? 0,
                                      modified:(Double(row["mtime"] ?? "0") ?? 0) / 1e9, title:row["title"] ?? "Untitled", artist:row["artist"] ?? "Unknown artist", album:row["album"] ?? "Unknown album", genre:row["genre"] ?? "Uncategorized", duration:Double(row["duration"] ?? "0") ?? 0))
        }
        state.folders = rows("SELECT * FROM library_roots").compactMap { row in row["path"].map { Folder(path:$0, status:row["status"] ?? "Imported") } }
        for row in rows("SELECT * FROM track_roots") { if let path=row["path"], let root=row["root"] { state.memberships[path,default:[]].append(root) } }
        if state.folders.isEmpty, let path = rows("SELECT value FROM settings WHERE key='nas'").first?["value"], !path.isEmpty { state.folders = [Folder(path:path)] }
        for track in state.tracks where track.source == "nas" && state.memberships[track.path] == nil {
            state.memberships[track.path] = state.folders.filter { track.path.hasPrefix($0.path + "/") }.map(\.path)
        }
        state.profiles = rows("SELECT * FROM profiles").compactMap { row in guard let id=row["id"], let name=row["name"] else { return nil }; return Profile(id:id,name:name) }
        state.selectedProfile = state.profiles.first?.id ?? ""
        for row in rows("SELECT * FROM settings") { if row["key"] == "debug_mode" { state.debug = row["value"] == "true" } }
        for row in rows("SELECT * FROM category_images") { if let key=row["key"], let file=row["file"] { state.images[key] = "category-images/" + file } }
        // Import completed round summaries and full per-question history. The SQLite file remains read-only.
        for row in rows("SELECT * FROM rounds WHERE finished IS NOT NULL ORDER BY finished") {
            guard let raw=row["state"], let data=raw.data(using:.utf8), let old=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let results=old["results"] as? [[String:Any]] else { continue }
            let entries: [ResultEntry] = results.compactMap { value in
                guard let t=value["track"] as? [String:String] else { return nil }
                let match = state.tracks.first { $0.title == t["title"] && $0.artist == t["artist"] && $0.album == t["album"] }
                let track = match ?? Track(path:"", source:old["source"] as? String ?? "nas", size:0, modified:0,title:t["title"] ?? "Untitled",artist:t["artist"] ?? "Unknown artist",album:t["album"] ?? "Unknown album",genre:t["genre"] ?? "Uncategorized",duration:0)
                return ResultEntry(track:track,correct:value["correct"] as? Bool ?? false,timeout:value["timeout"] as? Bool ?? false,points:value["points"] as? Int ?? 0,elapsed:value["elapsed"] as? Double ?? 0,kind:QuestionKind(rawValue:value["kind"] as? String ?? "title") ?? .title)
            }
            state.history.append(GameRecord(id:row["id"] ?? UUID().uuidString,profile:old["profile"] as? String ?? "",date:Date(timeIntervalSince1970:Double(row["finished"] ?? "0") ?? 0),source:old["source"] as? String ?? "nas",kind:QuestionKind(rawValue:old["kind"] as? String ?? "title") ?? .title,requested:old["length"] as? Int ?? entries.count,seconds:old["seconds"] as? Double ?? 10,results:entries))
        }
        return state
    }
    func image(kind: String, source: String, name: String, state: LocalState) -> URL? {
        if let file = state.images[Rules.imageKey(kind: kind, source: source, name: name)] {
            let url = directory.appendingPathComponent(file); if FileManager.default.fileExists(atPath:url.path) { return url }
        }
        if kind == "artist" && source == "nas" {
            let url=directory.appendingPathComponent("artist-photos/" + digest(normalized(name)) + ".jpg")
            if FileManager.default.fileExists(atPath:url.path) { return url }
        }
        return nil
    }
    func storeImage(_ url: URL, kind: String, source: String, name: String, state: inout LocalState) throws {
        guard state.debug else { throw GameError(message:"Enable BIG CHIEF'M (Debug) in Settings to change images") }
        let values = try url.resourceValues(forKeys:[.fileSizeKey])
        guard ["jpg","jpeg","png","webp"].contains(url.pathExtension.lowercased()), (values.fileSize ?? Int.max) <= 8 * 1024 * 1024,
              let bitmap=NSBitmapImageRep(data:try Data(contentsOf:url)), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, bitmap.pixelsWide * bitmap.pixelsHigh <= 40_000_000 else { throw GameError(message:"Choose a JPEG, PNG or WebP below 8 MB and 40 megapixels") }
        let scale=min(1,1200/Double(max(bitmap.pixelsWide,bitmap.pixelsHigh)))
        let size=NSSize(width:Double(bitmap.pixelsWide)*scale,height:Double(bitmap.pixelsHigh)*scale)
        let image=NSImage(size:size); image.lockFocus(); NSImage(cgImage:bitmap.cgImage!,size:size).draw(in:NSRect(origin:.zero,size:size)); image.unlockFocus()
        guard let tiff=image.tiffRepresentation,let output=NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.9]) else { throw GameError(message:"Unable to decode image") }
        let key=Rules.imageKey(kind:kind,source:source,name:name), file="category-images/" + key + "-" + UUID().uuidString + ".jpg"
        try output.write(to:directory.appendingPathComponent(file),options:.atomic);state.images[key]=file;try save(state)
    }
    func generateDemo() throws -> [Track] {
        let titles=["Velvet Satellite","Afterglow Avenue","Paper Moons","Electric Orchard","Slow Horizon","Midnight Current","Amber Circuit","Sunday Static","Blue Carousel","Copper Rain","Soft Geometry","Neon Letters","Golden Hour","Distant Rooms","City of Ferns","Plum Weather","Small Hours","Parallel Gardens"]
        let artists=["Luna Relay","The Daybreaks","Moss & Mercury","Glass District","June Atlas","Night Assembly"]
        return try titles.enumerated().map { i,title in
            let url=directory.appendingPathComponent("demo/" + title + ".wav")
            if !FileManager.default.fileExists(atPath:url.path) {
                let rate=16000, samples=rate*24
                var pcm=Data();pcm.reserveCapacity(samples*2)
                let notes=[0,3,7,10,7,3,5,2]
                for n in 0..<samples {
                    let t=Double(n)/Double(rate),beat=t*(2+Double(i%3)*0.25),phase=beat.truncatingRemainder(dividingBy:1)
                    let note=notes[(Int(beat)+i)%notes.count],freq=130.81*pow(2,Double(note+i%5)/12)
                    let env=min(1,phase*25)*exp(-phase*3)
                    let value=0.24*env*(sin(2*Double.pi*freq*t)+0.3*sin(4*Double.pi*freq*t))+0.08*sin(2*Double.pi*65.4*t)*exp(-phase*10)
                    var sample=Int16(max(-1,min(1,value))*32767).littleEndian
                    withUnsafeBytes(of:&sample) { pcm.append(contentsOf:$0) }
                }
                var data=Data("RIFF".utf8)
                func word(_ value:UInt32) { var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)} }
                func short(_ value:UInt16) { var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)} }
                word(UInt32(pcm.count+36));data.append(Data("WAVEfmt ".utf8));word(16);short(1);short(1);word(UInt32(rate));word(UInt32(rate*2));short(2);short(16);data.append(Data("data".utf8));word(UInt32(pcm.count));data.append(pcm);try data.write(to:url,options:.atomic)
            }
            var track=try Media.probe(url,source:"demo");track.title=title;track.artist=artists[i%6];track.album="jipass · Original sketches";track.genre=["Electronic","Indie","Jazz"][i%3];return track
        }
    }
}
