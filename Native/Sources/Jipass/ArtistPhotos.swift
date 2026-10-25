import Foundation

struct PhotoCredit: Identifiable {
    var id:String { artist }
    var artist:String
    var matched:String
    var author:String
    var license:String
    var source:URL?
    var licenseURL:URL?
}
actor ArtistPhotos {
    static let shared=ArtistPhotos()
    private var checked=Set<String>()
    private let hosts:Set<String>=["en.wikipedia.org","commons.wikimedia.org","upload.wikimedia.org","thumb.wikimedia.org"]
    func download(_ url:URL) async throws -> Data {
        guard url.scheme == "https",hosts.contains(url.host ?? "") else {throw GameError(message:"Unsupported photo host")}
        var request=URLRequest(url:url);request.timeoutInterval=12;request.setValue("jipass/2.0 (local music trivia; artist photo cache)",forHTTPHeaderField:"User-Agent")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse,response.statusCode == 200,hosts.contains(response.url?.host ?? ""),data.count <= 5*1024*1024 else {throw GameError(message:"Photo unavailable")}
        return data
    }
    func json(_ host:String,_ parameters:[String:String]) async throws -> [String:Any] {
        var url=URLComponents(string:"https://" + host + "/w/api.php")!;url.queryItems=parameters.map{URLQueryItem(name:$0.key,value:$0.value)}
        return try JSONSerialization.jsonObject(with:await download(url.url!)) as? [String:Any] ?? [:]
    }
    func fetch(_ name:String,directory:URL) async -> Bool {
        let key=digest(normalized(name)),folder=directory.appendingPathComponent("artist-photos"),record=folder.appendingPathComponent(key+".json"),image=folder.appendingPathComponent(key+".jpg")
        guard checked.insert(key).inserted else {return false}
        if FileManager.default.fileExists(atPath:image.path){return false}
        if let raw=try? Data(contentsOf:record),let saved=try? JSONSerialization.jsonObject(with:raw) as? [String:Any],let time=saved["checked"] as? Double,Date().timeIntervalSince1970-time < 86400{return false}
        do {
            var names=[name,name+" (band)",name+" (musician)"]
            if name.contains(","){names.append(String(name.split(separator:",")[0]).trimmingCharacters(in:.whitespaces))}
            let response=try await json("en.wikipedia.org",["action":"query","format":"json","prop":"pageimages|pageprops","titles":names.joined(separator:"|"),"piprop":"thumbnail|name","pithumbsize":"640","redirects":"1"])
            let pages=(response["query"] as? [String:Any])?["pages"] as? [String:[String:Any]] ?? [:]
            for wanted in names {
                for page in pages.values where normalized(page["title"] as? String ?? "") == normalized(wanted) {
                    let props=page["pageprops"] as? [String:Any] ?? [:],description=(props["wikibase-shortdesc"] as? String ?? "").lowercased()
                    guard props["disambiguation"] == nil,props["page_image_free"] != nil,["music","band","singer","rapper","rock","pop","artist","composer","dj"].contains(where:description.contains),let title=page["pageimage"] as? String,let thumb=(page["thumbnail"] as? [String:Any])?["source"] as? String,let url=URL(string:thumb) else {continue}
                    let commons=try await json("commons.wikimedia.org",["action":"query","format":"json","prop":"imageinfo","titles":"File:"+title,"iiprop":"extmetadata"])
                    let entries=(commons["query"] as? [String:Any])?["pages"] as? [String:[String:Any]] ?? [:]
                    let metadata=((entries.values.first?["imageinfo"] as? [[String:Any]])?.first?["extmetadata"] as? [String:[String:Any]]) ?? [:]
                    func value(_ key:String)->String { (metadata[key]?["value"] as? String ?? "").replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).replacingOccurrences(of:"&amp;",with:"&") }
                    guard !value("LicenseShortName").isEmpty else {continue}
                    let raw=try await download(url),input=folder.appendingPathComponent(UUID().uuidString+".tmp"),output=folder.appendingPathComponent(UUID().uuidString+".jpg")
                    try raw.write(to:input);defer{try? FileManager.default.removeItem(at:input);try? FileManager.default.removeItem(at:output)}
                    let result=try Media.run("ffmpeg",["-nostdin","-v","error","-i",input.path,"-frames:v","1","-vf","scale=640:640:force_original_aspect_ratio=decrease","-map_metadata","-1","-y",output.path],timeout:15)
                    guard result.status == 0 else {continue}
                    let source="https://commons.wikimedia.org/wiki/File:"+(title.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? title)
                    let saved:[String:Any]=["artist":name,"matched_artist":page["title"] as? String ?? name,"author":value("Artist"),"license":value("LicenseShortName"),"source_url":source,"license_url":value("LicenseUrl"),"checked":Date().timeIntervalSince1970]
                    // Never replace a custom image written while a lookup was in flight.
                    if !FileManager.default.fileExists(atPath:image.path) {try FileManager.default.moveItem(at:output,to:image);try JSONSerialization.data(withJSONObject:saved).write(to:record,options:.atomic)}
                    return true
                }
            }
            try JSONSerialization.data(withJSONObject:["artist":name,"checked":Date().timeIntervalSince1970]).write(to:record,options:.atomic)
        } catch {
            // Keep the monogram and retry temporary failures on a later launch.
        }
        return false
    }
    static func credits(directory:URL)->[PhotoCredit] {
        let folder=directory.appendingPathComponent("artist-photos")
        return ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension == "json"}.compactMap{url in
            guard let raw=try? Data(contentsOf:url),let row=try? JSONSerialization.jsonObject(with:raw) as? [String:Any],let artist=row["artist"] as? String,let license=row["license"] as? String else {return nil}
            func link(_ key:String)->URL? {guard let value=row[key] as? String,let url=URL(string:value),url.scheme == "https" else{return nil};return url}
            return PhotoCredit(artist:artist,matched:row["matched_artist"] as? String ?? artist,author:row["author"] as? String ?? "",license:license,source:link("source_url"),licenseURL:link("license_url"))
        }.sorted{$0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending}
    }
}
