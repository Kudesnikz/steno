import CryptoKit
import Foundation

public actor BedrockClient {
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Sends a minimal signed Bedrock Converse request for the selected Nova model.
    public func validateConfiguration(config: AppConfig, model: AIModelReference) async throws {
        let body = BedrockConverseRequest(
            messages: [
                BedrockMessage(
                    role: "user",
                    content: [.text("Ответь одним словом: ok")]
                )
            ],
            system: [BedrockTextBlock(text: "Health check")]
        )
        _ = try await converse(body: body, config: config, modelID: model.modelID, context: "health check")
    }

    /// Sends the meeting video through Bedrock Converse using a native `video` content block.
    public func generateReport(
        videoURL: URL,
        transcript: AITranscriptContext?,
        config: AppConfig,
        model: AIModelReference,
        agent: Agent
    ) async throws -> AIProcessingResult {
        let start = Date()
        let body = BedrockConverseRequest(
            messages: [
                BedrockMessage(
                    role: "user",
                    content: [
                        .text(AIPromptBuilder.meetingAnalysisPrompt(videoURL: videoURL, transcript: transcript)),
                        .video(BedrockVideoBlock(format: videoURL.bedrockVideoFormat, source: BedrockVideoSource(bytes: try Data(contentsOf: videoURL).base64EncodedString())))
                    ]
                )
            ],
            system: [BedrockTextBlock(text: PromptSecurity.systemPrompt(for: agent))]
        )

        let response = try await converse(body: body, config: config, modelID: model.modelID, context: "generate report")
        let text = response.output.message.content.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIClientError.emptyResponse
        }

        let usage = response.usage
        return AIProcessingResult(
            text: text,
            metadata: AIProcessingMetadata(
                durationSeconds: Int(Date().timeIntervalSince(start)),
                tokensInput: usage?.inputTokens ?? 0,
                tokensOutput: usage?.outputTokens ?? 0,
                tokensTotal: usage?.totalTokens ?? 0,
                model: model.displayName,
                agentName: agent.name,
                outputFileName: "",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    /// Lists Bedrock foundation models with input modalities for dynamic video filtering.
    public func listFoundationModels(config: AppConfig) async throws -> [RemoteAIModelCapability] {
        let region = normalizedRegion(config.awsRegion)
        let url = try bedrockURL(region: region, path: "/foundation-models", runtime: false)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try sign(request: &request, body: Data(), config: config, region: region, service: "bedrock")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response, data: data, provider: AIProviderID.amazonBedrock.displayName, context: "GET /foundation-models")
        let models = try decoder.decode(BedrockListModelsResponse.self, from: data)
        return models.modelSummaries.map {
            RemoteAIModelCapability(
                modelID: $0.modelID,
                displayName: $0.modelName,
                inputModalities: $0.inputModalities
            )
        }
    }

    private func converse(
        body: BedrockConverseRequest,
        config: AppConfig,
        modelID: String,
        context: String
    ) async throws -> BedrockConverseResponse {
        let region = normalizedRegion(config.awsRegion)
        let path = "/model/\(modelID)/converse"
        let url = try bedrockURL(region: region, path: path, runtime: true)
        let bodyData = try encoder.encode(body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        try sign(request: &request, body: bodyData, config: config, region: region, service: "bedrock")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response, data: data, provider: AIProviderID.amazonBedrock.displayName, context: "POST \(path) \(context)")
        return try decoder.decode(BedrockConverseResponse.self, from: data)
    }

    private func bedrockURL(region: String, path: String, runtime: Bool) throws -> URL {
        let serviceHost = runtime ? "bedrock-runtime" : "bedrock"
        guard let url = URL(string: "https://\(serviceHost).\(region).amazonaws.com\(path)") else {
            throw AIClientError.invalidURL("https://\(serviceHost).\(region).amazonaws.com\(path)")
        }
        return url
    }

    private func sign(request: inout URLRequest, body: Data, config: AppConfig, region: String, service: String) throws {
        guard let url = request.url,
              let host = url.host else {
            throw AIClientError.invalidURL(request.url?.absoluteString ?? "")
        }

        let accessKeyID = config.awsAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = config.awsSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKeyID.isEmpty, !secretAccessKey.isEmpty else {
            throw AIClientError.missingAPIKey(.amazonBedrock)
        }

        let now = Date()
        let amzDate = awsDateFormatter.string(from: now)
        let dateStamp = awsDateStampFormatter.string(from: now)
        let payloadHash = sha256Hex(body)
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        let sessionToken = config.awsSessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let canonicalHeaders = canonicalHeaderString(from: request)
        let signedHeaders = signedHeaderString(from: request)
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            url.path.isEmpty ? "/" : url.path,
            url.query ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = awsSigningKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = hmacSHA256Hex(key: signingKey, message: stringToSign)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private var awsDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    private var awsDateStampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }

    private func canonicalHeaderString(from request: URLRequest) -> String {
        headerPairs(from: request)
            .map { "\($0.name):\($0.value)\n" }
            .joined()
    }

    private func signedHeaderString(from request: URLRequest) -> String {
        headerPairs(from: request)
            .map(\.name)
            .joined(separator: ";")
    }

    private func headerPairs(from request: URLRequest) -> [(name: String, value: String)] {
        (request.allHTTPHeaderFields ?? [:])
            .map { key, value in
                (
                    name: key.lowercased(),
                    value: value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func awsSigningKey(secretAccessKey: String, dateStamp: String, region: String, service: String) -> Data {
        let dateKey = hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), message: dateStamp)
        let dateRegionKey = hmacSHA256(key: dateKey, message: region)
        let dateRegionServiceKey = hmacSHA256(key: dateRegionKey, message: service)
        return hmacSHA256(key: dateRegionServiceKey, message: "aws4_request")
    }

    private func hmacSHA256(key: Data, message: String) -> Data {
        let key = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(code)
    }

    private func hmacSHA256Hex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message).hexString
    }

    private func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    private func normalizedRegion(_ region: String) -> String {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "us-east-1" : trimmed
    }

    private func validate(_ response: URLResponse, data: Data, provider: String, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIClientError.apiError(provider: provider, status: http.statusCode, message: httpErrorMessage(statusCode: http.statusCode, data: data), context: context)
        }
    }

    private func httpErrorMessage(statusCode: Int, data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        let rawMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawMessage.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : String(rawMessage.prefix(800))
    }
}

private struct BedrockConverseRequest: Encodable {
    var messages: [BedrockMessage]
    var system: [BedrockTextBlock]
}

private struct BedrockMessage: Encodable {
    var role: String
    var content: [BedrockContentBlock]
}

private enum BedrockContentBlock: Encodable {
    case text(String)
    case video(BedrockVideoBlock)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(text, forKey: .text)
        case let .video(video):
            try container.encode(video, forKey: .video)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case video
    }
}

private struct BedrockTextBlock: Codable {
    var text: String
}

private struct BedrockVideoBlock: Encodable {
    var format: String
    var source: BedrockVideoSource
}

private struct BedrockVideoSource: Encodable {
    var bytes: String
}

private struct BedrockConverseResponse: Decodable {
    var output: BedrockOutput
    var usage: BedrockUsage?
}

private struct BedrockOutput: Decodable {
    var message: BedrockResponseMessage
}

private struct BedrockResponseMessage: Decodable {
    var content: [BedrockResponseContentBlock]
}

private struct BedrockResponseContentBlock: Decodable {
    var text: String?
}

private struct BedrockUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
}

private struct BedrockListModelsResponse: Decodable {
    var modelSummaries: [BedrockModelSummary]
}

private struct BedrockModelSummary: Decodable {
    var modelID: String
    var modelName: String?
    var inputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case modelName
        case inputModalities
    }
}

private extension URL {
    var bedrockVideoFormat: String {
        switch pathExtension.lowercased() {
        case "mkv":
            "mkv"
        case "mov":
            "mov"
        case "webm":
            "webm"
        case "flv":
            "flv"
        case "mpeg":
            "mpeg"
        case "mpg":
            "mpg"
        case "wmv":
            "wmv"
        case "3gp", "3gpp":
            "three_gp"
        default:
            "mp4"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
