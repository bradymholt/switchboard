import AppKit

struct ServiceConfig: Codable, Hashable, Identifiable {
    var name: String
    var url: URL
    var profile: String?
    var icon: String?
    var badge: String?
    var userAgent: String?

    var id: String { name }
}

enum ConfigFile {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/switchboard")
    static let url = directory.appending(path: "services.json")

    static let starter = """
    [
      { "name": "Asana", "url": "https://app.asana.com" },
      { "name": "Gmail", "url": "https://mail.google.com/mail/u/0/", "profile": "work" },
      { "name": "Gmail (Personal)", "url": "https://mail.google.com/mail/u/0/", "profile": "personal" },
      { "name": "Calendar", "url": "https://calendar.google.com", "profile": "work" }
    ]

    """

    static func load() -> Result<[ServiceConfig], Error> {
        Result {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try starter.write(to: url, atomically: true, encoding: .utf8)
            }
            let services = try JSONDecoder().decode([ServiceConfig].self, from: Data(contentsOf: url))
            var seen = Set<String>()
            for service in services {
                guard seen.insert(service.name).inserted else {
                    throw ConfigError("Duplicate service name \"\(service.name)\"")
                }
                guard ["http", "https"].contains(service.url.scheme) else {
                    throw ConfigError("\"\(service.name)\" needs an http(s) URL")
                }
            }
            return services
        }
    }

    static var modificationDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    static func open() {
        NSWorkspace.shared.open(url)
    }
}

struct ConfigError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
