import Foundation

/// Runs shell commands as root through the standard macOS admin password dialog.
/// Shared by the wake helper and the lid helper installers.
enum AdminShell {
    /// What `run` does. Tests replace it so nothing ever asks for an admin password.
    nonisolated(unsafe) static var runner: (String, String, @escaping (Bool) -> Void) -> Void = runWithOsascript
    /// The program that shows the dialog. Tests point it at a stand-in script.
    nonisolated(unsafe) static var osascriptPath = "/usr/bin/osascript"

    static func run(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        runner(command, prompt, completion)
    }

    /// The AppleScript that runs `command` as root, with `\` and `"` escaped for the script string.
    static func appleScript(for command: String, prompt: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    static func runWithOsascript(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        let apple = appleScript(for: command, prompt: prompt)
        let osascript = osascriptPath

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: osascript)
            p.arguments = ["-e", apple]
            let err = Pipe()
            p.standardError = err
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                if !ok {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    NSLog("MacAwake: admin command failed: \(msg)")
                }
            } catch {
                NSLog("MacAwake: could not run osascript: \(error)")
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Single-quotes a string for /bin/sh.
    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `# macawake-helper-version: N` marker in a helper script. 1 if there's none (the first helpers
    /// shipped without it), nil if the file can't be read.
    static func helperVersion(atPath path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(10) {
            if let r = line.range(of: "# macawake-helper-version:") {
                return Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) ?? 1
            }
        }
        return 1
    }
}
