import Foundation
/// Local stand-in for the Objective-C bridge (type-checking on Windows only).
final class NXPython {
    static var isStarted: Bool { false }
    static func start(withHome home: String, paths: [String]) -> String? { nil }
    static func call(_ module: String, function: String, args: [Any], error: inout NSString?) -> String? { nil }
    static func run(_ source: String) -> String? { nil }
}
