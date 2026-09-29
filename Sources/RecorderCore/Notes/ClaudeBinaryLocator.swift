import Foundation

/// Trouve le binaire `claude` installé sur la machine : d'abord les chemins
/// d'installation connus, puis le PATH du shell de l'utilisateur.
///
/// Une app GUI n'hérite pas du PATH configuré dans `~/.zshrc` : sans le repli
/// sur le shell de l'utilisateur, une install nvm ou à un emplacement perso
/// reste introuvable (l'ancien repli `/bin/sh -lc` ne lit pas `~/.zshrc`).
public struct ClaudeBinaryLocator: Sendable {
    public typealias ShellLookup = @Sendable () async -> String?

    private let home: URL
    private let systemPaths: [String]
    private let shellLookup: ShellLookup

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemPaths: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                shellLookup: @escaping ShellLookup = { await ClaudeBinaryLocator.loginShellLookup() }) {
        self.home = home
        self.systemPaths = systemPaths
        self.shellLookup = shellLookup
    }

    /// Le premier exécutable trouvé, ou `nil`. Le shell n'est interrogé que si
    /// aucun chemin connu ne convient (il peut prendre plusieurs secondes).
    public func locate() async -> URL? {
        if let hit = knownCandidates().first(where: Self.isExecutable) { return hit }
        guard let path = await shellLookup() else { return nil }
        let url = URL(fileURLWithPath: path)
        return Self.isExecutable(url) ? url : nil
    }

    /// Ordre : install locale, installeur natif, nvm (version la plus récente
    /// d'abord), puis chemins système (Homebrew).
    func knownCandidates() -> [URL] {
        var candidates = [
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".local/bin/claude"),
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        candidates += versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin/claude") }
        candidates += systemPaths.map { URL(fileURLWithPath: $0) }
        return candidates
    }

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Dernière ligne qui est un chemin absolu : un `.zshrc` peut imprimer du
    /// bruit avant, et `command -v` répond « alias claude=… » pour un alias.
    static func parseShellOutput(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    /// `command -v claude` dans un shell login + interactif (`-lic`), pour que
    /// `~/.zprofile` ET `~/.zshrc` soient lus. Au-delà de `timeout`, le shell
    /// est tué et la réponse est `nil`.
    public static func loginShellLookup(shell: String = userShell(),
                                        timeout: TimeInterval = 5) async -> String? {
        // Appel bloquant (waitUntilExit) : hors du pool coopératif Swift.
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-lic", "command -v claude"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { once.resume(nil); return }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                    once.resume(nil)
                }
                // Un sous-processus orphelin peut garder le pipe ouvert après
                // le timeout ; la réponse est alors déjà rendue (nil).
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { once.resume(nil); return }
                once.resume(parseShellOutput(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    public static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

/// Reprend une continuation une seule fois (fin normale OU timeout).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
