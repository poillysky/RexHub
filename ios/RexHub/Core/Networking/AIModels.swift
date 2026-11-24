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
    let chatCompletionSource: String?
    let apiMode: String?
    let baseUrl: String?
    let model: String?
    let models: [String]?
    let promptPostProcessing: String?
    let customIncludeHeaders: String?
    let timeoutSec: Int?
    let configured: Bool?
    let apiKeyHint: String?
    let fromEnv: Bool?
    let fromEnvKey: Bool?

    private enum CodingKeys: String, CodingKey {
        case enabled, chatCompletionSource, apiMode, baseUrl, model, models
        case promptPostProcessing, customIncludeHeaders, timeoutSec
        case configured, apiKeyHint, fromEnv, fromEnvKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.rexBool(.enabled)
        chatCompletionSource = container.rexString(.chatCompletionSource)
        apiMode = container.rexString(.apiMode)
        baseUrl = container.rexString(.baseUrl)
        model = container.rexString(.model)
        models = container.rexArray(.models, as: String.self)
        promptPostProcessing = container.rexString(.promptPostProcessing)
        customIncludeHeaders = container.rexString(.customIncludeHeaders)
        timeoutSec = container.rexInt(.timeoutSec)
        configured = container.rexBool(.configured)
        apiKeyHint = container.rexString(.apiKeyHint)
        fromEnv = container.rexBool(.fromEnv)
        fromEnvKey = container.rexBool(.fromEnvKey)
    }
}

struct AiLlmSaveBody: Encodable {
    let enabled: Bool
    let chatCompletionSource: String
    let apiMode: String
    let baseUrl: String
    let model: String
    let apiKey: String?
    let promptPostProcessing: String
    let customIncludeHeaders: String
    let timeoutSec: Int
}

struct AiLlmTestResult: Decodable, Sendable {
    let ok: Bool?
    let message: String?
    let model: String?
}

struct AiLlmConnectBody: Encodable {
    let baseUrl: String
    let apiKey: String?
    let customIncludeHeaders: String?
    let listModels: Bool = true
}

struct AiLlmConnectResult: Decodable, Sendable {
    let ok: Bool?
    let models: [String]
    let modelCount: Int?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case ok, models, modelCount, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.rexBool(.ok)
        models = container.rexArray(.models, as: String.self)
        modelCount = container.rexInt(.modelCount)
        message = container.rexString(.message)
    }
}

// MARK: - AI 预设

struct AiPresetOption: Decodable, Hashable, Identifiable, Sendable {
    let value: String
    let label: String
    let baseUrl: String?
    let dim: String?

    var id: String { value }

    init(value: String, label: String, baseUrl: String? = nil, dim: String? = nil) {
        self.value = value
        self.label = label
        self.baseUrl = baseUrl
        self.dim = dim
    }

    private enum CodingKeys: String, CodingKey {
        case value, label, baseUrl, dim
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = container.rexString(.value) ?? ""
        label = container.rexString(.label) ?? value
        baseUrl = container.rexString(.baseUrl)
        dim = container.rexString(.dim)
    }
}

struct AiPresets: Decodable, Sendable {
    let chatSources: [AiPresetOption]
    let promptPostProcessing: [AiPresetOption]
    let webSearchProviders: [AiPresetOption]

    private enum CodingKeys: String, CodingKey {
        case chatSources, promptPostProcessing, webSearchProviders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatSources = container.rexArray(.chatSources, as: AiPresetOption.self)
        promptPostProcessing = container.rexArray(.promptPostProcessing, as: AiPresetOption.self)
        webSearchProviders = container.rexArray(.webSearchProviders, as: AiPresetOption.self)
    }
}

// MARK: - 网络搜索服务

struct AiWebSearchSettings: Decodable, Sendable {
    let enabled: Bool?
    let provider: String?
    let baseUrl: String?
    let configured: Bool?
    let fromEnv: Bool?
    let apiKeyHint: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, baseUrl, configured, fromEnv, apiKeyHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.rexBool(.enabled)
        provider = container.rexString(.provider)
        baseUrl = container.rexString(.baseUrl)
        configured = container.rexBool(.configured)
        fromEnv = container.rexBool(.fromEnv)
        apiKeyHint = container.rexString(.apiKeyHint)
    }
}

struct AiWebSearchSaveBody: Encodable {
    let enabled: Bool
    let provider: String
    let apiKey: String?
    let baseUrl: String
}

// MARK: - 助手 Agent 设置

struct AiAssistantToolMeta: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let group: String
    let label: String
    let desc: String

    private enum CodingKeys: String, CodingKey {
        case id, group, label, desc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        group = container.rexString(.group) ?? ""
        label = container.rexString(.label) ?? id
        desc = container.rexString(.desc) ?? ""
    }
}

struct AiAssistantSkillGroup: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let desc: String

    private enum CodingKeys: String, CodingKey {
        case id, label, desc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.rexString(.id) ?? ""
        label = container.rexString(.label) ?? id
        desc = container.rexString(.desc) ?? ""
    }
}

struct AiAssistantSettings: Decodable, Sendable {
    let model: String?
    let systemPrompt: String?
    let suggestChips: [String]
    let tools: [String: Bool]
    let toolMeta: [AiAssistantToolMeta]
    let skillGroups: [AiAssistantSkillGroup]

    private enum CodingKeys: String, CodingKey {
        case model, systemPrompt, suggestChips, tools, toolMeta, skillGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.rexString(.model)
        systemPrompt = container.rexString(.systemPrompt)
        suggestChips = container.rexArray(.suggestChips, as: String.self)
        tools = (try? container.decodeIfPresent([String: Bool].self, forKey: .tools)) ?? [:]
        toolMeta = container.rexArray(.toolMeta, as: AiAssistantToolMeta.self)
        skillGroups = container.rexArray(.skillGroups, as: AiAssistantSkillGroup.self)
    }
}

struct AiAssistantSaveBody: Encodable {
    let model: String
    let systemPrompt: String
    let tools: [String: Bool]
}
