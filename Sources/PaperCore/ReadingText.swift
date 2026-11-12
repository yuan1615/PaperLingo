import Foundation

/// Repairs prose layout while tracking a selection in the original UTF-16 text.
enum ReadingText {
    static let compounds:Set<String> = ["self","cross","zero","few","one","two","three","low","high","well","real","large","small","long","short","task","data","non","single","double","full","part","open","closed","domain","model","language","memory","context","token","word","rule","contrastive"]
    static let suffixes:Set<String> = ["based","free","level","wise","scale","only","aware","driven","dependent","independent","specific","like","centric","conditioned","efficient","compatible","dimensional","shot"]
    static let lineBreak=try! NSRegularExpression(pattern:"\r\n?|\u{2028}|\u{2029}")
    static let escapedBreak=try! NSRegularExpression(pattern:#"\\r\\n|\\[nr](?=\s|$|[A-Z])"#)
    static let softBreak=try! NSRegularExpression(pattern:"\u{00ad}[ \t]*\n[ \t]*")
    static let invisible=try! NSRegularExpression(pattern:"[\u{00ad}\u{200b}\u{feff}]")
    static let wordBreak=try! NSRegularExpression(pattern:"([A-Za-z]+(?:-[A-Za-z]+)*)[-\u{2010}\u{2011}][ \t]*\n[ \t]*([A-Za-z]+(?:-[A-Za-z]+)*)")
    static let numericBreak=try! NSRegularExpression(pattern:"(?<=[A-Za-z0-9])[-\u{2010}\u{2011}][ \t]*\n[ \t]*(?=[0-9])|(?<=[0-9])[-\u{2010}\u{2011}][ \t]*\n[ \t]*(?=[A-Za-z])")
    static let whitespace=try! NSRegularExpression(pattern:#"\s+"#)
    static let edges=try! NSRegularExpression(pattern:"^ | $")
    static let ligatures:[(String,String)] = [("ﬀ","ff"),("ﬁ","fi"),("ﬂ","fl"),("ﬃ","ffi"),("ﬄ","ffl")]

    static func normalize(_ input:String,tracking selection:NSRange=NSRange(location:0,length:0))->(text:String,range:NSRange) {
        var text=input,start=selection.location,end=NSMaxRange(selection)
        func replace(_ regex:NSRegularExpression,_ replacement:(NSTextCheckingResult,NSString)->String) {
            let source=text as NSString
            for match in regex.matches(in:text,range:NSRange(location:0,length:source.length)).reversed() {
                let value=replacement(match,source),length=(value as NSString).length
                if source.substring(with:match.range) == value {continue}
                let lower=match.range.location,upper=NSMaxRange(match.range),delta=length-match.range.length
                func mapped(_ offset:Int,isEnd:Bool)->Int {
                    if offset <= lower {return offset}
                    if offset >= upper {return offset+delta}
                    return lower+(isEnd ? length:0)
                }
                start=mapped(start,isEnd:false);end=mapped(end,isEnd:true)
                text=(text as NSString).replacingCharacters(in:match.range,with:value)
            }
        }
        replace(lineBreak){_,_ in "\n"}
        replace(escapedBreak){_,_ in "\n"}
        replace(softBreak){_,_ in ""}
        replace(invisible){_,_ in ""}
        for (glyph,letters) in ligatures {
            let regex=try! NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:glyph))
            replace(regex){_,_ in letters}
        }
        replace(wordBreak){match,source in
            let left=source.substring(with:match.range(at:1)),right=source.substring(with:match.range(at:2))
            let initialism=left.count > 1 && left == left.uppercased()
            let compound=initialism || left.contains("-") || right.contains("-") || compounds.contains(left.lowercased()) || suffixes.contains(right.lowercased()) || right.first?.isUppercase == true
            return left+(compound ? "-":"")+right
        }
        replace(numericBreak){_,_ in "-"}
        replace(whitespace){_,_ in " "}
        replace(edges){_,_ in ""}
        return (text,NSRange(location:start,length:max(0,end-start)))
    }
}

public enum SpeechText {
    static let citation=try! NSRegularExpression(pattern:#"\[\s*[1-9]\d*(?:\s*[,;–—-]\s*[1-9]\d*)*\s*\]"#)
    static let mathPrefix=try! NSRegularExpression(pattern:#"(?i)(?:[=∈∉<>≤≥+*/−-]|(?:vector|array|tensor|shape|indices|index|values|matrix|range|interval|dimensions?)(?:\s+(?:in|is|of))?)\s*$"#)
    static let subscriptPrefix=try! NSRegularExpression(pattern:#"(?<![A-Za-z])[A-Za-z]$"#)
    static let abbreviation=try! NSRegularExpression(pattern:#"[(（]\s*([A-Za-z][A-Za-z0-9]{1,12})\s*[)）]"#)
    static let acronymPart=try! NSRegularExpression(pattern:"[A-Z][a-z]*|[0-9]+")
    static let morphemes:[String:String] = ["autoencoder":"AE","autoencoders":"AE","autoregressive":"AR"]
    static let word=try! NSRegularExpression(pattern:"[A-Za-z]+")
    static let stops:Set<String> = ["a","an","the","of","for","from","and","or","to","in","on","with","by","at"]

    /// Only a playback copy is filtered; stored quotations retain their evidence.
    public static func prepare(_ input:String)->String {
        var text=TextTools.clean(input)
        let original=text as NSString
        for match in citation.matches(in:text,range:NSRange(location:0,length:original.length)).reversed() {
            let prefix=String(original.substring(to:match.range.location).suffix(60))
            let range=NSRange(location:0,length:(prefix as NSString).length)
            if mathPrefix.firstMatch(in:prefix,range:range) != nil || subscriptPrefix.firstMatch(in:prefix,range:range) != nil {continue}
            text=(text as NSString).replacingCharacters(in:match.range,with:" ")
        }
        let source=text as NSString
        for match in abbreviation.matches(in:text,range:NSRange(location:0,length:source.length)).reversed() {
            var originalAcronym=source.substring(with:match.range(at:1))
            if originalAcronym.hasSuffix("s") {originalAcronym.removeLast()}
            guard originalAcronym.filter({$0.isUppercase}).count >= 2 else {continue}
            let acronym=originalAcronym.uppercased()
            let acronymNS=originalAcronym as NSString
            let parts=acronymPart.matches(in:originalAcronym,range:NSRange(location:0,length:acronymNS.length)).map{acronymNS.substring(with:$0.range).lowercased()}
            let prefix=source.substring(to:match.range.location)
            let clause=String(prefix.components(separatedBy:CharacterSet(charactersIn:".!?;:\n")).last?.suffix(200) ?? "")
            let ns=clause as NSString
            let words=word.matches(in:clause,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range)}
            var expanded=false
            if !words.isEmpty {
                for count in 1...min(12,words.count) {
                    let suffix=words.suffix(count)
                    let all=suffix.compactMap{$0.first}.map{String($0).uppercased()}.joined()
                    let significant=suffix.filter{!stops.contains($0.lowercased())}.compactMap{$0.first}.map{String($0).uppercased()}.joined()
                    let expandedMorphemes=suffix.map{morphemes[$0.lowercased()] ?? String($0.first!).uppercased()}.joined()
                    let prefixes=parts.count == suffix.count && zip(parts,suffix).allSatisfy{$1.lowercased().hasPrefix($0)}
                    if all == acronym || significant == acronym || expandedMorphemes == acronym || prefixes {expanded=true;break}
                }
            }
            if expanded {text=(text as NSString).replacingCharacters(in:match.range,with:" ")}
        }
        text=text.replacingOccurrences(of:#"\s+([,.;:!?])"#,with:"$1",options:.regularExpression)
        return TextTools.clean(text)
    }
}
