// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperLingo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaperLingo", targets: ["PaperLingo"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PaperCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PaperLingo", dependencies: ["PaperCore"]),
        .executableTarget(name: "PaperCoreChecks", dependencies: ["PaperCore"], path: "Tests/PaperCoreTests"),
        .executableTarget(name: "PaperResearchSmoke", dependencies: ["PaperCore"]),
        .executableTarget(name: "PaperResearchBenchmark", dependencies: ["PaperCore"]),
        .executableTarget(name: "PaperWordExplanationSmoke", dependencies: ["PaperCore"]),
        .executableTarget(name: "PaperRetrievalBenchmark", dependencies: ["PaperCore"])
    ]
)
