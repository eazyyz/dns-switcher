import Foundation
import DNSSwitcherCore

enum PrivilegedCommand {
    // Arguments are data, never interpolated into AppleScript source.
    static let script = """
    on run argv
        set commandText to ""
        repeat with argument in argv
            set commandText to commandText & quoted form of (contents of argument) & " "
        end repeat
        try
            return do shell script commandText with administrator privileges
        on error messageText number errorNumber
            if errorNumber is -128 then return "DNS_SWITCHER_CANCELLED"
            error messageText number errorNumber
        end try
    end run
    """

    static func apply(_ profile: Profile?, executable: URL) throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SwitcherError("Не найден DNS-сервис. Распакуйте приложение повторно.")
        }
        var arguments = [executable.path]
        if let profile = profile {
            try DNSList.validate(profile)
            arguments += ["--apply-profile", try JSONEncoder().encode(profile).base64EncodedString()]
        } else {
            arguments += ["--apply", "1"]
        }
        return try execute(arguments: arguments) != "DNS_SWITCHER_CANCELLED"
    }

    static func execute(arguments: [String], script: String = script) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        // Allow the user time to answer the system password dialog.
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw SwitcherError(text.isEmpty ? "Не удалось переключить DNS." : String(text.suffix(4000)))
        }
        return text
    }
}
