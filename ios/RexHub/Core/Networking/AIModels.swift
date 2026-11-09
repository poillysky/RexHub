import Foundation

// MARK: - AI 助手

struct AssistantMeta: Decodable, Sendable {
    let suggestChips: [String]
    let webSearchEnabled: Bool
    let sources: [String]

    private enum CodingKeys: String, CodingKey {
        case suggestChips, webSearchEnabled, sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestChips = container.rexArray(.suggestChips, as: String.self)
        webSearchEnabled = container.rexBool(.webSearchEnabled) ?? false
        sources = container.rexArray(.sources, as: String.self)
    }
}

struct AssistantCard: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let source: String
    let title: String
    let subtitle: String
    let meta: String
    let cover: String
    let score: Double?
    let openURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, source, title, subtitle, meta, cover, score, open
    }

    private enum OpenKeys: String, CodingKey {
        case url, hash, kind, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? UUID().uuidString
        source = container.rexString(.source) ?? ""
        title = container.rexString(.title) ?? "资源"
        subtitle = container.rexString(.subtitle) ?? ""
        meta = container.rexString(.meta) ?? ""
        cover = container.rexString(.cover) ?? ""
        score = container.rexDouble(.score)

        let open = try? container.nestedContainer(keyedBy: OpenKeys.self, forKey: .open)
        openURL = open.flatMap { try? $0.decodeIfPresent(String.self, forKey: .url) }
    }
}

struct AssistantStep: Decodable, Hashable, Sendable {
    let tool: String?
    let label: String?
    let query: String?
    let status: String?
    let summary: String?

    private enum CodingKeys: String, CodingKey {
        case tool, label, query, status, summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try? container.decodeIfPresent(String.self, forKey: .tool)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        query = try? container.decodeIfPresent(String.self, forKey: .query)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
    }
}

struct AssistantReply: Decodable, Sendable {
    let reply: String
    let cards: [AssistantCard]
    let steps: [AssistantStep]
    let usedLlm: Bool?
    let toolSummary: String?

    private enum CodingKeys: String, CodingKey {
        case reply, cards, steps, usedLlm, toolSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reply = container.rexString(.reply) ?? ""
        cards = container.rexArray(.cards, as: AssistantCard.self)
        steps = container.rexArray(.steps, as: AssistantStep.self)
        usedLlm = container.rexBool(.usedLlm)
        toolSummary = container.rexString(.toolSummary)
    }
}

struct AssistantHistoryTurn: Encodable, Sendable {
    let role: String
    let content: String
}

struct AssistantChatBody: Encodable {
    let message: String
    let history: [AssistantHistoryTurn]
    let preferSources: [String]
}

// MARK: - 流式事件

struct AssistantStreamPayload: Decodable, Sendable {
    let event: String
    let data: AssistantEventData
}

struct AssistantEventData: Decodable, Sendable {
    let text: String?
    let tool: String?
    let message: String?
    let cards: [AssistantCard]
    let reply: String?
    let steps: [AssistantStep]
    let usedLlm: Bool?
    let toolSummary: String?

    private enum CodingKeys: String, CodingKey {
        case text, tool, message, cards, reply, steps, usedLlm, toolSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.rexString(.text)
        tool = container.rexString(.tool)
        message = container.rexString(.message)
        cards = container.rexArray(.cards, as: AssistantCard.self)
        reply = container.rexString(.reply)
        steps = container.rexArray(.steps, as: AssistantStep.self)
        usedLlm = container.rexBool(.usedLlm)
        toolSummary = container.rexString(.toolSummary)
    }
}

struct AssistantFinal: Sendable {
    let reply: String
    let cards: [AssistantCard]
    let steps: [AssistantStep]
    let usedLlm: Bool
    let toolSummary: String
}

/// 流式事件：状态文案、增量卡片、最终结果、失败。
struct AssistantStreamEvent: Sendable {
    enum Kind: Sendable {
        case status(String)
        case cards([AssistantCard])
        case done(AssistantFinal)
        case failure(String)
    }

    let kind: Kind
}

// MARK: - LLM 设置

struct AiLlmSettings: Decodable, Sendable {
    let enabled: Bool?
    let baseUrl: String?
    let model: String?
    let models: [String]?
    let timeoutSec: Int?
    let configured: Bool?
    let apiKeyHint: String?
    let fromEnv: Bool?

    private enum CodingKeys: String, CodingKey {
        case enabled, baseUrl, model, models, timeoutSec, configured, apiKeyHint, fromEnv
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.rexBool(.enabled)
        baseUrl = container.rexString(.baseUrl)
        model = container.rexString(.model)
        models = container.rexArray(.models, as: String.self)
        timeoutSec = container.rexInt(.timeoutSec)
        configured = container.rexBool(.configured)
        apiKeyHint = container.rexString(.apiKeyHint)
        fromEnv = container.rexBool(.fromEnv)
    }
}

struct AiLlmSaveBody: Encodable {
    let enabled: Bool
    let baseUrl: String
    let model: String
    let apiKey: String?
    let timeoutSec: Int
}

struct AiLlmTestResult: Decodable, Sendable {
    let ok: Bool?
    let message: String?
    let model: String?
}
