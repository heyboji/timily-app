import Foundation

enum EntrySource: String, Codable {
    case manual
    case timer
    case fromActivity
}

enum RuleKind: String, Codable {
    case application
    case domain
    case url
    case titleContains
    case pathContains
}
