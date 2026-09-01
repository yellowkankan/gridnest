import Foundation

struct AppInfo: Identifiable, Hashable, Codable {
    let id: String
    let name: String

    var url: URL { URL(fileURLWithPath: id) }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
