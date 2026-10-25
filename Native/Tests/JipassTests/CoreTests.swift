import XCTest
@testable import Jipass

final class CoreTests: XCTestCase {
    func track(_ n:Int,artist:String?=nil,genre:String="Rock") -> Track { Track(path:"/music/\(n).wav",source:"nas",size:0,modified:0,title:"Song \(n)",artist:artist ?? "Artist \(n)",album:"Album",genre:genre,duration:60) }
    func temporary() throws -> URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url}
    func testScoreBoundaries() {
        XCTAssertEqual(Rules.score(correct:true,elapsed:0,limit:10),1000)
        XCTAssertEqual(Rules.score(correct:true,elapsed:2,limit:10),900)
        XCTAssertEqual(Rules.score(correct:false,elapsed:2,limit:10),0)
        XCTAssertEqual(Rules.score(correct:true,elapsed:10,limit:10),0)
        XCTAssertEqual(Rules.score(correct:true,elapsed:20,limit:10),0)
        XCTAssertEqual(Rules.score(correct:true,elapsed:0,limit:0),0)
    }
    func testChoicesAreUniqueAndLibraryOnly() throws {
        var tracks=(0..<8).map{track($0)};var duplicate=tracks[0];duplicate.title="  SONG   0 ";tracks.append(duplicate)
        for _ in 0..<30 {
            let choices=try Rules.choices(for:tracks[0],library:tracks,kind:.title)
            XCTAssertEqual(choices.count,4);XCTAssertEqual(Set(choices.map{normalized($0.label)}).count,4)
            XCTAssertTrue(choices.contains{$0.label == "Song 0"});XCTAssertTrue(choices.allSatisfy{c in tracks.contains{$0.title == c.label}})
        }
    }
    func testDistractorsPreferArtistThenGenre() throws {
        let tracks=(0..<4).map{track($0,artist:"Same artist")} + (4..<9).map{track($0,genre:"Jazz")}
        let options=try Rules.choices(for:tracks[0],library:tracks,kind:.title)
        XCTAssertEqual(Set(options.map(\.label)),Set(tracks.prefix(4).map(\.title)))
    }
    func testArtistQuestionsNeedFourKnownArtists() throws {
        let tracks=(0..<6).map{track($0,artist:$0 == 5 ? "Unknown artist":"Artist \($0%3)")}
        XCTAssertThrowsError(try Rules.choices(for:tracks[0],library:tracks,kind:.artist))
        XCTAssertEqual(Rules.kinds(for:tracks[0],library:tracks,mode:.mixed),[.title])
        XCTAssertEqual(Set(Rules.kinds(for:track(0),library:(0..<5).map{track($0)},mode:.mixed)),Set([.title,.artist]))
    }
    func testClockWaitsForPlaybackAndResolvesOnlyOnce() {
        var clock=QuestionClock()
        XCTAssertNil(clock.resolve(now:100,limit:10))
        XCTAssertEqual(clock.elapsed(now:100,limit:10),0)
        clock.start(now:100);clock.start(now:102)
        XCTAssertEqual(clock.resolve(now:103,limit:10),3)
        XCTAssertNil(clock.resolve(now:104,limit:10))
        var timeout=QuestionClock();timeout.start(now:100)
        XCTAssertEqual(timeout.resolve(now:115,limit:10),10)
    }
    func testClipMargins() {
        for _ in 0..<100 {
            let start=Rules.clipStart(duration:60,seconds:10);XCTAssertGreaterThanOrEqual(start,10);XCTAssertLessThanOrEqual(start,40)
            let short=Rules.clipStart(duration:4,seconds:4);XCTAssertEqual(short,0)
        }
    }
    func testPersistenceAndMalformedDataNotOverwritten() throws {
        let root=try temporary(),store=try NativeStorage(directory:root)
        var state=try store.load();state.profiles=[Profile(name:"Listener")];state.debug=true;try store.save(state)
        XCTAssertEqual(try store.load().profiles.first?.name,"Listener");XCTAssertTrue(try store.load().debug)
        try Data("bad json".utf8).write(to:store.file)
        XCTAssertThrowsError(try store.load());XCTAssertEqual(try String(contentsOf:store.file),"bad json")
    }
    func testIncrementalIndexOfflineAndOverlappingRoots() throws {
        let root=try temporary(),music=root.appendingPathComponent("music"),album=music.appendingPathComponent("album")
        try FileManager.default.createDirectory(at:album,withIntermediateDirectories:true)
        let audio=album.appendingPathComponent("untagged.wav")
        XCTAssertEqual(try Media.run("ffmpeg",["-v","error","-f","lavfi","-i","sine=frequency=440:duration=4","-y",audio.path]).status,0)
        let folders=[Folder(path:music.path),Folder(path:album.path)]
        let first=Indexer.scan(tracks:[],folders:folders,memberships:[:])
        XCTAssertEqual(first.tracks.count,1);XCTAssertEqual(first.changed,1);XCTAssertEqual(first.unchanged,1)
        XCTAssertEqual(first.tracks[0].title,"untagged");XCTAssertEqual(first.tracks[0].artist,"Unknown artist")
        XCTAssertEqual(first.memberships[audio.path]?.count,2)
        let next=Indexer.scan(tracks:first.tracks,folders:folders,memberships:first.memberships)
        XCTAssertEqual(next.changed,0);XCTAssertEqual(next.unchanged,2)
        try FileManager.default.moveItem(at:music,to:root.appendingPathComponent("offline"))
        let offline=Indexer.scan(tracks:next.tracks,folders:folders,memberships:next.memberships)
        XCTAssertEqual(offline.tracks.count,1);XCTAssertEqual(offline.errors.count,2)
    }
    func testCorruptTrackSkippedAndCompleteScanPrunesDeleted() throws {
        let root=try temporary(),bad=root.appendingPathComponent("broken.mp3")
        try Data("not music".utf8).write(to:bad)
        var old=track(0);old.path=root.appendingPathComponent("removed.mp3").path
        let report=Indexer.scan(tracks:[old],folders:[Folder(path:root.path)],memberships:[old.path:[root.path]])
        XCTAssertTrue(report.tracks.isEmpty);XCTAssertEqual(report.errors.count,1)
    }
    func testImageWritesRequireDebug() throws {
        let store=try NativeStorage(directory:temporary());var state=LocalState()
        XCTAssertThrowsError(try store.storeImage(URL(fileURLWithPath:"/nonexistent.png"),kind:"artist",source:"nas",name:"Artist",state:&state))
        XCTAssertTrue(state.images.isEmpty)
    }
    func testActualLegacyLibraryImport() throws {
        // Use a fixture DB, never the user's live database.
        let root=try temporary(),db=root.appendingPathComponent("needle.sqlite3")
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3");process.arguments=[db.path,"CREATE TABLE profiles(id TEXT,name TEXT);INSERT INTO profiles VALUES('p','Listener');CREATE TABLE tracks(path TEXT,source TEXT,size INTEGER,mtime INTEGER,title TEXT,artist TEXT,album TEXT,genre TEXT,duration REAL);INSERT INTO tracks VALUES('/music/song.mp3','nas',12,1000000000,'Song','Artist','Album','Rock',60);CREATE TABLE library_roots(path TEXT,status TEXT);INSERT INTO library_roots VALUES('/music','Ready');"]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let before=try Data(contentsOf:db),store=try NativeStorage(directory:root),state=try store.load()
        XCTAssertEqual(state.tracks.count,1);XCTAssertEqual(state.tracks[0].modified,1)
        XCTAssertEqual(state.profiles.first?.name,"Listener");XCTAssertEqual(state.memberships["/music/song.mp3"],["/music"])
        XCTAssertEqual(try Data(contentsOf:db),before)
    }
    func testPreparedClipDecodesWithMetadataRemoved() throws {
        let root=try temporary(),input=root.appendingPathComponent("track.wav")
        XCTAssertEqual(try Media.run("ffmpeg",["-v","error","-f","lavfi","-i","sine=frequency=440:duration=6","-metadata","title=Secret title","-y",input.path]).status,0)
        let track=try Media.probe(input,source:"nas"),url=try Media.clip(track,seconds:5,directory:root)
        XCTAssertEqual(track.title,"Secret title")
        let clip=try Media.probe(url,source:"nas");XCTAssertNotEqual(clip.title,"Secret title");XCTAssertEqual(clip.duration,5,accuracy:0.1)
    }
}
