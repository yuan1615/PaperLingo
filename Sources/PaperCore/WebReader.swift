import Foundation

public enum HTMLReader {
    public static func extract(_ html: String) -> (String,String) {
        func capture(_ pattern: String, _ source: String) -> String? {
            guard let regex=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]), let result=regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)), let range=Range(result.range(at:1),in:source) else { return nil }
            return String(source[range])
        }
        func decode(_ s: String) -> String {
            var text=s
            for (key,value) in ["&nbsp;":" ","&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&#39;":"'","&apos;":"'","&ndash;":"–","&mdash;":"—","&ldquo;":"“","&rdquo;":"”","&rsquo;":"’"] { text=text.replacingOccurrences(of:key,with:value) }
            if let regex=try? NSRegularExpression(pattern:"&#(x[0-9a-fA-F]+|[0-9]+);") {
                for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
                    let ns=text as NSString, token=ns.substring(with:match.range(at:1))
                    let number=token.hasPrefix("x") ? UInt32(token.dropFirst(),radix:16) : UInt32(token)
                    if let number, let scalar=UnicodeScalar(number), let range=Range(match.range,in:text) { text.replaceSubrange(range,with:String(scalar)) }
                }
            }
            return text
        }
        let title=decode(capture("<title[^>]*>(.*?)</title>",html) ?? "")
        var source=html.replacingOccurrences(of:"(?is)<(script|style|nav|footer|header|noscript|svg|iframe)\\b[^>]*>.*?</\\1\\s*>",with:" ",options:.regularExpression)
        source=capture("<article\\b[^>]*>(.*?)</article>",source) ?? capture("<main\\b[^>]*>(.*?)</main>",source) ?? capture("<body\\b[^>]*>(.*?)</body>",source) ?? source
        source=source.replacingOccurrences(of:"(?i)</?(p|div|h[1-6]|section|article|li|br|tr|blockquote)\\b[^>]*>",with:"\n\n",options:.regularExpression)
        source=source.replacingOccurrences(of:"<[^>]+>",with:" ",options:.regularExpression)
        let paragraphs=decode(source).components(separatedBy:.newlines).map(TextTools.clean).filter{!$0.isEmpty}
        return (TextTools.clean(title),paragraphs.joined(separator:"\n\n"))
    }
}
