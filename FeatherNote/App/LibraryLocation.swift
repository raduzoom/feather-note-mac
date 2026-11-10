import Foundation

/// Where the one library of this install lives (design spec "Local storage").
enum LibraryLocation {
    static let overrideArgument = "-FeatherLibraryPath"

    /// The folder name before the app was renamed to FeatherMark (2026-11-10).
    static let formerName = "Feather Note"
    static let name = "FeatherMark"

    static func directory(arguments: [String] = CommandLine.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          fileManager: FileManager = .default,
                          supportDirectory: URL? = nil) -> URL {
        if let i = arguments.firstIndex(of: overrideArgument), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        // A unit-test run launches the app as its host: never let it open the person's real library.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return fileManager.temporaryDirectory.appending(path: "FeatherNote-TestHost-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        let support = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appending(path: name, directoryHint: .isDirectory)
        // A library made under the former name moves once; an existing FeatherMark library is never replaced.
        let former = support.appending(path: formerName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: former.path) {
            try? fileManager.moveItem(at: former, to: current)
        }
        return current
    }
}
