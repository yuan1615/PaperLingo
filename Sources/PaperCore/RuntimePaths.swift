import Foundation

/// Installed builds keep immutable engines/models in the app; all writes live in
/// the user's Application Support directory. Development builds retain .runtime.
public struct RuntimePaths {
    public let assets:URL
    public let work:URL
    public let bundled:Bool
    public init(configuration:[String:String],resources:URL,applicationSupport:URL,
                environment:[String:String]=ProcessInfo.processInfo.environment,
                currentDirectory:String=FileManager.default.currentDirectoryPath) {
        if let override=environment["PAPERLINGO_RUNTIME_DIR"] {
            assets=URL(fileURLWithPath:override);bundled=false
        } else if configuration["runtime"] == "bundled" {
            assets=resources.appendingPathComponent("Runtime");bundled=true
        } else {
            assets=URL(fileURLWithPath:configuration["runtime"] ?? currentDirectory+"/.runtime");bundled=false
        }
        if let override=environment["PAPERLINGO_ENGINE_WORK_DIR"] {work=URL(fileURLWithPath:override)}
        else {work=bundled ? applicationSupport.appendingPathComponent("PaperLingo/Engine") : assets}
    }
    public func modelURL(_ path:String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath:path) : assets.appendingPathComponent(path)
    }
    public var ollamaModels:URL {work.appendingPathComponent("ollama-models")}
    public func prepare() throws {
        let manager=FileManager.default
        try manager.createDirectory(at:work.appendingPathComponent("logs"),withIntermediateDirectories:true)
        guard bundled else {return}
        // Ollama can write metadata without changing any signed app resource.
        // Individual weight files are linked; manifests are tiny writable copies.
        let source=assets.appendingPathComponent("ollama-models").resolvingSymlinksInPath()
        let blobs=ollamaModels.appendingPathComponent("blobs")
        try manager.createDirectory(at:blobs,withIntermediateDirectories:true)
        for file in try manager.contentsOfDirectory(at:source.appendingPathComponent("blobs"),includingPropertiesForKeys:nil) {
            let target=blobs.appendingPathComponent(file.lastPathComponent)
            if let old=try? manager.destinationOfSymbolicLink(atPath:target.path) {
                if old == file.path {continue}
                try manager.removeItem(at:target)
            } else if manager.fileExists(atPath:target.path) {continue}
            try manager.createSymbolicLink(at:target,withDestinationURL:file)
        }
        let manifests=source.appendingPathComponent("manifests")
        guard let enumerator=manager.enumerator(atPath:manifests.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // URL enumerators can return /private/var for a /var starting URL on
        // macOS. Relative names avoid corrupt paths when the bundle is moved.
        for case let relative as String in enumerator {
            let file=manifests.appendingPathComponent(relative)
            let target=ollamaModels.appendingPathComponent("manifests").appendingPathComponent(relative)
            if try file.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true {
                try manager.createDirectory(at:target,withIntermediateDirectories:true)
            } else {
                let data=try Data(contentsOf:file)
                if (try? Data(contentsOf:target)) != data {try data.write(to:target,options:.atomic)}
            }
        }
    }
}
