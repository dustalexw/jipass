import SwiftUI
import AVFoundation

protocol AudioPlayback: AnyObject {
    var volume:Float {get set}
    var duration:TimeInterval {get}
    var currentTime:TimeInterval {get set}
    var isPlaying:Bool {get}
    func prepareToPlay()->Bool
    func play()->Bool
    func pause()
    func stop()
}
extension AVAudioPlayer:AudioPlayback {}

@MainActor final class GameModel: ObservableObject {
    enum Page { case play, library, history, game, results }
    @Published var state = LocalState()
    @Published var page: Page = .play
    @Published var categoryMode = "genre"
    @Published var category = ""
    @Published var search = ""
    @Published var mode: QuestionKind = .mixed
    @Published var length = 5
    @Published var seconds = 10.0
    @Published var settings = false
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?
    @Published var profileName = ""
    @Published var options: [Choice] = []
    @Published var currentKind: QuestionKind = .title
    @Published var remaining = 10.0
    @Published var active = false
    @Published var playing = false
    @Published var feedback: ResultEntry?
    @Published var artwork: URL?
    @Published var results: [ResultEntry] = []
    @Published var completed: GameRecord?
    @Published var volume: Double = 0.8 { didSet { player?.volume=Float(volume) } }
    @Published var skipped = 0
    @Published var selectedChoice: UUID?
    @Published var credits: [PhotoCredit] = []
    private var feedbackPlayer: AVAudioPlayer?
    let storage: NativeStorage
    private var player: AudioPlayback?
    private let audioFactory:(URL) throws -> AudioPlayback
    private var storageReady = true
    private var clock=QuestionClock()
    private var timer: Timer?
    private var pending: [Track] = []
    private var library: [Track] = []
    private var current: Track?
    private var correctLabel = ""
    private var currentLimit = 10.0
    private var roundMode: QuestionKind = .mixed
    private var roundLength = 5
    private var roundSeconds = 10.0
    private var roundSource = "nas"
    private var roundProfile = ""
    private var firstKind: QuestionKind = .title
    private var clip: URL?
    private var generation = UUID()
    init(directory: URL, audioFactory:@escaping (URL) throws -> AudioPlayback = {try AVAudioPlayer(contentsOf:$0)}) {
        self.audioFactory=audioFactory
        do { storage=try NativeStorage(directory:directory) }
        catch { fatalError("Unable to open jipass data folder: \(error.localizedDescription)") }
        do { state=try storage.load() } catch { storageReady=false;self.error="Could not open native saved data. It has been left untouched: " + error.localizedDescription }
        credits=ArtistPhotos.credits(directory:storage.directory)
        message="Your music. Your machine."
    }
    var source: String { state.demo ? "demo" : "nas" }
    var sourceTracks: [Track] { state.tracks.filter { $0.source == source } }
    var categories: [(name:String,count:Int)] {
        let groups=Dictionary(grouping:sourceTracks.filter { categoryMode != "artist" || normalized($0.artist) != "unknown artist" },by:{ normalized(categoryMode == "artist" ? $0.artist : $0.genre) })
        return groups.values.compactMap { tracks in
            guard let first=tracks.first else { return nil }
            let name=categoryMode == "artist" ? first.artist : first.genre
            guard search.isEmpty || name.localizedCaseInsensitiveContains(search) else { return nil }
            return (name,tracks.count)
        }.sorted { normalized($0.name) < normalized($1.name) }
    }
    var streak: Int { results.reversed().prefix(while:{$0.correct}).count }
    var total: Int { results.reduce(0){$0+$1.points} }
    var personalBest: Int {
        guard let record=completed else { return 0 }
        return state.history.filter { $0.profile == record.profile && $0.source == record.source && $0.kind == record.kind && $0.requested == record.requested && $0.seconds == record.seconds }.map(\.total).max() ?? record.total
    }
    var canAnswer: Bool { active && feedback == nil && !busy }
    var isRound: Bool { page == .game }
    func persist() { guard storageReady else { return };do { try storage.save(state) } catch { self.error="Could not save: " + error.localizedDescription } }
    func addProfile() {
        guard !isRound else { return }
        let name=profileName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile=Profile(name:String(name.prefix(60)));state.profiles.append(profile);state.selectedProfile=profile.id;profileName="";persist()
    }
    func setDemo(_ value:Bool) {
        guard !isRound else { return }
        state.demo=value;category="";search="";persist()
        if value && !state.tracks.contains(where:{$0.source == "demo"}) {
            busy=true;message="Creating 18 original demo sketches…"
            let storage=self.storage
            Task { do {
                let tracks=try await Task.detached(priority:.userInitiated){try storage.generateDemo()}.value
                state.tracks.removeAll{$0.source == "demo"};state.tracks+=tracks;persist();message="Demo ready. These are original synthesized sketches."
            } catch { self.error=error.localizedDescription };busy=false }
        }
    }
    func addFolder() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=true;panel.prompt="Add music folders"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path=url.resolvingSymlinksInPath().standardizedFileURL.path
            if !state.folders.contains(where:{$0.path == path}) && state.folders.count < 50 { state.folders.append(Folder(path:path)) }
        };persist()
    }
    func removeFolder(_ folder:Folder) {
        guard !busy else { return }
        state.folders.removeAll{$0.path == folder.path}
        for path in Array(state.memberships.keys) {
            state.memberships[path]?.removeAll{$0 == folder.path}
            if state.memberships[path]?.isEmpty == true { state.memberships.removeValue(forKey:path);state.tracks.removeAll{$0.source == "nas" && $0.path == path} }
        };persist()
    }
    func rescan() {
        guard !busy,!isRound else { return }
        busy=true;message="Scanning folders… Unchanged tracks are skipped."
        let tracks=state.tracks,folders=state.folders,memberships=state.memberships
        Task {
            let report=await Task.detached(priority:.userInitiated){Indexer.scan(tracks:tracks,folders:folders,memberships:memberships)}.value
            state.tracks=report.tracks;state.memberships=report.memberships;state.folders=report.folders;persist();busy=false
            message="\(report.changed) updated · \(report.unchanged) unchanged · \(report.errors.count) reported issues"
            if !report.errors.isEmpty { error=report.errors.joined(separator:"\n") }
        }
    }
    func loadPhoto(_ name:String) async {
        guard categoryMode == "artist",source == "nas",image(name) == nil else { return }
        let changed=await ArtistPhotos.shared.fetch(name,directory:storage.directory)
        if changed { objectWillChange.send();credits=ArtistPhotos.credits(directory:storage.directory) }
    }
    func playFeedback(correct:Bool) {
        let rate=16000,count=4000
        var samples=Data()
        for n in 0..<count {
            let t=Double(n)/Double(rate),frequency=correct ? (n < count/2 ? 660.0:880.0):220.0
            var sample=Int16(sin(2*Double.pi*frequency*t)*exp(-t*12)*6000).littleEndian
            withUnsafeBytes(of:&sample){samples.append(contentsOf:$0)}
        }
        var data=Data("RIFF".utf8)
        func word(_ n:UInt32){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        func short(_ n:UInt16){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        word(UInt32(samples.count+36));data.append(Data("WAVEfmt ".utf8));word(16);short(1);short(1);word(16000);word(32000);short(2);short(16);data.append(Data("data".utf8));word(UInt32(samples.count));data.append(samples)
        feedbackPlayer=try? AVAudioPlayer(data:data);feedbackPlayer?.volume=Float(volume);feedbackPlayer?.play()
    }
    func image(_ name:String) -> URL? { storage.image(kind:categoryMode,source:source,name:name,state:state) }
    func upload(_ name:String) {
        guard state.debug,!isRound else { return }
        let panel=NSOpenPanel();panel.allowedContentTypes=[.jpeg,.png,.webP];panel.prompt="Use image"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let preview=NSAlert();preview.messageText="Use this image for " + name + "?";preview.informativeText="The image is stored locally. Your original music and image files stay unchanged.";preview.icon=NSImage(contentsOf:url);preview.addButton(withTitle:"Save image");preview.addButton(withTitle:"Cancel")
        guard preview.runModal() == .alertFirstButtonReturn else { return }
        do { try storage.storeImage(url,kind:categoryMode,source:source,name:name,state:&state) } catch { self.error=error.localizedDescription }
    }
    func resetImage(_ name:String) {
        guard state.debug else { return }
        state.images.removeValue(forKey:Rules.imageKey(kind:categoryMode,source:source,name:name));persist()
    }
    func startRound() {
        guard !busy,storageReady else { return }
        if state.selectedProfile.isEmpty {
            if state.profiles.isEmpty { state.profiles.append(Profile(name:"Player 1")) }
            state.selectedProfile=state.profiles[0].id;persist()
        }
        library=sourceTracks
        roundMode=categoryMode == "artist" && !category.isEmpty ? .title : mode
        let pool=library.filter { category.isEmpty || normalized(categoryMode == "artist" ? $0.artist : $0.genre) == normalized(category) }
        let kinds:[QuestionKind]=roundMode == .mixed ? [.title,.artist]:[roundMode]
        let available=kinds.filter{kind in Set(library.map{normalized($0.label(kind))}.filter{!$0.isEmpty && !(kind == .artist && $0 == "unknown artist")}).count >= 4}
        pending=pool.filter{track in available.contains{kind in let key=normalized(track.label(kind));return !key.isEmpty && !(kind == .artist && key == "unknown artist")}}.shuffled()
        guard pending.count >= length else { error="This category has \(pending.count) eligible tracks. Choose a shorter round, another category, or add more music. Four distinct answers must exist in the library.";return }
        roundLength=length;roundSeconds=seconds;roundSource=source;roundProfile=state.selectedProfile
        results=[];completed=nil;skipped=0;firstKind=Bool.random() ? .title : .artist;page = .game;prepare()
    }
    func stopAudio() {
        timer?.invalidate();timer=nil;player?.stop();player=nil;playing=false;active=false
        if let clip { try? FileManager.default.removeItem(at:clip) };clip=nil
    }
    func leave() { generation=UUID();stopAudio();busy=false;current=nil;feedback=nil;artwork=nil;page = .play }
    func prepare() {
        stopAudio();feedback=nil;selectedChoice=nil;artwork=nil;options=[];clock=QuestionClock();busy=true;message="Preparing your next discovery…"
        let token=UUID();generation=token
        Task {
            while !pending.isEmpty && generation == token {
                let track=pending.removeFirst()
                let kinds=Rules.kinds(for:track,library:library,mode:roundMode)
                let desired=results.count % 2 == 0 ? firstKind : (firstKind == .title ? .artist : .title)
                guard let kind=kinds.contains(desired) ? desired : kinds.first, let choices=try? Rules.choices(for:track,library:library,kind:kind) else { skipped+=1;continue }
                let directory=storage.directory.appendingPathComponent("native-clips"),seconds=roundSeconds
                do {
                    let clipURL=try await Task.detached(priority:.userInitiated){try Media.clip(track,seconds:seconds,directory:directory)}.value
                    guard generation == token else { try? FileManager.default.removeItem(at:clipURL);return }
                    let audio=try audioFactory(clipURL);audio.volume=Float(volume)
                    guard audio.prepareToPlay() else { throw GameError(message:"Audio could not be prepared") }
                    current=track;correctLabel=track.label(kind);currentKind=kind;options=choices;clip=clipURL;player=audio
                    currentLimit=min(roundSeconds,track.duration,audio.duration);remaining=currentLimit;busy=false;message="Listen closely."
                    play();return
                } catch { skipped+=1 }
            }
            if generation == token { busy=false;if results.isEmpty { self.error="No playable tracks remain. Check your NAS connection and FFmpeg installation.";leave() } else { finish() } }
        }
    }
    func play() {
        guard let player,!busy else { return }
        if playing { player.pause();playing=false;return }
        if feedback == nil && clock.started == nil {
            guard player.play() else { error="Playback could not start. Check your audio output and press Play to retry.";return }
            clock.start(now:ProcessInfo.processInfo.systemUptime);active=true;playing=true
            timer=Timer.scheduledTimer(withTimeInterval:0.025,repeats:true){ [weak self] _ in Task { @MainActor in self?.tick() } }
        } else {
            if player.currentTime >= player.duration-0.1 { player.currentTime=0 }
            playing=player.play()
        }
    }
    func tick() {
        guard active else { return }
        remaining=max(0,currentLimit-clock.elapsed(now:ProcessInfo.processInfo.systemUptime,limit:currentLimit))
        if remaining <= 0 { answer(nil) }
        if player?.isPlaying == false { playing=false }
    }
    func answer(_ id:UUID?) {
        guard canAnswer,let track=current,let elapsed=clock.resolve(now:ProcessInfo.processInfo.systemUptime,limit:currentLimit) else { return }
        timer?.invalidate();timer=nil;active=false
        let timeout=elapsed >= currentLimit,correct = !timeout && options.first(where:{$0.id == id})?.label == correctLabel
        let entry=ResultEntry(track:track,correct:correct,timeout:timeout,points:Rules.score(correct:correct,elapsed:elapsed,limit:currentLimit),elapsed:elapsed,kind:currentKind)
        selectedChoice=id;feedback=entry;results.append(entry);playFeedback(correct:correct)
        let directory=storage.directory.appendingPathComponent("artwork"),token=generation
        Task {
            let url=await Task.detached(priority:.utility){Media.artwork(track,directory:directory)}.value
            if generation == token && feedback != nil { artwork=url }
        }
        // Save answered questions immediately, including a round left before completion.
        persistProgress()
    }
    private var currentRecordID=UUID().uuidString
    func persistProgress() {
        if results.count == 1 { currentRecordID=UUID().uuidString }
        let record=GameRecord(id:currentRecordID,profile:roundProfile,source:roundSource,kind:roundMode,requested:roundLength,seconds:roundSeconds,results:results)
        state.history.removeAll{$0.id == record.id};state.history.append(record);persist()
    }
    func next() { guard feedback != nil else { return };if results.count >= roundLength || pending.isEmpty { finish() } else { prepare() } }
    func finish() { stopAudio();completed=state.history.first{$0.id == currentRecordID};page = .results }
    func isCorrectChoice(_ choice:Choice) -> Bool { feedback != nil && choice.label == correctLabel }
}
