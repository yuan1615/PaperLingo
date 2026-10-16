import Foundation

public enum EvidenceKind: String, Codable, Sendable { case narrative, experiment, dataProfile, references }

public struct ResearchEvidence: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var paperID: String
    public var page: Int
    public var section: String
    public var label: String
    public var kind: EvidenceKind
    public var text: String
    public var contextIDs: [String] = []
    public init(paperID: String, page: Int, section: String, label: String = "", kind: EvidenceKind, text: String) {
        self.paperID=paperID; self.page=page; self.section=section; self.label=label; self.kind=kind; self.text=text
        id=ResearchText.hash("\(paperID):\(page):\(label):\(text)")
    }
}

public struct ExperimentMeasurement: Codable, Equatable, Sendable, Identifiable {
    public var id: String { ResearchText.hash(method+metric+value+condition+evidenceID+quote) }
    public var method: String
    public var metric: String
    public var value: String
    public var condition: String
    public var evidenceID: String
    public var quote: String
}

public struct ExperimentRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: EvidenceKind
    public var evidenceIDs: [String]
    public var dataset: String
    public var task: String
    public var metrics: [String]
    public var conditions: String
    public var limitations: String
    public var measurements: [ExperimentMeasurement]
    public var extracted: Bool
    public var rejectedFields: Int
}

public struct ExperimentReview: Codable, Equatable, Sendable {
    public var paperID: String
    public var experimentID: String
    public var reviewed: Bool
    public var annotation: String
    public init(paperID: String, experimentID: String, reviewed: Bool = false, annotation: String = "") {
        self.paperID=paperID; self.experimentID=experimentID; self.reviewed=reviewed; self.annotation=annotation
    }
}

public struct ResearchLedger: Codable, Equatable, Sendable {
    public var paperID: String
    public var sourceHash: String
    public var version: String
    public var model: String
    public var created: Date
    public var totalPages: Int
    public var evidence: [ResearchEvidence]
    public var experiments: [ExperimentRecord]
    public var facts: [DigestPoint]
    public var analyzedEvidenceIDs: [String]
    public var completed: Bool
    public var modelCalls: Int
    public var elapsedSeconds: Double
    public var bibliography: ResearchBibliography
    public init(paperID: String, sourceHash: String, totalPages: Int, evidence: [ResearchEvidence], model: String) {
        self.paperID=paperID; self.sourceHash=sourceHash; self.totalPages=totalPages; self.evidence=evidence; self.model=model
        version=ResearchStructure.version; created=Date(); facts=[]; analyzedEvidenceIDs=[]; completed=false; modelCalls=0; elapsedSeconds=0
        bibliography=ResearchBibliography()
        experiments=evidence.filter { $0.kind == .experiment || $0.kind == .dataProfile }.map {
            ExperimentRecord(id:$0.id,title:$0.label,kind:$0.kind,evidenceIDs:[$0.id]+$0.contextIDs,dataset:"",task:"",metrics:[],conditions:"",limitations:"",measurements:[],extracted:false,rejectedFields:0)
        }
    }
}

public struct ResearchBibliography: Codable, Equatable, Sendable {
    public var title=""
    public var authors:[String]=[]
    public var year=""
    public var venue=""
    public var doi=""
    public var arxiv=""
    public init() {}
}

/// All raw sources are retained. The model reads a bounded evidence plan, and
/// coverage records the actual submitted sources rather than claiming full reading.
public enum ResearchStructure {
    public static let version="evidence-ledger-v2"
    public static let indexVersion="paper-overview-v4"
    public static func matches(_ text:String,_ pattern:String)->Bool {text.range(of:pattern,options:.regularExpression) != nil}
    public static func clean(_ text:String)->String {
        text.replacingOccurrences(of:"\u{00AD}",with:"")
            .replacingOccurrences(of:"([A-Za-z])-\\s*\\n\\s*([a-z])",with:"$1$2",options:.regularExpression)
            .replacingOccurrences(of:"[\\t ]+",with:" ",options:.regularExpression)
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }
    public static func heading(_ line:String)->Bool {
        let s=line.trimmingCharacters(in:.whitespacesAndNewlines)
        guard s.count < 100 else{return false}
        return matches(s,"^(?:[0-9]+(?:\\.[0-9]+)*\\.?\\s+[A-Z][A-Za-z -]{2,80}|[A-G]\\.?\\s+[A-Z][A-Za-z -]{2,80})$")
            || matches(s,"(?i)^(abstract|references|bibliography|acknowledg(?:e)?ments|appendix(?: [A-G])?|limitations|broader impact|conclusions?|results(?: and discussion)?)$")
    }
    public static func sources(paperID:String,pages:[String])->[ResearchEvidence] {
        var result:[ResearchEvidence]=[];var section="Opening";var reference=false
        for (page,raw) in pages.enumerated() {
            let lines=clean(raw).components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}
            var buffer:[String]=[];var table="";var tableKind:EvidenceKind = .experiment
            func flush() {
                let text=clean(buffer.joined(separator:"\n"));buffer=[]
                guard text.count > 2 else{return}
                if !table.isEmpty && !matches(text,"(?i)^Table\\s+[0-9]+[.:]$") {
                    let pieces=split(text,size:6000,overlap:200)
                    for (index,piece) in pieces.enumerated() {
                        let label=table+(pieces.count>1 ? " [part \(index+1)/\(pieces.count)]":"")
                        result.append(ResearchEvidence(paperID:paperID,page:page,section:section,label:label,kind:tableKind,text:piece))
                    }
                    table="";return
                }
                table=""
                for part in split(text,size:1700,overlap:120) {
                    let measured = !reference && !matches(part,"(?i)table\\s+[0-9]") && matches(section,"(?i)(result|evaluation|experiment|ablation|inference speed)") && matches(part,"[0-9]+\\.[0-9]+") && matches(part,"(?i)(WER|CER|accuracy|latency|RTF|BLEU|F1|throughput|MOS)")
                    result.append(ResearchEvidence(paperID:paperID,page:page,section:section,label:measured ? "实验段落 · \(section)":"",kind:reference ? .references:(measured ? .experiment:.narrative),text:part))
                }
            }
            for line in lines {
                if matches(line,"^[0-9]{1,3}$"),line == lines.last {continue}
                if matches(line,"(?i)^Table\\s+[0-9]+[.:]") && !matches(line,"(?i)^Table\\s+[0-9]+\\.\\s*(we |it |these |as shown)") {
                    flush();table=line;buffer=[line]
                    tableKind=matches(line,"(?i)(supported languages|training (?:data|corpus)|data(?:set)? (?:statistics|distribution)|data duration|hours of (?:training|audio))") ? .dataProfile:.experiment
                    continue
                }
                if heading(line) {
                    flush();section=line;reference=matches(line,"(?i)^(references|bibliography|acknowledg)");continue
                }
                if !table.isEmpty && buffer.count > 4 && matches(line,"^(?:We |As shown|To validate|Firstly|Secondly|In this |These results|This (?:table|result)|The results|Note that)") {flush()}
                if line.isEmpty {
                    if table.isEmpty {flush()}
                } else {buffer.append(line)}
            }
            flush()
        }
        let setup=result.filter{$0.kind == .narrative && $0.text.count>20 && matches($0.section,"(?i)(evaluation benchmarks|experimental setup|evaluation metrics)")}.prefix(2)
        for i in result.indices where result[i].kind == .experiment {
            let local=result[..<i].filter{$0.kind == .narrative && $0.text.count>20 && $0.page >= result[i].page-1}.suffix(2)
            let sectionSetup=result[..<i].first{$0.kind == .narrative && $0.text.count>20 && $0.section == result[i].section}
            result[i].contextIDs=Array(Set(setup.map(\.id)+local.map(\.id)+(sectionSetup.map{[$0.id]} ?? []))).sorted()
        }
        return result
    }
    public static func split(_ text:String,size:Int,overlap:Int)->[String] {
        var rest=text;var parts:[String]=[]
        while rest.count > size {
            let cap=rest.index(rest.startIndex,offsetBy:size)
            let minimum=rest.index(rest.startIndex,offsetBy:max(1,size/2))
            let window=String(rest[minimum..<cap])
            let punctuation=window.range(of:"[.!?]\\s+|\\n",options:[.regularExpression,.backwards])
            let boundary=punctuation.map{rest.index(minimum,offsetBy:window.distance(from:window.startIndex,to:$0.upperBound))}
                ?? rest[..<cap].lastIndex(where:{$0.isWhitespace}) ?? cap
            let part=String(rest[..<boundary]).trimmingCharacters(in:.whitespacesAndNewlines)
            if !part.isEmpty {parts.append(part)}
            let back=min(overlap,max(0,rest.distance(from:rest.startIndex,to:boundary)-1))
            var start=rest.index(boundary,offsetBy:-back)
            if back > 0,let space=rest[start..<boundary].firstIndex(where:{$0.isWhitespace}) {start=rest.index(after:space)}
            rest=String(rest[start...]).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        if !rest.isEmpty {parts.append(rest)}
        return parts
    }
    public static func chunks(paperID:String,pages:[String],size:Int=1400,overlap:Int=140)->[PaperTextChunk] {
        var ordinals:[Int:Int]=[:]
        return sources(paperID:paperID,pages:pages).flatMap { source in
            split(source.text,size:max(100,size),overlap:min(max(0,overlap),max(100,size)/3)).map {part in
                let ordinal=ordinals[source.page,default:0];ordinals[source.page]=ordinal+1
                return PaperTextChunk(paperID:paperID,page:source.page,ordinal:ordinal,text:"[\(source.kind.rawValue)] \(source.section)\n\(part)")
            }
        }
    }
    public static func plan(_ ledger:ResearchLedger,budget:Int=24000)->[[ResearchEvidence]] {
        let experiments=ledger.evidence.filter{$0.kind == .experiment}
        let narratives=ledger.evidence.filter{$0.kind == .narrative && $0.text.count>20}
        // Preserve section diversity. Bibliographies/data-language listings never
        // consume the experimental evidence budget; their full sources remain stored.
        var chosen:[ResearchEvidence]=[];var used=Set<String>()
        func add(_ e:ResearchEvidence){if used.insert(e.id).inserted{chosen.append(e)}}
        for e in narratives.prefix(2){add(e)}
        for e in narratives.filter({matches($0.section,"(?i)(method|architecture|approach|framework|design)")}).prefix(2){add(e)}
        for e in narratives.filter({matches($0.section,"(?i)(limitations|conclusion|broader impact)")}).suffix(3){add(e)}
        for e in narratives.filter({matches($0.text,"(?i)(we propose|our contributions|we introduce|ablation experiments|experimental setup|evaluate the inference)")}).prefix(3){add(e)}
        let contextIDs=Set(experiments.flatMap(\.contextIDs))
        for e in narratives where contextIDs.contains(e.id){add(e)}
        if chosen.reduce(0,{$0+$1.text.count})+experiments.reduce(0,{$0+$1.text.count}) <= budget {
            return [chosen+experiments]
        }
        if experiments.isEmpty {
            var groups:[[ResearchEvidence]]=[];var group:[ResearchEvidence]=[];var chars=0
            for source in chosen {
                if chars+source.text.count>budget && !group.isEmpty {groups.append(group);group=[];chars=0}
                group.append(source);chars+=source.text.count
            }
            if !group.isEmpty {groups.append(group)}
            return groups.isEmpty ? [Array(narratives.prefix(8))]:groups
        }
        var base:[ResearchEvidence]=[];var baseSize=0
        for source in chosen where !contextIDs.contains(source.id) {
            if baseSize+source.text.count<=6000 {base.append(source);baseSize+=source.text.count}
        }
        var planned:[[ResearchEvidence]]=[];var current=base;var currentIDs=Set(base.map(\.id));var chars=baseSize
        for experiment in experiments {
            let contexts=narratives.filter{experiment.contextIDs.contains($0.id)}
            var additions=(contexts+[experiment]).filter{!currentIDs.contains($0.id)}
            if chars+additions.reduce(0,{$0+$1.text.count})>budget && current.contains(where:{$0.kind == .experiment}) {
                planned.append(current);current=[];currentIDs=[];chars=0;additions=contexts+[experiment]
            }
            for source in additions where currentIDs.insert(source.id).inserted {current.append(source);chars+=source.text.count}
        }
        if !current.isEmpty {planned.append(current)}
        return planned
    }
}

public struct StructuredDraft: Codable, Sendable {
    public struct Fact:Codable,Sendable {public var topic:DigestTopic;public var source:String;public var quote:String}
    public struct Row:Codable,Sendable {
        public var method:String;public var metric:String;public var value:String;public var condition:String
        public var source:String?=nil;public var quote:String?=nil;public var line:Int?=nil
    }
    public struct Experiment:Codable,Sendable {
        public var source:String;public var dataset:String;public var task:String;public var metrics:[String]
        public var conditions:String;public var limitations:String;public var rows:[Row]
    }
    public var bibliography:ResearchBibliography
    public var facts:[Fact]
    public var experiments:[Experiment]
    public var truncated:Bool?=nil
    public static func recover(_ text:String)->StructuredDraft? {
        func objects(_ key:String,array:Bool)->[Data] {
            guard let range=text.range(of:"\"\(key)\"\\s*:\\s*",options:.regularExpression) else{return []}
            let chars=Array(text[range.upperBound...]);var quoted=false;var escaped=false;var depth=0;var start:Int?;var result:[Data]=[]
            for (i,c) in chars.enumerated() {
                if quoted {if escaped{escaped=false}else if c == "\\"{escaped=true}else if c == "\""{quoted=false};continue}
                if c == "\""{quoted=true;continue}
                if c == "{" {if depth == 0 {start=i};depth+=1}
                else if c == "}" {depth-=1;if depth == 0,let start {result.append(Data(String(chars[start...i]).utf8));if !array{return result}}}
                else if c == "]" && depth == 0 && array {break}
            }
            return result
        }
        let decoder=JSONDecoder()
        let facts=objects("facts",array:true).compactMap{try? decoder.decode(Fact.self,from:$0)}
        let experiments=objects("experiments",array:true).compactMap{try? decoder.decode(Experiment.self,from:$0)}
        let bibliography=objects("bibliography",array:false).first.flatMap{try? decoder.decode(ResearchBibliography.self,from:$0)} ?? ResearchBibliography()
        guard !facts.isEmpty || !experiments.isEmpty else{return nil}
        return StructuredDraft(bibliography:bibliography,facts:facts,experiments:experiments,truncated:true)
    }
    public func applying(to old:ResearchLedger,sources:[ResearchEvidence])->ResearchLedger {
        var ledger=old;let lookup=Dictionary(uniqueKeysWithValues:sources.enumerated().map{("E\($0.offset)",$0.element)})
        func contains(_ source:ResearchEvidence,_ value:String)->Bool {
            !value.isEmpty && TextTools.clean(source.text).range(of:TextTools.clean(value),options:[.caseInsensitive,.diacriticInsensitive]) != nil
        }
        if sources.contains(where:{$0.page == 0}) {
            let opening=sources.filter{$0.page == 0}
            func found(_ value:String)->String {opening.contains(where:{contains($0,value)}) ? value:""}
            var b=ResearchBibliography();b.title=found(bibliography.title);b.authors=bibliography.authors.filter{!found($0).isEmpty}
            b.year=found(bibliography.year);b.venue=found(bibliography.venue);b.doi=found(bibliography.doi);b.arxiv=found(bibliography.arxiv)
            ledger.bibliography=b
        }
        for fact in facts.prefix(8) {
            guard fact.topic != .results && fact.topic != .reuse,let source=lookup[fact.source],source.kind == .narrative,
                  fact.quote.count >= 18,fact.quote.count <= 600,contains(source,fact.quote) else{continue}
            let point=DigestPoint(topic:fact.topic,text:TextTools.clean(fact.quote),chunkID:source.id,quote:TextTools.clean(fact.quote),page:source.page)
            if !ledger.facts.contains(where:{$0.id == point.id}){ledger.facts.append(point)}
        }
        for draft in experiments {
            guard let source=lookup[draft.source],source.kind == .experiment,let i=ledger.experiments.firstIndex(where:{$0.id == source.id}) else{continue}
            var record=ledger.experiments[i];record.extracted=true
            let related=sources.filter{record.evidenceIDs.contains($0.id)}
            func checked(_ value:String)->String {
                if ["","not reported","not specified","not stated","none","n/a"].contains(value.lowercased()){return ""}
                if related.contains(where:{contains($0,value)}){return value}
                let pieces=value.components(separatedBy:CharacterSet(charactersIn:",;；")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"(?i)^and\\s+",with:"",options:.regularExpression)}
                let valid=pieces.filter{piece in !piece.isEmpty && related.contains(where:{contains($0,piece)})}
                if valid.count<pieces.count || valid.isEmpty{record.rejectedFields+=1}
                return valid.joined(separator:"; ")
            }
            record.dataset=checked(draft.dataset);record.task=checked(draft.task);record.metrics=draft.metrics.compactMap{let v=checked($0);return v.isEmpty ? nil:v}
            record.conditions=checked(draft.conditions);record.limitations=checked(draft.limitations)
            record.measurements=draft.rows.prefix(4).compactMap { row in
                var evidence=row.source.flatMap{lookup[$0]} ?? source
                let lines=evidence.text.components(separatedBy:.newlines)
                var quote=row.line.flatMap{lines.indices.contains($0) ? lines[$0]:nil} ?? row.quote ?? ""
                var literalValue=ResearchNumbers.cell(for:row.value,in:quote)
                guard related.contains(where:{contains($0,row.method)}),contains(source,row.metric) else{record.rejectedFields+=1;return nil}
                if literalValue == nil {
                    // An incorrect line pointer must not turn a correct number
                    // elsewhere into evidence for another method. Rescue only
                    // a unique line containing BOTH the exact method and cell.
                    let methodPattern="(?<![A-Za-z0-9-])"+NSRegularExpression.escapedPattern(for:row.method)+"(?![A-Za-z0-9-])"
                    let candidates=related.flatMap { e in e.text.components(separatedBy:.newlines).compactMap {line -> (ResearchEvidence,String,String)? in
                        guard line.range(of:methodPattern,options:[.regularExpression,.caseInsensitive]) != nil,let cell=ResearchNumbers.cell(for:row.value,in:line) else{return nil}
                        return(e,line,cell)
                    }}
                    guard candidates.count == 1 else{record.rejectedFields+=1;return nil}
                    evidence=candidates[0].0;quote=candidates[0].1;literalValue=candidates[0].2;record.rejectedFields+=1
                }
                guard related.contains(where:{$0.id == evidence.id}),contains(evidence,quote),quote.count>=4,let literalValue else{record.rejectedFields+=1;return nil}
                var conditions:[String]=[]
                for atom in row.condition.components(separatedBy:CharacterSet(charactersIn:",;；")).map({$0.trimmingCharacters(in:.whitespacesAndNewlines)}) where !atom.isEmpty {
                    if related.contains(where:{contains($0,atom)}) {conditions.append(atom);continue}
                    if let actual=ResearchNumbers.condition(atom,in:related.map(\.text).joined(separator:"\n"),row:quote){conditions.append(actual)}
                    else{record.rejectedFields+=1}
                }
                var citation=TextTools.clean(quote)
                if citation.count>420,let range=citation.range(of:TextTools.clean(literalValue)) {
                    let start=citation.index(range.lowerBound,offsetBy:-100,limitedBy:citation.startIndex) ?? citation.startIndex
                    let end=citation.index(start,offsetBy:420,limitedBy:citation.endIndex) ?? citation.endIndex
                    citation=String(citation[start..<end])
                }
                return ExperimentMeasurement(method:row.method,metric:row.metric,value:literalValue,condition:conditions.joined(separator:"; "),evidenceID:evidence.id,quote:citation)
            }
            ledger.experiments[i]=record
        }
        ledger.analyzedEvidenceIDs=Array(Set(ledger.analyzedEvidenceIDs+sources.map(\.id))).sorted()
        ledger.modelCalls+=1
        return ledger
    }
}

public enum ResearchNumbers {
    public static func condition(_ proposed:String,in text:String,row:String)->String? {
        let clean=TextTools.clean(text)
        let pattern="(?i)^batch\\s+size(?:\\s+of)?\\s+([0-9]+)$"
        if let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:proposed,range:NSRange(proposed.startIndex...,in:proposed)),let range=Range(match.range(at:1),in:proposed) {
            let value=String(proposed[range]);let actual="(?i)batch\\s+size(?:\\s+of)?\\s+"+NSRegularExpression.escapedPattern(for:value)+"(?![0-9])"
            if let found=clean.range(of:actual,options:.regularExpression){return String(clean[found])}
        }
        let stepPattern="(?i)^([0-9]+)\\s+(?:inference\\s+)?steps$"
        if let regex=try? NSRegularExpression(pattern:stepPattern),let match=regex.firstMatch(in:proposed,range:NSRange(proposed.startIndex...,in:proposed)),let range=Range(match.range(at:1),in:proposed) {
            let value=String(proposed[range])
            if cell(for:value,in:row) != nil,clean.range(of:"Steps",options:.caseInsensitive) != nil {return "Steps = \(value)"}
        }
        return nil
    }
    /// Copy a complete printed numeric cell. Never accept a substring that
    /// drops a minus sign or leading digit, and retain uncertainty/unit markers.
    public static func cell(for proposed:String,in row:String)->String? {
        guard !proposed.isEmpty,let regex=try? NSRegularExpression(pattern:"[+−-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.[0-9]+)?(?:[eE][+−-]?[0-9]+)?(?:\\s*±\\s*[+−-]?[0-9]+(?:\\.[0-9]+)?)?(?:[%*kKmMgGbB])?") else{return nil}
        func normalized(_ s:String)->String {s.replacingOccurrences(of:"\\s+",with:"",options:.regularExpression).replacingOccurrences(of:"−",with:"-")}
        let wanted=normalized(proposed)
        for match in regex.matches(in:row,range:NSRange(row.startIndex...,in:row)) {
            guard let range=Range(match.range,in:row) else{continue}
            let literal=String(row[range]);let value=normalized(literal)
            if value == wanted{return literal}
            let base=value.components(separatedBy:"±").first!.trimmingCharacters(in:CharacterSet(charactersIn:"%*kKmMgGbB"))
            if base == wanted{return literal}
        }
        return nil
    }
}
