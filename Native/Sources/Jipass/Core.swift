import Foundation
import CryptoKit

func normalized(_ text: String) -> String { text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
struct Track: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var source: String
    var size: Int64
    var modified: Double
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: Double
    func label(_ kind: QuestionKind) -> String { kind == .artist ? artist : title }
}
enum QuestionKind: String, Codable, CaseIterable { case mixed, title, artist
    var label: String { switch self { case .mixed: return "Artist + song title"; case .title: return "Song title"; case .artist: return "Artist" } }
}
struct Choice: Identifiable { let id = UUID(); var label: String }
struct Profile: Codable, Identifiable, Hashable { var id: String = UUID().uuidString; var name: String }
struct Folder: Codable, Identifiable { var id: String { path }; var path: String; var status = "Not scanned" }
struct ResultEntry: Codable, Identifiable {
    var id: String = UUID().uuidString
    var track: Track
    var correct: Bool
    var timeout: Bool
    var points: Int
    var elapsed: Double
    var kind: QuestionKind
}
struct GameRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var profile: String
    var date = Date()
    var source: String
    var kind: QuestionKind
    var requested: Int
    var seconds: Double
    var results: [ResultEntry]
    var total: Int { results.reduce(0) { $0 + $1.points } }
    var accuracy: Int { results.isEmpty ? 0 : Int((100 * Double(results.filter(\.correct).count) / Double(results.count)).rounded()) }
    var average: Double { results.isEmpty ? 0 : results.reduce(0) { $0 + $1.elapsed } / Double(results.count) }
}
struct LocalState: Codable {
    var tracks: [Track] = []
    var folders: [Folder] = []
    var memberships: [String: [String]] = [:]
    var profiles: [Profile] = []
    var history: [GameRecord] = []
    var images: [String: String] = [:]
    var debug = false
    var demo = false
    var selectedProfile = ""
    var imported = false
}
struct GameError: LocalizedError { var message: String; var errorDescription: String? { message } }

enum Rules {
    static func score(correct: Bool, elapsed: Double, limit: Double) -> Int {
        guard correct, limit > 0, elapsed.isFinite, elapsed < limit else { return 0 }
        return 500 + Int((500 * max(0, 1 - max(0, elapsed) / limit)).rounded(.toNearestOrEven))
    }
    static func choices(for track: Track, library: [Track], kind: QuestionKind) throws -> [Choice] {
        let answer = track.label(kind)
        guard !normalized(answer).isEmpty, !(kind == .artist && normalized(answer) == "unknown artist") else { throw GameError(message: "Missing artist metadata") }
        var buckets = [[String](), [String](), [String]()]
        let artistKey=normalized(track.artist),genreKey=normalized(track.genre),answerKey=normalized(answer)
        var candidates:[String:(String,Int)] = [:]
        for candidate in library {
            let label=candidate.label(kind),key=normalized(label)
            guard !key.isEmpty,key != answerKey,!(kind == .artist && key == "unknown artist") else {continue}
            let rank=kind == .title && normalized(candidate.artist) == artistKey && artistKey != "unknown artist" ? 0 : normalized(candidate.genre) == genreKey ? 1 : 2
            if candidates[key] == nil || rank < candidates[key]!.1 {candidates[key]=(label,rank)}
        }
        for (label,rank) in candidates.values {buckets[rank].append(label)}
        let wrong = buckets.flatMap { $0.shuffled() }.prefix(3)
        guard wrong.count == 3 else { throw GameError(message: "This library needs four distinct \(kind == .artist ? "artists" : "song titles") for these questions.") }
        return ([answer] + wrong).shuffled().map { Choice(label: $0) }
    }
    static func kinds(for track: Track, library: [Track], mode: QuestionKind) -> [QuestionKind] {
        (mode == .mixed ? [.title, .artist] : [mode]).filter { kind in
            let key=normalized(track.label(kind))
            guard !key.isEmpty,!(kind == .artist && key == "unknown artist") else{return false}
            return Set(library.map{normalized($0.label(kind))}.filter{!$0.isEmpty && !(kind == .artist && $0 == "unknown artist")}).count >= 4
        }
    }
    static func clipStart(duration: Double, seconds: Double) -> Double {
        let margin = min(10, max(0, (duration - seconds) / 4))
        return Double.random(in: margin...max(margin, duration - seconds - margin))
    }
    static func imageKey(kind: String, source: String, name: String) -> String { digest(kind + "\0" + source + "\0" + normalized(name)) }
}

// Monotonic clock, armed only after AVAudioPlayer successfully starts.
struct QuestionClock {
    private(set) var started: Double?
    private(set) var resolved = false
    mutating func start(now: Double) { if started == nil && !resolved { started = now } }
    func elapsed(now: Double, limit: Double) -> Double { min(limit, max(0, now - (started ?? now))) }
    mutating func resolve(now: Double, limit: Double) -> Double? {
        guard started != nil, !resolved else { return nil }
        let value = elapsed(now: now, limit: limit); resolved = true; return value
    }
}

struct ProcessOutput { var data: Data; var status: Int32 }
enum Media {
    static let formats: Set<String> = ["mp3","flac","m4a","aac","ogg","opus","wav","aiff","aif","wma","alac","ape","mp4"]
    static func tool(_ name: String) throws -> URL {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw GameError(message: "\(name) is missing. Install FFmpeg with brew install ffmpeg, then reopen jipass.")
    }
    static func run(_ toolName: String, _ arguments: [String], timeout: Double = 40) throws -> ProcessOutput {
        let process = Process(), pipe = Pipe()
        process.executableURL = try tool(toolName); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        return ProcessOutput(data: data, status: process.terminationStatus)
    }
    static func probe(_ url: URL, source: String) throws -> Track {
        let output = try run("ffprobe", ["-v","error","-show_format","-show_streams","-of","json",url.path], timeout: 25)
        guard output.status == 0, let json = try JSONSerialization.jsonObject(with: output.data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else { throw GameError(message: "Unreadable audio: \(url.lastPathComponent)") }
        let format = json["format"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for block in [audio["tags"], format["tags"]] {
            for (key,value) in block as? [String: Any] ?? [:] { tags[key.lowercased()] = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let duration = Double(String(describing: format["duration"] ?? audio["duration"] ?? "0")) ?? 0
        guard duration.isFinite, duration >= 3 else { throw GameError(message: "Track is too short or has no usable duration") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        func tag(_ key: String, _ fallback: String) -> String { let value = tags[key] ?? ""; return value.isEmpty ? fallback : value }
        return Track(path: url.path, source: source, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                     modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     title: tag("title", url.deletingPathExtension().lastPathComponent), artist: tag("artist", tag("album_artist", "Unknown artist")),
                     album: tag("album", "Unknown album"), genre: tag("genre", "Uncategorized"), duration: duration)
    }
    static func clip(_ track: Track, seconds: Double, directory: URL) throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let duration = min(seconds, track.duration)
        let response = try run("ffmpeg", ["-nostdin","-v","error","-ss",String(Rules.clipStart(duration: track.duration, seconds: duration)),"-i",track.path,"-t",String(duration),"-vn","-map_metadata","-1","-ac","1","-ar","22050","-c:a","pcm_s16le","-y",output.path])
        guard response.status == 0, (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 100 else {
            try? FileManager.default.removeItem(at: output); throw GameError(message: "Track could not be played")
        }
        return output
    }
    static func artwork(_ track: Track, directory: URL) -> URL? {
        let audio = URL(fileURLWithPath: track.path)
        guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: audio.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let cover = ["cover","folder","front","album","artwork"].compactMap { stem in
            files.first { normalized($0.deletingPathExtension().lastPathComponent) == stem && ["jpg","jpeg","png","webp"].contains($0.pathExtension.lowercased()) && $0.resolvingSymlinksInPath().deletingLastPathComponent() == audio.resolvingSymlinksInPath().deletingLastPathComponent() && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 20 * 1024 * 1024 }
        }.first
        let signature = track.path + String(track.modified) + (cover.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.map { String($0.timeIntervalSince1970) } ?? "")
        let dest = directory.appendingPathComponent(digest(signature) + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        var inputs: [(URL,String)] = []
        if let output = try? run("ffprobe", ["-v","error","-select_streams","v","-show_entries","stream=index:stream_disposition=attached_pic","-of","json",audio.path], timeout: 15),
           let json = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any], let streams = json["streams"] as? [[String: Any]],
           let attached = streams.first(where: { ($0["disposition"] as? [String: Int])?["attached_pic"] == 1 }), let index = attached["index"] as? Int { inputs.append((audio,"0:\(index)")) }
        if let cover { inputs.append((cover,"0:v:0")) }
        for (input,map) in inputs {
            if let result = try? run("ffmpeg", ["-nostdin","-v","error","-i",input.path,"-map",map,"-frames:v","1","-vf","scale=600:600:force_original_aspect_ratio=decrease","-map_metadata","-1","-q:v","3","-y",dest.path], timeout: 20), result.status == 0 { return dest }
        }
        try? FileManager.default.removeItem(at: dest); return nil
    }
}

struct ScanReport { var tracks: [Track]; var memberships: [String: [String]]; var folders: [Folder]; var changed = 0; var unchanged = 0; var errors: [String] = [] }
enum Indexer {
    static func scan(tracks: [Track], folders: [Folder], memberships: [String: [String]]) -> ScanReport {
        var report = ScanReport(tracks: tracks, memberships: memberships, folders: folders)
        var byPath = Dictionary(tracks.map { ($0.path,$0) }, uniquingKeysWith: { first,_ in first })
        let fm = FileManager.default
        for index in folders.indices {
            let root = URL(fileURLWithPath: folders[index].path).resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue, fm.isReadableFile(atPath: root.path) else {
                report.folders[index].status = "Unavailable — mount your NAS"; report.errors.append(root.path + ": unavailable"); continue
            }
            var complete = true, seen = Set<String>(), failures = 0
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _,_ in complete = false; return true }) else { continue }
            for case let file as URL in iterator {
                guard Media.formats.contains(file.pathExtension.lowercased()) else { continue }
                let url = file.resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(root.path + "/") else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true else { continue }
                    seen.insert(url.path)
                    let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    if let old = byPath[url.path], old.size == Int64(values.fileSize ?? 0), abs(old.modified - modified) < 0.000_001 {
                        report.unchanged += 1
                    } else {
                        byPath[url.path] = try Media.probe(url, source: "nas"); report.changed += 1
                    }
                    var roots = Set(report.memberships[url.path] ?? []); roots.insert(root.path); report.memberships[url.path] = Array(roots)
                } catch { failures += 1; if report.errors.count < 30 { report.errors.append(file.lastPathComponent + ": " + error.localizedDescription) } }
            }
            if complete {
                for path in Array(report.memberships.keys) where !seen.contains(path) {
                    report.memberships[path]?.removeAll { $0 == root.path }
                    if report.memberships[path]?.isEmpty == true { byPath.removeValue(forKey: path); report.memberships.removeValue(forKey: path) }
                }
            }
            report.folders[index].status = complete ? "Scanned · \(seen.count) files · \(failures) skipped" : "Incomplete scan — index retained"
        }
        report.tracks = Array(byPath.values).sorted { $0.path < $1.path }; return report
    }
}
