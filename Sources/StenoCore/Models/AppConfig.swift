import Foundation

public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String

    public init(id: String, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

public struct VideoQualityPreset: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int

    public init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    public var resolutionDescription: String {
        "\(width)x\(height)"
    }

    public var bitrateMbps: Double {
        Double(bitrate) / 1_000_000
    }

    public var bitrateDescription: String {
        if bitrate % 1_000_000 == 0 {
            return "\(bitrate / 1_000_000) Mbps"
        }
        return String(format: "%.1f Mbps", bitrateMbps)
    }

    public func estimatedMegabytes(durationSeconds: Int) -> Double {
        Double(bitrate) / 8 * Double(durationSeconds) / 1_000_000
    }
}

public struct AppConfig: Codable, Hashable, Sendable {
    public var aiProviderID: String
    public var apiKey: String
    public var baseURL: String
    public var openRouterAPIKey: String
    public var openRouterBaseURL: String
    public var kimiAPIKey: String
    public var kimiBaseURL: String
    public var qwenAPIKey: String
    public var qwenBaseURL: String
    public var awsAccessKeyID: String
    public var awsSecretAccessKey: String
    public var awsSessionToken: String
    public var awsRegion: String
    public var videoDeviceIndex: String
    public var videoDeviceName: String
    public var modelName: String
    public var saveDirectory: String
    public var videoQuality: String
    public var showRecordingTime: Bool
    public var volumeMain: Double
    public var volumeMic: Double
    public var muteMain: Bool
    public var muteMic: Bool
    public var usedTokens: Int
    public var lastRequestTokens: Int
    public var systemVolume: Double
    public var microphoneVolume: Double
    public var echoCancellationEnabled: Bool
    public var noiseReductionEnabled: Bool
    public var localTranscriptionEnabled: Bool
    public var attachTranscriptToAI: Bool
    public var localTranscriptionModel: String
    public var localTranscriptionLanguage: String
    public var localTranscriptionThreadCount: Int
    public var localTranscriptionUseGPU: Bool
    public var activeAgentID: String
    public var agents: [Agent]

    enum CodingKeys: String, CodingKey {
        case aiProviderID = "ai_provider_id"
        case apiKey = "api_key"
        case baseURL = "base_url"
        case openRouterAPIKey = "openrouter_api_key"
        case openRouterBaseURL = "openrouter_base_url"
        case kimiAPIKey = "kimi_api_key"
        case kimiBaseURL = "kimi_base_url"
        case qwenAPIKey = "qwen_api_key"
        case qwenBaseURL = "qwen_base_url"
        case awsAccessKeyID = "aws_access_key_id"
        case awsSecretAccessKey = "aws_secret_access_key"
        case awsSessionToken = "aws_session_token"
        case awsRegion = "aws_region"
        case videoDeviceIndex = "video_device_idx"
        case videoDeviceName = "video_device_name"
        case modelName = "model_name"
        case saveDirectory = "save_dir"
        case videoQuality = "video_quality"
        case showRecordingTime = "show_recording_time"
        case volumeMain = "volume_main"
        case volumeMic = "volume_mic"
        case muteMain = "mute_main"
        case muteMic = "mute_mic"
        case usedTokens = "used_tokens"
        case lastRequestTokens = "last_request_tokens"
        case systemVolume = "sys_volume"
        case microphoneVolume = "mic_volume"
        case echoCancellationEnabled = "echo_cancellation_enabled"
        case noiseReductionEnabled = "noise_reduction_enabled"
        case localTranscriptionEnabled = "local_transcription_enabled"
        case attachTranscriptToAI = "attach_transcript_to_ai"
        case localTranscriptionModel = "local_transcription_model"
        case localTranscriptionLanguage = "local_transcription_language"
        case localTranscriptionThreadCount = "local_transcription_thread_count"
        case localTranscriptionUseGPU = "local_transcription_use_gpu"
        case activeAgentID = "active_agent_id"
        case agents
    }

    public init(
        aiProviderID: String,
        apiKey: String,
        baseURL: String,
        openRouterAPIKey: String,
        openRouterBaseURL: String,
        kimiAPIKey: String,
        kimiBaseURL: String,
        qwenAPIKey: String,
        qwenBaseURL: String,
        awsAccessKeyID: String,
        awsSecretAccessKey: String,
        awsSessionToken: String,
        awsRegion: String,
        videoDeviceIndex: String,
        videoDeviceName: String,
        modelName: String,
        saveDirectory: String,
        videoQuality: String,
        showRecordingTime: Bool,
        volumeMain: Double,
        volumeMic: Double,
        muteMain: Bool,
        muteMic: Bool,
        usedTokens: Int,
        lastRequestTokens: Int,
        systemVolume: Double,
        microphoneVolume: Double,
        echoCancellationEnabled: Bool,
        noiseReductionEnabled: Bool,
        localTranscriptionEnabled: Bool,
        attachTranscriptToAI: Bool,
        localTranscriptionModel: String,
        localTranscriptionLanguage: String,
        localTranscriptionThreadCount: Int,
        localTranscriptionUseGPU: Bool,
        activeAgentID: String,
        agents: [Agent]
    ) {
        self.aiProviderID = aiProviderID
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.openRouterAPIKey = openRouterAPIKey
        self.openRouterBaseURL = openRouterBaseURL
        self.kimiAPIKey = kimiAPIKey
        self.kimiBaseURL = kimiBaseURL
        self.qwenAPIKey = qwenAPIKey
        self.qwenBaseURL = qwenBaseURL
        self.awsAccessKeyID = awsAccessKeyID
        self.awsSecretAccessKey = awsSecretAccessKey
        self.awsSessionToken = awsSessionToken
        self.awsRegion = awsRegion
        self.videoDeviceIndex = videoDeviceIndex
        self.videoDeviceName = videoDeviceName
        self.modelName = modelName
        self.saveDirectory = saveDirectory
        self.videoQuality = videoQuality
        self.showRecordingTime = showRecordingTime
        self.volumeMain = volumeMain
        self.volumeMic = volumeMic
        self.muteMain = muteMain
        self.muteMic = muteMic
        self.usedTokens = usedTokens
        self.lastRequestTokens = lastRequestTokens
        self.systemVolume = systemVolume
        self.microphoneVolume = microphoneVolume
        self.echoCancellationEnabled = echoCancellationEnabled
        self.noiseReductionEnabled = noiseReductionEnabled
        self.localTranscriptionEnabled = localTranscriptionEnabled
        self.attachTranscriptToAI = attachTranscriptToAI
        self.localTranscriptionModel = localTranscriptionModel
        self.localTranscriptionLanguage = localTranscriptionLanguage
        self.localTranscriptionThreadCount = localTranscriptionThreadCount
        self.localTranscriptionUseGPU = localTranscriptionUseGPU
        self.activeAgentID = activeAgentID
        self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aiProviderID = try container.decodeIfPresent(String.self, forKey: .aiProviderID) ?? defaults.aiProviderID
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        openRouterAPIKey = try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? defaults.openRouterAPIKey
        openRouterBaseURL = try container.decodeIfPresent(String.self, forKey: .openRouterBaseURL) ?? defaults.openRouterBaseURL
        kimiAPIKey = try container.decodeIfPresent(String.self, forKey: .kimiAPIKey) ?? defaults.kimiAPIKey
        kimiBaseURL = try container.decodeIfPresent(String.self, forKey: .kimiBaseURL) ?? defaults.kimiBaseURL
        qwenAPIKey = try container.decodeIfPresent(String.self, forKey: .qwenAPIKey) ?? defaults.qwenAPIKey
        qwenBaseURL = try container.decodeIfPresent(String.self, forKey: .qwenBaseURL) ?? defaults.qwenBaseURL
        awsAccessKeyID = try container.decodeIfPresent(String.self, forKey: .awsAccessKeyID) ?? defaults.awsAccessKeyID
        awsSecretAccessKey = try container.decodeIfPresent(String.self, forKey: .awsSecretAccessKey) ?? defaults.awsSecretAccessKey
        awsSessionToken = try container.decodeIfPresent(String.self, forKey: .awsSessionToken) ?? defaults.awsSessionToken
        awsRegion = try container.decodeIfPresent(String.self, forKey: .awsRegion) ?? defaults.awsRegion
        videoDeviceIndex = try container.decodeIfPresent(String.self, forKey: .videoDeviceIndex) ?? defaults.videoDeviceIndex
        videoDeviceName = try container.decodeIfPresent(String.self, forKey: .videoDeviceName) ?? defaults.videoDeviceName
        modelName = AIModelCatalog.normalizedModelID(try container.decodeIfPresent(String.self, forKey: .modelName) ?? defaults.modelName)
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? defaults.saveDirectory
        videoQuality = try container.decodeIfPresent(String.self, forKey: .videoQuality) ?? defaults.videoQuality
        showRecordingTime = try container.decodeIfPresent(Bool.self, forKey: .showRecordingTime) ?? defaults.showRecordingTime
        volumeMain = try container.decodeIfPresent(Double.self, forKey: .volumeMain) ?? defaults.volumeMain
        volumeMic = try container.decodeIfPresent(Double.self, forKey: .volumeMic) ?? defaults.volumeMic
        muteMain = try container.decodeIfPresent(Bool.self, forKey: .muteMain) ?? defaults.muteMain
        muteMic = try container.decodeIfPresent(Bool.self, forKey: .muteMic) ?? defaults.muteMic
        usedTokens = try container.decodeIfPresent(Int.self, forKey: .usedTokens) ?? defaults.usedTokens
        lastRequestTokens = try container.decodeIfPresent(Int.self, forKey: .lastRequestTokens) ?? defaults.lastRequestTokens
        systemVolume = try container.decodeIfPresent(Double.self, forKey: .systemVolume) ?? defaults.systemVolume
        microphoneVolume = try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? defaults.microphoneVolume
        echoCancellationEnabled = try container.decodeIfPresent(Bool.self, forKey: .echoCancellationEnabled) ?? defaults.echoCancellationEnabled
        noiseReductionEnabled = try container.decodeIfPresent(Bool.self, forKey: .noiseReductionEnabled) ?? defaults.noiseReductionEnabled
        localTranscriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .localTranscriptionEnabled) ?? defaults.localTranscriptionEnabled
        attachTranscriptToAI = try container.decodeIfPresent(Bool.self, forKey: .attachTranscriptToAI) ?? defaults.attachTranscriptToAI
        localTranscriptionModel = try container.decodeIfPresent(String.self, forKey: .localTranscriptionModel) ?? defaults.localTranscriptionModel
        localTranscriptionLanguage = try container.decodeIfPresent(String.self, forKey: .localTranscriptionLanguage) ?? defaults.localTranscriptionLanguage
        localTranscriptionThreadCount = try container.decodeIfPresent(Int.self, forKey: .localTranscriptionThreadCount) ?? defaults.localTranscriptionThreadCount
        localTranscriptionUseGPU = try container.decodeIfPresent(Bool.self, forKey: .localTranscriptionUseGPU) ?? defaults.localTranscriptionUseGPU
        activeAgentID = try container.decodeIfPresent(String.self, forKey: .activeAgentID) ?? defaults.activeAgentID
        agents = try container.decodeIfPresent([Agent].self, forKey: .agents) ?? defaults.agents
    }
}

public extension AppConfig {
    static var aiModels: [String] {
        AIModelCatalog.providerModels(.gemini).map(\.modelID)
    }

    static let qualityPresets: [String: VideoQualityPreset] = [
        "Low": VideoQualityPreset(width: 960, height: 540, fps: 1, bitrate: 1_000_000),
        "Medium": VideoQualityPreset(width: 1280, height: 720, fps: 5, bitrate: 3_000_000),
        "High": VideoQualityPreset(width: 1920, height: 1080, fps: 15, bitrate: 8_000_000),
        "Ultra": VideoQualityPreset(width: 2560, height: 1440, fps: 30, bitrate: 25_000_000)
    ]

    static let qualityPresetOrder = ["Low", "Medium", "High", "Ultra"]

    static let defaultAgents: [Agent] = [
        Agent(
            id: "default",
            name: "Стандартный протокол",
            prompt: """
            Ты — ИИ-ассистент для составления протоколов встреч. Твоя задача — проанализировать предоставленный медиафайл и вернуть ТОЛЬКО протокол в формате Markdown (оптимизированный для Confluence), строго без вступительных слов, приветствий и пояснений самой нейросети.

            Используй следующий шаблон:
            # Протокол встречи: [Сформулируй тему]
            **Дата:** [Дата из запроса]
            **Участники:** [Список имен или ролей]

            ## 1. Саммари (Summary)
            [Краткое, структурированное содержание обсуждения без воды]

            ## 2. Принятые решения
            * [Список конкретных решений]

            ## 3. План действий (Action Items)
            Оформи строго как таблицу:
            | Задача | Ответственный | Срок |
            | :--- | :--- | :--- |
            | [Описание задачи] | [Имя] | [Дедлайн или -] |
            """
        ),
        Agent(
            id: "summary",
            name: "Краткая выжимка",
            prompt: """
            Ты — экспертный ИИ-аналитик, специализирующийся на выделении ключевых смыслов из бизнес-коммуникаций. Твоя единственная задача — превратить хаотичный лог встречи в предельно лаконичную выжимку (Executive Summary), содержащую только самую суть.

            ТВОЕ ЗАДАНИЕ:
            Проанализируй текст встречи и отсеки 90% второстепенной информации, оставив только критически важные инсайты, цели и итоги.

            ПРАВИЛА КОНТЕНТА И ФОРМАТИРОВАНИЯ:
            1. Пиши максимально кратко, в стиле «для генерального директора, у которого есть всего 30 секунд».
            2. Используй только формат Markdown.
            3. СТРОГО ЗАПРЕЩЕНЫ: приветствия, вводные фразы («Я проанализировал...», «Вот краткая выжимка...»), вежливые отступления и любые пояснения от нейросети.
            4. Выдавай результат сразу по следующему шаблону:

            # Главное (The Core)
            **Суть встречи в 1 предложении:** [Сформулируй максимально емко]

            ## Ключевые тезисы
            * [Тезис 1: Самая важная мысль]
            * [Тезис 2: Главный инсайт или проблема]
            * [Тезис 3: Критическое изменение в планах]

            ## Главный итог (Outcome)
            [Опиши финальное состояние вопроса: о чем договорились в сухом остатке]

            ## Что дальше (Next Steps)
            * [Действие] — [Ответственный]

            Если на встрече не было принято решений или не назначены ответственные, так и напиши: «Решения не зафиксированы». Не выдумывай факты, которых нет в исходном тексте.
            """
        ),
        Agent(
            id: "stenograph",
            name: "Steno-графист",
            prompt: """
            Ты — опытный ИИ-стенографист и секретарь-референт, специализирующийся на расшифровке онлайн-встреч. Твоя единственная цель — сотворить максимально точную, дословную и структурированную стенограмму (транскрипт) предоставленного созвона.

            ТВОЕ ЗАДАНИЕ:
            Внимательно проанализируй аудиозапись или черновой транскрипт и преобразуй его в читаемый, четкий формат диалога без искажения смысла.

            ПРАВИЛА ФОРМАТИРОВАНИЯ И ПОВЕДЕНИЯ:
            1. Выводи текст строго в формате диалога:
               [Имя спикера или "Спикер 1", "Спикер 2"]: [Точная реплика].
            2. Слушай внимательно: если участники встречи обращаются друг к другу по именам или представляют себя, используй эти имена вместо безликого "Спикер N".
            3. Разделяй реплики разных людей абзацами для удобства чтения.
            4. Сохраняй исходный смысл и полноту 100% информации. Сохраняй технические термины, англицизмы и метрики. Не выдумывай ничего от себя и не делай кратких выжимок.
            5. Слегка очисти речь от явного "мусора": запинок и слов-паразитов ("э-э-э", "ну как бы"), если это не меняет тональность.
            6. Расставь правильные знаки препинания для удобства чтения.

            Начни свой ответ СРАЗУ со стенограммы. Не пиши никаких вступительных фраз или приветствий. Выдавай только структурированный диалог.
            """
        )
    ]

    static let `default` = AppConfig(
        aiProviderID: AIProviderID.gemini.rawValue,
        apiKey: "",
        baseURL: "https://gemini-warmup.galaypro.ru",
        openRouterAPIKey: "",
        openRouterBaseURL: "https://openrouter.ai/api/v1",
        kimiAPIKey: "",
        kimiBaseURL: "https://api.moonshot.ai/v1",
        qwenAPIKey: "",
        qwenBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        awsAccessKeyID: "",
        awsSecretAccessKey: "",
        awsSessionToken: "",
        awsRegion: "us-east-1",
        videoDeviceIndex: "0",
        videoDeviceName: "Main Screen",
        modelName: "gemini-3-flash-preview",
        saveDirectory: UserPaths.defaultSaveDirectory.path,
        videoQuality: "Medium",
        showRecordingTime: true,
        volumeMain: 1.0,
        volumeMic: 1.0,
        muteMain: false,
        muteMic: false,
        usedTokens: 0,
        lastRequestTokens: 0,
        systemVolume: 1.0,
        microphoneVolume: 1.0,
        echoCancellationEnabled: true,
        noiseReductionEnabled: false,
        localTranscriptionEnabled: true,
        attachTranscriptToAI: true,
        localTranscriptionModel: "ggml-tiny-q5_1",
        localTranscriptionLanguage: "auto",
        localTranscriptionThreadCount: 2,
        localTranscriptionUseGPU: false,
        activeAgentID: "default",
        agents: defaultAgents
    )

    var activeAgent: Agent? {
        agents.first { $0.id == activeAgentID }
    }

    func agent(id: String) -> Agent? {
        agents.first { $0.id == id }
    }

    func preset() -> VideoQualityPreset {
        Self.qualityPresets[videoQuality] ?? Self.qualityPresets["Medium"]!
    }
}

public extension AppConfig {
    var aiProvider: AIProviderID {
        get {
            AIProviderID(rawValue: aiProviderID) ?? .gemini
        }
        set {
            aiProviderID = newValue.rawValue
        }
    }

    var selectedModelReference: AIModelReference? {
        AIModelCatalog.model(providerID: aiProvider, modelID: modelName)
    }

    var selectedModelDisplayName: String {
        selectedModelReference?.displayName ?? modelName
    }

    func apiKey(for providerID: AIProviderID) -> String {
        switch providerID {
        case .gemini:
            apiKey
        case .kimi:
            kimiAPIKey
        case .amazonBedrock:
            awsAccessKeyID.isEmpty || awsSecretAccessKey.isEmpty ? "" : "\(awsAccessKeyID):\(awsSecretAccessKey)"
        case .qwen:
            qwenAPIKey
        case .openRouter:
            openRouterAPIKey
        }
    }

    func baseURL(for providerID: AIProviderID) -> String {
        switch providerID {
        case .gemini:
            baseURL
        case .kimi:
            kimiBaseURL
        case .amazonBedrock:
            "https://bedrock-runtime.\(awsRegion).amazonaws.com"
        case .qwen:
            qwenBaseURL
        case .openRouter:
            openRouterBaseURL
        }
    }
}
