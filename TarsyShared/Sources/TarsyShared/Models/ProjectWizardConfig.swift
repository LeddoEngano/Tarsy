import Foundation

public struct ProjectWizardConfig: Codable, Sendable {
    public var projectName: String
    public var projectDescription: String
    public var language: String
    public var framework: String
    public var dependencies: [String]
    public var stack: String
    public var suggestedPath: String
    public var initialPrompt: String
    public var additionalNotes: String?

    public init(
        projectName: String = "",
        projectDescription: String = "",
        language: String = "",
        framework: String = "",
        dependencies: [String] = [],
        stack: String = "web",
        suggestedPath: String = "",
        initialPrompt: String = "",
        additionalNotes: String? = nil
    ) {
        self.projectName = projectName
        self.projectDescription = projectDescription
        self.language = language
        self.framework = framework
        self.dependencies = dependencies
        self.stack = stack
        self.suggestedPath = suggestedPath
        self.initialPrompt = initialPrompt
        self.additionalNotes = additionalNotes
    }

    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode(from json: String) throws -> ProjectWizardConfig {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON string"))
        }
        return try JSONDecoder().decode(ProjectWizardConfig.self, from: data)
    }
}
