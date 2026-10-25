import SwiftUI
import AppKit

@main struct JipassApp: App {
    @StateObject private var model: GameModel
    init() {
        let configured=ProcessInfo.processInfo.environment["JIPASS_DATA"] ?? Bundle.main.object(forInfoDictionaryKey:"JipassDataPath") as? String
        let directory=configured.map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("jipass")
        _model=StateObject(wrappedValue:GameModel(directory:directory))
    }
    var body: some Scene {
        WindowGroup("jipass") { RootView().environmentObject(model).frame(minWidth:840,minHeight:650).preferredColorScheme(.light) }
        .defaultSize(width:1200,height:820)
        .commands { CommandGroup(replacing:.appSettings) { Button("Settings…") { model.settings=true }.keyboardShortcut(",") } }
    }
}
extension Color {
    static let paper=Color(red:0.961,green:0.953,blue:0.925)
    static let ink=Color(red:0.133,green:0.153,blue:0.122)
    static let forest=Color(red:0.15,green:0.21,blue:0.18)
    static let orange=Color(red:0.914,green:0.369,blue:0.208)
    static let muted=Color(red:0.46,green:0.48,blue:0.43)
    static let line=Color(red:0.86,green:0.87,blue:0.82)
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View { configuration.label.font(.system(size:14,weight:.bold)).foregroundColor(.white).padding(.horizontal,24).padding(.vertical,16).background(Color.orange.opacity(configuration.isPressed ? 0.75:1),in:RoundedRectangle(cornerRadius:9)).scaleEffect(configuration.isPressed ? 0.98:1) }
}
struct Eyebrow: View { var text:String;var body:some View { Text(text.uppercased()).font(.system(size:10,weight:.bold)).tracking(2).foregroundColor(.muted) } }
struct RootView: View {
    @EnvironmentObject var m:GameModel
    @State var leaveConfirmation=false
    @State var destination:GameModel.Page = .play
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:5) { Text("j").font(.custom("Georgia-Italic",size:58)).foregroundColor(.orange);Text("jipass").font(.system(size:34,weight:.heavy)).tracking(-2) }.padding(.bottom,24)
                Eyebrow(text:"Your listening room")
                nav("Play a round",symbol:"play.circle",page:.play)
                nav("Your history",symbol:"clock",page:.history)
                nav("Library settings",symbol:"externaldrive",page:.library)
                Spacer()
                Circle().fill(Color.orange).frame(width:7,height:7)
                Text("Local by design.").bold()
                Text("Your music. Your machine.\nNative on your Mac.").font(.system(size:11)).foregroundColor(.muted).lineSpacing(5)
                Eyebrow(text:"JIPASS / VOL. 001")
            }.padding(26).frame(width:205).background(Color.paper)
            Rectangle().fill(Color.line).frame(width:1)
            VStack(spacing:0) {
                HStack {
                    Eyebrow(text:m.state.demo ? "Demo mode / original sketches" : "Your collection, on the record")
                    Spacer()
                    if !m.state.profiles.isEmpty { Picker("Player",selection:$m.state.selectedProfile) { ForEach(m.state.profiles) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width:145).disabled(m.isRound).onChange(of:m.state.selectedProfile){_ in m.persist()} }
                    Button { m.settings=true } label:{ Image(systemName:"gearshape").font(.system(size:17)) }.buttonStyle(.plain).help("Settings")
                }.padding(.horizontal,30).frame(height:65)
                Divider()
                ScrollView {
                    Group {
                        switch m.page {
                        case .play: categoryPage
                        case .library: libraryPage
                        case .history: historyPage
                        case .game: gamePage
                        case .results: resultsPage
                        }
                    }.padding(30).frame(maxWidth:1200)
                }
                HStack { Text("YOUR MUSIC / STAYS HERE");Spacer();Text("JIPASS · NATIVE MAC EDITION") }.font(.system(size:8,weight:.semibold)).tracking(1).foregroundColor(.muted).padding(18)
            }
        }.foregroundColor(.ink).background(Color.paper)
        .sheet(isPresented:$m.settings){settingsPage}
        .alert("jipass",isPresented:Binding(get:{m.error != nil},set:{if !$0 {m.error=nil}})){Button("OK"){m.error=nil}}message:{Text(m.error ?? "")}
        .confirmationDialog("Leave this round? Answered questions are saved in your history.",isPresented:$leaveConfirmation){Button("Leave round",role:.destructive){m.leave();m.page=destination};Button("Keep playing",role:.cancel){}}
    }
    func nav(_ label:String,symbol:String,page:GameModel.Page) -> some View {
        Button { if m.isRound {destination=page;leaveConfirmation=true} else {m.page=page} } label:{HStack{Image(systemName:symbol);Text(label);Spacer()}.font(.system(size:12,weight:.semibold)).padding(12).background(m.page == page ? Color.line.opacity(0.65):Color.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)
    }
    var categoryPage:some View {
        VStack(alignment:.leading,spacing:24) {
            Eyebrow(text:"Drop the needle")
            (Text("You know the music.\n").font(.system(size:47,weight:.medium))+Text("Prove it.").font(.custom("Georgia-Italic",size:53))).tracking(-2)
            Text("A few seconds. Four answers. Your entire collection.").foregroundColor(.muted)
            HStack {
                Picker("Categories",selection:$m.categoryMode){Text("Genres").tag("genre");Text("Artists").tag("artist")}.pickerStyle(.segmented).labelsHidden().frame(width:200).onChange(of:m.categoryMode){_ in m.category="";m.search=""}
                Spacer();TextField(m.categoryMode == "artist" ? "Find an artist…":"Find a genre…",text:$m.search).textFieldStyle(.roundedBorder).frame(maxWidth:240)
            }
            if m.state.demo { Label("DEMO MODE · Original synthesized sketches",systemImage:"waveform").font(.system(size:12,weight:.semibold)).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:8)) }
            Divider()
            HStack(alignment:.top,spacing:20) {
                VStack(alignment:.leading){Eyebrow(text:"Set the tempo");Text("Your round, your rules.").font(.system(size:21,weight:.semibold))}
                Spacer()
                VStack(alignment:.leading){Text("I'm guessing").font(.caption).foregroundColor(.muted);Picker("Question type",selection:$m.mode){ForEach(QuestionKind.allCases,id:\.self){Text($0.label).tag($0)}}.labelsHidden().frame(width:165).disabled(m.categoryMode == "artist" && !m.category.isEmpty)}
                VStack(alignment:.leading){Text("Questions").font(.caption).foregroundColor(.muted);Picker("Questions",selection:$m.length){ForEach([5,10,15],id:\.self){Text("\($0)").tag($0)}}.labelsHidden().frame(width:70)}
                VStack(alignment:.leading){Text("Clip length").font(.caption).foregroundColor(.muted);Picker("Clip length",selection:$m.seconds){ForEach([5.0,10.0,15.0],id:\.self){Text("\(Int($0)) sec").tag($0)}}.labelsHidden().frame(width:80)}
            }
            if m.categoryMode == "artist" && !m.category.isEmpty { Text("Guess song titles by \(m.category). Other answers prefer this artist’s songs.").font(.caption).foregroundColor(.muted) }
            else if m.mode == .mixed && Set(m.sourceTracks.filter{normalized($0.artist) != "unknown artist"}.map{normalized($0.artist)}).count < 4 { Text("Mixed mode uses titles until your library has four distinct artists for artist questions.").font(.caption).foregroundColor(.muted) }
            HStack { Button("Start the round ↗"){m.startRound()}.buttonStyle(PrimaryButton()).disabled(m.busy || m.sourceTracks.isEmpty);Spacer();Text("500 correct + up to 500 speed bonus\nWrong answer or timeout = 0").font(.caption).foregroundColor(.muted).multilineTextAlignment(.trailing) }
            if m.busy {ProgressView(m.message).progressViewStyle(.linear)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:210),spacing:16)],spacing:18) {
                categoryCard("Mixed library",count:m.sourceTracks.count,mixed:true)
                ForEach(m.categories,id:\.name){categoryCard($0.name,count:$0.count)}
            }
            if m.sourceTracks.isEmpty { Text("Your listening room is waiting. Add a music folder in Library settings, or try Demo mode in Settings.").foregroundColor(.muted).padding(.vertical,15) }
        }
    }
    func categoryCard(_ name:String,count:Int,mixed:Bool=false) -> some View {
        let selected=mixed ? m.category.isEmpty : normalized(m.category)==normalized(name)
        return VStack(spacing:0) {
            Button {m.category=mixed ? "":name} label:{
                VStack(spacing:0) {
                    ZStack {
                        Rectangle().fill(mixed ? Color(red:0.89,green:0.69,blue:0.48):Color(red:0.82,green:0.86,blue:0.76))
                        if !mixed,let url=m.image(name),let image=NSImage(contentsOf:url) {GeometryReader{g in Image(nsImage:image).resizable().scaledToFill().frame(width:g.size.width,height:g.size.height,alignment:.top).clipped()}}
                        else if mixed {RecordView().frame(width:114,height:114)}
                        else {Text(name.split(separator:" ").prefix(2).compactMap{$0.first.map(String.init)}.joined()).font(.custom("Georgia-Italic",size:38)).foregroundColor(.forest).frame(width:90,height:90).background(Color.paper.opacity(0.55),in:Circle())}
                    }.frame(height:155).clipped()
                    HStack(alignment:.top){VStack(alignment:.leading,spacing:6){Text(name).font(.system(size:14,weight:.bold)).lineLimit(2);Text("\(count) tracks · \(mixed ? "A little of everything":count < m.length ? "Needs \(m.length) tracks":"Guess their \(m.categoryMode == "artist" ? "songs":"music")")").font(.system(size:10)).foregroundColor(.muted)};Spacer();Image(systemName:selected ? "checkmark.circle.fill":"circle").foregroundColor(selected ? .orange:.muted)}.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                }.background(Color.paper).clipShape(RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(selected ? Color.orange:Color.line,lineWidth:selected ? 2:1))
            }.buttonStyle(.plain)
            if m.state.debug && !mixed {HStack{Button("Change image"){m.upload(name)};Spacer();Button("Reset"){m.resetImage(name)}}.font(.caption).padding(.top,8)}
        }.task(id:sourceTaskKey(name,mixed:mixed)){if !mixed {await m.loadPhoto(name)}}
    }
    func sourceTaskKey(_ name:String,mixed:Bool)->String { m.source + m.categoryMode + name }
    var libraryPage:some View {
        VStack(alignment:.leading,spacing:22) {
            Eyebrow(text:"Your music / stays here")
            Text("Bring your\ncollection home.").font(.custom("Georgia",size:47)).tracking(-2)
            Text("Mount your NAS on this Mac, then add its music folders. Credentials stay with macOS. Your original files remain untouched.").foregroundColor(.muted)
            HStack{Button("Add music folders…"){m.addFolder()}.buttonStyle(PrimaryButton());Button("Rescan all folders"){m.rescan()}.disabled(m.state.folders.isEmpty);Spacer();Text("\(m.state.tracks.filter{$0.source == "nas"}.count) indexed tracks").foregroundColor(.muted)}.disabled(m.busy)
            ForEach(m.state.folders){folder in HStack{Image(systemName:"externaldrive").font(.title2);VStack(alignment:.leading,spacing:7){Text(folder.path).font(.system(size:13,weight:.semibold)).textSelection(.enabled);Text(folder.status).font(.caption).foregroundColor(.muted)};Spacer();Button("Remove"){m.removeFolder(folder)}.disabled(m.busy)}.padding(18).background(Color.white.opacity(0.45),in:RoundedRectangle(cornerRadius:9))}
            if m.busy {ProgressView().progressViewStyle(.linear)}
            Text(m.message).font(.caption).foregroundColor(.muted)
            Text("MP3, FLAC, M4A, AAC, Ogg, Opus, WAV, AIFF, WMA, ALAC and APE through FFmpeg. Unchanged files are skipped. Missing tags use filename, Unknown artist or Uncategorized.").font(.caption).foregroundColor(.muted)
            Text("Native saves: \(m.storage.directory.path)").font(.caption).foregroundColor(.muted).textSelection(.enabled)
        }
    }
    var gamePage:some View {
        VStack(spacing:22) {
            HStack{Eyebrow(text:"Track \(min(m.results.count + (m.feedback == nil ? 1:0),m.length)) / \(m.length)");Spacer();Text("\(m.total) POINTS").font(.system(size:13,weight:.bold))}
            ProgressView(value:Double(m.results.count),total:Double(m.length)).tint(.orange)
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.top,spacing:28){deck.frame(width:310);question.frame(minWidth:350)}
                VStack(spacing:24){deck;question}
            }
        }
    }
    var deck:some View {
        VStack(spacing:25) {
            HStack{Eyebrow(text:m.state.demo ? "Demo / original sketch":"Your local collection");Spacer()}
            ZStack {
                if let art=m.artwork,let image=NSImage(contentsOf:art){Image(nsImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:9))}
                else {RecordView().padding(15)}
            }.frame(height:265)
            HStack(alignment:.bottom,spacing:7){ForEach(0..<20){i in Rectangle().fill(Color(red:0.65,green:0.72,blue:0.56)).frame(height:CGFloat(6+(i*17)%25))}}.frame(height:32)
            Divider().overlay(Color.white.opacity(0.25))
            HStack{Button{m.play()}label:{Image(systemName:m.playing ? "pause.fill":"play.fill").foregroundColor(.forest).frame(width:43,height:43).background(Color.paper,in:Circle())}.buttonStyle(.plain).disabled(m.busy || m.options.isEmpty);VStack(alignment:.leading,spacing:5){Text(m.feedback == nil ? "Listen closely":"Track revealed").font(.system(size:12,weight:.bold));Text(m.feedback?.track.title ?? (m.busy ? "Preparing audio…":"Trust your ears.")).font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(2)};Spacer()}
            Slider(value:$m.volume,in:0...1){Text("Volume")}.tint(Color.paper).accessibilityLabel("Volume")
            if m.busy {ProgressView().tint(.white)}
        }.padding(24).foregroundColor(Color.paper).background(Color.forest,in:RoundedRectangle(cornerRadius:13))
    }
    var question:some View {
        VStack(alignment:.leading,spacing:18) {
            Eyebrow(text:m.currentKind == .artist ? "Identify the artist":"Identify the song title")
            Text(m.currentKind == .artist ? "Who’s the artist?":"Name that song.").font(.system(size:35,weight:.medium)).tracking(-1.5)
            HStack{Eyebrow(text:m.busy ? "Preparing audio":"Pick your answer · 1–4");Spacer();Text(String(format:"%.1fs",m.remaining)).font(.system(size:23,weight:.bold,design:.rounded)).monospacedDigit()}
            ProgressView(value:m.remaining,total:max(1,m.seconds)).tint(.orange)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:14) {
                ForEach(Array(m.options.enumerated()),id:\.element.id){index,choice in answerButton(choice,index:index)}
            }
            if let result=m.feedback {
                VStack(alignment:.leading,spacing:12) {
                    HStack{Image(systemName:result.correct ? "checkmark.circle.fill":"xmark.circle.fill").font(.system(size:32));VStack(alignment:.leading,spacing:4){Eyebrow(text:result.timeout ? "Time’s up":result.correct ? "Correct answer":"Incorrect answer");Text(result.correct ? (result.elapsed < 3 ? "Lightning ears!":"You know your music!"):"Next one’s yours.").font(.system(size:19,weight:.bold))};Spacer();Text("+\(result.points)").font(.system(size:28,weight:.heavy))}
                    Text(String(format:"%.2fs response · ",result.elapsed)+(result.correct ? "500 correct + \(result.points-500) speed bonus":"0 points")).font(.caption)
                    if result.correct && m.streak > 1 {Label("\(m.streak) correct in a row",systemImage:"flame.fill").font(.caption.bold())}
                    Divider()
                    HStack{if let url=m.artwork,let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFill().frame(width:48,height:48).clipped().cornerRadius(5)};VStack(alignment:.leading,spacing:5){Text(result.track.title).bold();Text(result.track.artist + " · " + result.track.album).font(.caption)}}
                }.padding(18).foregroundColor(result.correct ? Color(red:0.32,green:0.47,blue:0.23):Color(red:0.65,green:0.30,blue:0.22)).background(result.correct ? Color(red:0.90,green:0.94,blue:0.85):Color.orange.opacity(0.10),in:RoundedRectangle(cornerRadius:12))
                Button(m.results.count >= m.length ? "See your results ↗":"Next track ↗"){m.next()}.buttonStyle(PrimaryButton()).keyboardShortcut(.return,modifiers:[])
            }
        }.frame(maxWidth:.infinity)
    }
    func answerButton(_ choice:Choice,index:Int) -> some View {
        let correct=m.isCorrectChoice(choice),selectedWrong=m.feedback != nil && m.selectedChoice == choice.id && !correct,wrong=m.feedback != nil && !correct && m.selectedChoice != choice.id
        return Button{m.answer(choice.id)}label:{
            HStack(spacing:10){Text(correct ? "✓":selectedWrong ? "×":String("ABCD"[String.Index(utf16Offset:index,in:"ABCD")])).font(.system(size:16,weight:.bold)).frame(width:30,height:30).background(correct ? Color.green.opacity(0.3):Color.line,in:Circle());Text(choice.label).font(.system(size:13,weight:.semibold)).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)}.padding(14).frame(maxWidth:.infinity,minHeight:102).background(correct ? Color(red:0.86,green:0.93,blue:0.80):selectedWrong ? Color.orange.opacity(0.18):Color.white.opacity(0.55),in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(correct ? Color.green:selectedWrong ? Color.orange:Color.line,lineWidth:2)).opacity(wrong ? 0.45:1)
        }.buttonStyle(.plain).disabled(!m.canAnswer).keyboardShortcut(KeyEquivalent(Character(String(index+1))),modifiers:[])
    }
    var resultsPage:some View {
        VStack(alignment:.leading,spacing:25) {
            Eyebrow(text:"That’s a wrap")
            Text("Well played.").font(.custom("Georgia-Italic",size:55))
            if let record=m.completed {
                HStack(spacing:35){stat("Total score","\(record.total)");stat("Accuracy","\(record.accuracy)%");stat("Average",String(format:"%.2fs",record.average));stat("Personal best","\(m.personalBest)")}
                if m.skipped > 0 {Text("Skipped \(m.skipped) unsupported or unavailable tracks.").font(.caption).foregroundColor(.muted)}
                ForEach(record.results){resultRow($0)}
            }
            Button("One more round ↗"){m.page = .play}.buttonStyle(PrimaryButton())
        }
    }
    func stat(_ label:String,_ value:String)->some View{VStack(alignment:.leading,spacing:6){Eyebrow(text:label);Text(value).font(.system(size:30,weight:.bold))}}
    func resultRow(_ r:ResultEntry)->some View {HStack{Image(systemName:r.correct ? "checkmark.circle.fill":"xmark.circle.fill").foregroundColor(r.correct ? .green:.orange);VStack(alignment:.leading,spacing:5){Text(r.track.title).bold();Text(r.track.artist + " · " + r.track.album).font(.caption).foregroundColor(.muted)};Spacer();Text(String(format:"%.2fs",r.elapsed)).font(.caption);Text("+\(r.points)").bold()}.padding(14).background(Color.white.opacity(0.4),in:RoundedRectangle(cornerRadius:8))}
    var historyPage:some View {
        VStack(alignment:.leading,spacing:20) {
            Eyebrow(text:"On the record");Text("Your listening history.").font(.system(size:38,weight:.medium)).tracking(-1)
            let records=m.state.history.filter{$0.profile == m.state.selectedProfile}.sorted{$0.date > $1.date}
            if records.isEmpty {Text("Your first round is waiting.").foregroundColor(.muted)}
            ForEach(records){record in DisclosureGroup{ForEach(record.results){resultRow($0)}}label:{HStack{VStack(alignment:.leading,spacing:5){Text(record.date,style:.date).bold();Text("\(record.results.count)/\(record.requested) tracks · \(record.kind.label) · \(record.source == "demo" ? "Demo":"Library")").font(.caption).foregroundColor(.muted)};Spacer();Text("\(record.accuracy)% · \(record.total) pts").bold()}.padding(.vertical,9)}}
        }
    }
    var settingsPage:some View {
        VStack(alignment:.leading,spacing:23) {
            HStack{Text("Settings").font(.system(size:30,weight:.semibold));Spacer();Button("Done"){m.settings=false}.keyboardShortcut(.cancelAction)}
            Divider()
            Toggle("Demo mode",isOn:Binding(get:{m.state.demo},set:{m.setDemo($0)})).disabled(m.isRound || m.busy)
            Text("Try 18 original synthesized sketches. Your own music is selected by default.").font(.caption).foregroundColor(.muted)
            Toggle("BIG CHIEF'M (Debug)",isOn:$m.state.debug).onChange(of:m.state.debug){_ in m.persist()}
            Text("Shows image upload and reset controls for artist and genre cards. Uploaded pictures stay on this Mac.").font(.caption).foregroundColor(.muted)
            Divider()
            Text("Local players").font(.headline)
            HStack{TextField("New player name",text:$m.profileName).textFieldStyle(.roundedBorder).onSubmit{m.addProfile()};Button("Add player"){m.addProfile()}.disabled(m.isRound || m.profileName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
            Text("Scoring: 500 + round(500 × (1 − response time ÷ clip duration)). Wrong answers and timeouts earn zero.").font(.caption).foregroundColor(.muted)
            Text("Python and the browser are no longer required. FFmpeg and ffprobe are used for audio decoding. Cached artist photos and your existing game data are imported locally.").font(.caption).foregroundColor(.muted)
            DisclosureGroup("Artist photo credits") {
                ScrollView { VStack(alignment:.leading,spacing:10) { ForEach(m.credits){credit in
                    VStack(alignment:.leading,spacing:3){Text(credit.artist).bold();Text(credit.author + " · " + credit.license).font(.caption);if credit.matched != credit.artist {Text("Lead artist photo: " + credit.matched).font(.caption)};if let url=credit.source {Link("Photo source",destination:url)};if let url=credit.licenseURL {Link("License",destination:url)}}
                } } }.frame(maxHeight:160)
            }
            Text("Automatic artist photos send only the artist name to Wikipedia/Wikimedia. Cached pictures work offline.").font(.caption).foregroundColor(.muted)
            Button("Show local data folder"){NSWorkspace.shared.open(m.storage.directory)}
        }.padding(30).frame(width:510).background(Color.paper)
    }
}
struct RecordView:View {
    var body:some View {GeometryReader{g in let size=min(g.size.width,g.size.height)
        ZStack{Circle().fill(Color.forest);ForEach(0..<10){i in Circle().stroke(Color(red:0.33,green:0.41,blue:0.30),lineWidth:1.5).padding(CGFloat(i+1)*size/28)};Circle().fill(Color.orange).frame(width:size*0.34,height:size*0.34);Text("j").font(.custom("Georgia-Italic",size:size*0.39)).foregroundColor(.paper).offset(x:-size*0.015,y:-size*0.01)}.frame(width:size,height:size).frame(maxWidth:.infinity,maxHeight:.infinity)
    }}
}
