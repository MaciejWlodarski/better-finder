import Foundation

/// Parsing only: never probes, mounts, opens a URL, or runs a shell. The existing
/// transactional pane navigator remains the sole authority for directory access.
enum FolderAddress {
    static func resolve(_ input: String, relativeTo current: URL, home: URL) throws -> URL {
        guard !input.isEmpty else { throw Failure("Wpisz ścieżkę folderu.") }
        guard input.utf8.count <= 16_384,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("Ścieżka jest zbyt długa lub zawiera znaki sterujące.")
        }
        if input.lowercased().hasPrefix("file:") {
            guard let parts = URLComponents(string: input), parts.scheme?.lowercased() == "file",
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  parts.path.hasPrefix("/"),
                  !parts.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let url = parts.url, url.isFileURL else {
                throw Failure("Użyj lokalnej ścieżki lub adresu file:/// bez danych logowania, parametrów i fragmentu.")
            }
            return URL(fileURLWithPath: parts.path, isDirectory: true).standardizedFileURL
        }
        guard !input.contains("://") else {
            throw Failure("Wpisz ścieżkę lokalną. Dla udziału sieciowego użyj jego zamontowanego folderu w /Volumes.")
        }
        let path: String
        if input == "~" { path = home.path }
        else if input.hasPrefix("~/") { path = home.appendingPathComponent(String(input.dropFirst(2))).path }
        else if input.hasPrefix("~") { throw Failure("Użyj ~ lub ~/folder dla własnego folderu domowego.") }
        else { path = input }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: current).standardizedFileURL
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
