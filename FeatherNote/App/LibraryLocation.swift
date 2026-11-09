import Foundation

/// Where the one library of this install lives (design spec "Local storage").
enum LibraryLocation {
    static let overrideArgument = "-FeatherLibraryPath"

    static func directory(arguments: [String] = CommandLine.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          fileManager: FileManager = .default) -> URL {
        if let i = arguments.firstIndex(of: overrideArgument), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        // A unit-test run launches the app as its host: never let it open the person's real library.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return fileManager.temporaryDirectory.appending(path: "FeatherNote-TestHost-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Feather Note", directoryHint: .isDirectory)
    }
}
