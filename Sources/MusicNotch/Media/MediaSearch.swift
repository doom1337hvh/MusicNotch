import AppKit

/// A song found in the Music library.
struct SearchResult: Identifiable, Equatable, Sendable {
    /// Music's persistent ID for the track.
    let id: String
    let title: String
    let artist: String
}

/// Where a search from the notch goes, for the app on show. Only Music lets another app
/// search it and get results back; Spotify and the web players can only be handed a query,
/// which opens their own search.
enum SearchTarget: Equatable {
    /// Music's library: results show in the notch.
    case musicLibrary
    case spotify
    /// A site's search page, opened in `browser` (a bundle ID), or the default browser.
    case web(WebSite, browser: String?)

    enum WebSite: String {
        case youTube = "YouTube"
        case soundCloud = "SoundCloud"
    }

    var placeholder: String {
        switch self {
        case .musicLibrary: "Search your Music library"
        case .spotify: "Search Spotify"
        case .web(let site, _): "Search \(site.rawValue)"
        }
    }

    /// For hand-offs, what pressing Return does.
    var hint: String? {
        switch self {
        case .musicLibrary: nil
        case .spotify: "Press Return to see the results in Spotify."
        case .web(let site, _): "Press Return to search \(site.rawValue) in your browser."
        }
    }

    private static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// What the app showing `snapshot` can be searched with, if anything.
    @MainActor
    static func forApp(of snapshot: NowPlayingSnapshot) -> SearchTarget? {
        let id = snapshot.sourceAppBundleID
        switch id {
        case "com.apple.Music": return .musicLibrary
        case "com.spotify.client": return .spotify
        default: break
        }
        // A web app (Chrome's are "com.google.Chrome.app.<id>") opens its site in its browser.
        let browser = browsers.first { id == $0 || id.hasPrefix($0 + ".app.") }
        let name = AppNames.name(for: id).lowercased()
        if name.contains("soundcloud") { return .web(.soundCloud, browser: browser) }
        if name.contains("youtube") { return .web(.youTube, browser: browser) }
        // A browser tab could be any site; YouTube is the likeliest to be searched.
        return browser.map { .web(.youTube, browser: $0) }
    }
}

/// App names by bundle ID, looked up once.
@MainActor
enum AppNames {
    private static var cache: [String: String] = [:]

    static func name(for bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        cache[bundleID] = name
        return name
    }
}

/// Searches from the notch: Music's library through AppleScript, or a hand-off that opens
/// the app's or site's own search.
@MainActor
final class MediaSearch {
    private let runner: AppleScriptRunner
    private static let music = "com.apple.Music"
    /// How many results the notch has room for.
    static let maxResults = 6

    init(scripts: AppleScriptRunner) {
        runner = scripts
    }

    /// Songs in the Music library matching `query`, or nil if Music couldn't be asked.
    func searchLibrary(_ query: String, completion: @escaping @MainActor @Sendable ([SearchResult]?) -> Void) {
        let script = """
            tell application id "\(Self.music)"
                set found to search library playlist 1 for "\(Self.escaped(query))" only songs
                if found is missing value then return ""
                set n to count of found
                if n > \(Self.maxResults) then set n to \(Self.maxResults)
                set out to ""
                repeat with i from 1 to n
                    set t to item i of found
                    set out to out & (persistent ID of t) & tab & (name of t) & tab & (artist of t) & linefeed
                end repeat
                return out
            end tell
            """
        runner.run(script, app: Self.music) { output in
            completion(output.map(Self.parse))
        }
    }

    func play(_ result: SearchResult) {
        let script = """
            tell application id "\(Self.music)" to play (some track of library playlist 1 \
            whose persistent ID is "\(Self.escaped(result.id))")
            """
        runner.run(script, app: Self.music) { _ in }
    }

    /// Opens the app's or site's own search for `query`.
    func handOff(_ query: String, to target: SearchTarget) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        switch target {
        case .musicLibrary:
            break
        case .spotify:
            if let url = URL(string: "spotify:search:\(encoded)") { NSWorkspace.shared.open(url) }
        case .web(let site, let browser):
            let address = switch site {
            case .youTube: "https://www.youtube.com/results?search_query=\(encoded)"
            case .soundCloud: "https://soundcloud.com/search?q=\(encoded)"
            }
            guard let url = URL(string: address) else { return }
            if let browser, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// URL-safe characters; everything else, including non-ASCII letters, is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Makes `text` safe inside an AppleScript string literal.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// One "id<TAB>title<TAB>artist" line per song.
    private static func parse(_ output: String) -> [SearchResult] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return SearchResult(id: fields[0], title: fields[1], artist: fields[2])
        }
    }
}
