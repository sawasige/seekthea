import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// OPML (Outline Processor Markup Language) フォーマットでソースを
/// インポート/エクスポートするためのサービス。
/// Reeder / NetNewsWire / Feedly / Inoreader 等からの移行用途を想定。
enum OPML {
    /// インポート時のパース結果。
    struct ParsedSource {
        let name: String
        let feedURL: URL
        let siteURL: URL?
        let category: String?
    }

    struct ImportSummary {
        var added: Int = 0
        var skipped: Int = 0

        var summaryText: String {
            switch (added, skipped) {
            case (0, 0): return "変更なし"
            case (let a, 0): return "ソース \(a)件追加"
            case (0, let s): return "全 \(s)件 既存と重複のためスキップ"
            case (let a, let s): return "ソース \(a)件追加、\(s)件は重複のためスキップ"
            }
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case invalidXML
        case noFeedsFound

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "OPMLファイルの形式が正しくありません。"
            case .noFeedsFound: return "OPMLファイル内にRSSフィードが見つかりませんでした。"
            }
        }
    }

    // MARK: - Export

    /// 現在のソース一覧をカテゴリごとにグルーピングした OPML 文字列にする。
    static func export(context: ModelContext) -> Data {
        let sources = ((try? context.fetch(FetchDescriptor<Source>(sortBy: [SortDescriptor(\.addedAt)]))) ?? [])
        let grouped = Dictionary(grouping: sources, by: { $0.category.isEmpty ? "未分類" : $0.category })
        let categoryOrder = grouped.keys.sorted()

        let dateString = ISO8601DateFormatter().string(from: Date())
        var xml = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <opml version=\"2.0\">
          <head>
            <title>Seekthea Sources</title>
            <dateCreated>\(dateString)</dateCreated>
          </head>
          <body>

        """

        for category in categoryOrder {
            let safeCategory = escape(category)
            xml += "    <outline text=\"\(safeCategory)\" title=\"\(safeCategory)\">\n"
            for source in grouped[category] ?? [] {
                let name = escape(source.displayName)
                let feedURL = escape(source.feedURL.absoluteString)
                let siteURL = escape(source.siteURL.absoluteString)
                xml += "      <outline type=\"rss\" text=\"\(name)\" title=\"\(name)\" xmlUrl=\"\(feedURL)\" htmlUrl=\"\(siteURL)\"/>\n"
            }
            xml += "    </outline>\n"
        }

        xml += """
          </body>
        </opml>
        """

        return Data(xml.utf8)
    }

    // MARK: - Import

    /// OPML データからフィード一覧を抽出する（カテゴリのネストは 1 階層を想定）。
    static func parse(data: Data) throws -> [ParsedSource] {
        let parser = XMLParser(data: data)
        let delegate = OPMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw Error.invalidXML
        }
        let parsed = delegate.results
        if parsed.isEmpty { throw Error.noFeedsFound }
        return parsed
    }

    /// パース結果を SwiftData に取り込む。feedURL が既存と重複するものはスキップ。
    @MainActor
    static func importFeeds(_ feeds: [ParsedSource], into context: ModelContext) -> ImportSummary {
        let existing = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let existingFeedURLs = Set(existing.map(\.feedURL))

        var summary = ImportSummary()
        for feed in feeds {
            if existingFeedURLs.contains(feed.feedURL) {
                summary.skipped += 1
                continue
            }
            let source = Source(
                name: feed.name,
                feedURL: feed.feedURL,
                siteURL: feed.siteURL ?? feed.feedURL,
                category: feed.category ?? ""
            )
            context.insert(source)
            summary.added += 1
        }
        try? context.save()
        return summary
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XMLParserDelegate

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var results: [OPML.ParsedSource] = []
    /// 現在開いているグループ outline の text/title スタック（ネストに対応）。
    /// xmlUrl 持ちの outline に到達したらスタックトップを category として使う。
    private var groupStack: [String] = []
    /// outline ごとに「グループとして push したか」を記録するスタック。
    /// didEndElement で feed/group を区別して groupStack を正しく pop するため。
    private var didPushGroup: [Bool] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String]) {
        guard elementName.lowercased() == "outline" else { return }

        // 他リーダー由来のファイルが xmlurl / xmlUrl / XMLURL 等で出力する可能性に備え
        // 属性名は case-insensitive に取得する。
        let attrs = Dictionary(uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) })

        if let xmlUrlString = attrs["xmlurl"], let feedURL = URL(string: xmlUrlString) {
            let name = attrs["text"] ?? attrs["title"] ?? feedURL.host ?? xmlUrlString
            let siteURL = attrs["htmlurl"].flatMap(URL.init(string:))
            let category = groupStack.last
            results.append(OPML.ParsedSource(
                name: name,
                feedURL: feedURL,
                siteURL: siteURL,
                category: category
            ))
            didPushGroup.append(false)
        } else {
            let title = attrs["text"] ?? attrs["title"] ?? ""
            groupStack.append(title)
            didPushGroup.append(true)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName.lowercased() == "outline" else { return }
        if didPushGroup.popLast() == true, !groupStack.isEmpty {
            groupStack.removeLast()
        }
    }
}

// MARK: - FileDocument

/// fileExporter / fileImporter 用の OPML ラッパー
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        // .opml が UTType として登録されていない環境では .xml にフォールバック
        if let opml = UTType(filenameExtension: "opml") {
            return [opml, .xml]
        }
        return [.xml]
    }
    static var writableContentTypes: [UTType] {
        if let opml = UTType(filenameExtension: "opml") {
            return [opml]
        }
        return [.xml]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
