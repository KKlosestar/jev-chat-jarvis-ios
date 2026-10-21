import Foundation

// MARK: - 判断层：TypeSafe Jev / System One 客户端
//
// Jev 是结构化决策模型：给它一个 state 加一组带类型的题目，返回校准过的概率而不是文字。
// 与 macOS 版 src/judge_jev.py 同一请求形状：
//   POST {base}/v1/systemone   Authorization: Bearer <key>
//   {"model": …, "state": …, "questions": {intent: choice, risk: score}}
// 排序只是又一道 choice 题：把候选文本当选项，哪条最合适。

struct JudgeResult: Equatable {
    var intent: String
    var confidence: Double
    var intentProbs: [String: Double]
    var risk: Double
    var riskProbs: [String: Double]
    var actions: [String]

    var riskLevelText: String { riskLabel(for: risk) }
}

struct RankedCandidate: Equatable {
    var text: String
    var prob: Double
}

/// 判断结果的内存缓存。实测判断一次要一秒多，而「换一批」是对同一条消息反复分析——
/// 判断结论不会变，没必要每次重付一次往返。只在进程内、不落盘；换了消息自然失效。
final class JevJudgeCache {
    static let shared = JevJudgeCache()

    private struct Key: Hashable {
        let message: String
        let context: String
    }

    private var store: [Key: (result: JudgeResult, at: Date)] = [:]
    private let ttl: TimeInterval = 300
    private let lock = NSLock()

    func get(message: String, context: String?) -> JudgeResult? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(message: message, context: context ?? "")
        guard let hit = store[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.result
    }

    func put(_ result: JudgeResult, message: String, context: String?) {
        lock.lock()
        defer { lock.unlock() }
        if store.count > 8 { store.removeAll() }
        store[Key(message: message, context: context ?? "")] = (result, Date())
    }
}

final class JevJudge {
    private let base: String
    private let key: String
    private let model: String

    init(cfg: JevConfig) {
        self.base = cfg.judgeBase.trimmingCharacters(in: .whitespaces)
        self.key = cfg.judgeKey.trimmingCharacters(in: .whitespaces)
        self.model = cfg.judgeModel.trimmingCharacters(in: .whitespaces)
    }

    /// OpenRouter 的 /api/alpha/decisions 决策端点与 jev-1.13 模型已下架（CN 区账号还会 403）。
    /// 对 openrouter.ai 一律改走普通 chat completions + typesafe/jev-router，
    /// 用 JSON 输出模拟 SystemOne 的 answers 形状，上层解析逻辑不变。
    private var useChatMode: Bool { base.lowercased().contains("openrouter.ai") }

    /// 旧配置里的退役模型名统一映射到快速非思考模型：jev-router 会随机路由到思考型
    /// 模型（一次判断动辄十几秒还常超时转盲起草）；意图/风险分类用 flash 级足够，
    /// 实测约 650 tokens、单次成本忽略不计。
    private var chatModel: String {
        let m = model.lowercased()
        if m.contains("jev") { return "deepseek/deepseek-v4-flash" }
        return model
    }

    var isConfigured: Bool { !key.isEmpty && !base.isEmpty && !model.isEmpty }

    // MARK: URL 拼接（与 macOS 版 #42 单一规则一致）
    //
    // 三种填法等价可用：只到主机（…/v1/systemone 自动补）、带版本段（…/v1 只补动作段）、
    // 完整动作路径（原样使用）。网关可以改名动作段（Vercel 是 /v1/evaluate、
    // OpenRouter 是 /api/alpha/decisions）。

    static func requestURL(_ rawBase: String) -> String {
        let b = rawBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let segs = b.split(separator: "/").map(String.init)
        guard let last = segs.last?.lowercased() else { return b }
        let actionSegs: Set<String> = ["systemone", "evaluate", "decisions"]
        if actionSegs.contains(last) { return b }
        if last.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return b + "/systemone" }
        return b + "/v1/systemone"
    }

    // MARK: 判断（意图 + 风险，一次调用出全分布）

    func judge(message: String, context: String?) async throws -> JudgeResult {
        let state = context != nil && !context!.isEmpty ? "\(context!)\n\n\(message)" : message
        let payload: [String: Any] = [
            "model": model,
            "state": state,
            "questions": [
                "intent": [
                    "type": "choice",
                    "instructions": "这句话的真实意图是什么？",
                    "criteria": INTENTS,
                ] as [String: Any],
                "risk": [
                    "type": "score",
                    "instructions": "如果直接回复这句话，风险有多大？",
                    "criteria": RISK_LEVELS,
                ] as [String: Any],
            ],
        ]
        let data = try await post(payload, stage: "判断")
        let answers = data["answers"] as? [String: Any] ?? [:]
        let intentAns = answers["intent"] as? [String: Any] ?? [:]
        let riskAns = answers["risk"] as? [String: Any] ?? [:]

        var intent = intentAns["choice"] as? String ?? "闲聊"
        if !INTENTS.keys.contains(intent) {
            // 网关偶尔回显下标或近似标签
            intent = INTENTS.keys.first { intent.contains($0) } ?? "闲聊"
        }
        let confidence = doubleValue(intentAns["confidence"])
        let risk = doubleValue(riskAns["score"])
        return JudgeResult(
            intent: intent,
            confidence: confidence,
            intentProbs: doubleDict(intentAns["probabilities"]),
            risk: risk,
            riskProbs: doubleDict(riskAns["probabilities"]),
            actions: ACTION_MAP[intent] ?? []
        )
    }

    // MARK: 排序（候选文本当 choice 选项）

    func rank(message: String, intent: String, candidates: [String]) async throws -> [RankedCandidate] {
        guard !candidates.isEmpty else { return [] }
        // 去重后再当选项：两个槽位选了同一个话术时，模型很可能给出两条一模一样的候选，
        // 而字典键不能重复（用 uniqueKeysWithValues 会直接 trap 崩掉键盘）。
        let criteria = Dictionary(candidates.map { ($0, NSNull()) }, uniquingKeysWith: { first, _ in first })
        let payload: [String: Any] = [
            "model": model,
            "state": "收到的消息：\(message)\n判断出的意图：\(intent)",
            "questions": [
                "best": [
                    "type": "choice",
                    "instructions": "哪一条回复最合适？",
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]
        let data = try await post(payload, stage: "排序")
        let ans = (data["answers"] as? [String: Any])?["best"] as? [String: Any] ?? [:]
        let probs = doubleDict(ans["probabilities"])
        var ranked = candidates.map { c -> RankedCandidate in
            var p = probs[c] ?? 0
            if p == 0, let choice = ans["choice"] as? String, choice == c {
                p = doubleValue(ans["confidence"])   // 网关可能只回显选中项
            }
            return RankedCandidate(text: c, prob: p)
        }
        ranked.sort { $0.prob > $1.prob }
        return ranked
    }

    // MARK: transport

    private func post(_ payload: [String: Any], stage: String) async throws -> [String: Any] {
        if useChatMode { return try await postViaChat(payload, stage: stage) }
        return try await JevHTTP.postJSON(
            payload,
            url: Self.requestURL(base),
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            budget: stage == "判断" ? 15 : 12,
            stage: stage
        )
    }

    // MARK: chat 模式（OpenRouter）

    /// 把 SystemOne 形状的题目翻译成一条 chat 请求，要求模型输出 JSON，
    /// 再拼回 answers 字典（choice/score + probabilities），与决策端点同形状。
    private func postViaChat(_ payload: [String: Any], stage: String) async throws -> [String: Any] {
        guard let questions = payload["questions"] as? [String: Any] else {
            throw JevError.config("判断题目缺失")
        }
        let state = payload["state"] as? String ?? ""

        var qLines: [String] = []
        var schemaParts: [String] = []
        for (name, raw) in questions {
            guard let q = raw as? [String: Any] else { continue }
            let instr = q["instructions"] as? String ?? ""
            qLines.append("问题「\(name)」：\(instr)")
            if let criteria = q["criteria"] as? [String: Any] {
                qLines.append("  选项（choice 只能从中选一个，用原文）：\(criteria.keys.joined(separator: "、"))")
                schemaParts.append("\"\(name)\": {\"choice\": \"选项原文\", \"confidence\": 0到1的小数, \"probabilities\": {每个选项原文: 概率}}")
            } else if let levels = q["criteria"] as? [String] {
                qLines.append("  等级（从低到高）：\(levels.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: "；"))")
                schemaParts.append("\"\(name)\": {\"score\": 等级编号, \"probabilities\": {每个等级原文: 概率}}")
            }
        }
        let system = "你是沟通意图与风险判断器。只输出一个 JSON 对象，不输出解释、markdown 或其他文字。probabilities 里所有概率之和约等于 1。"
        let user = "待分析消息：\n\(state)\n\n\(qLines.joined(separator: "\n"))\n\n输出 JSON，每个问题一个键，值形如：\(schemaParts.joined(separator: "；"))"

        // 路由模型多为思考型：max_tokens 要够思考+正文，正文空时从 reasoning 里兜底抠 JSON。
        let chat: [String: Any] = [
            "model": chatModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": 600,
        ]
        let data = try await JevHTTP.postJSON(
            chat,
            url: "https://openrouter.ai/api/v1/chat/completions",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            budget: stage == "判断" ? 30 : 25,
            stage: stage
        )
        guard let choices = data["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw JevError.badJSON(stage)
        }
        let content = (msg["content"] as? String) ?? (msg["reasoning"] as? String) ?? ""
        let obj = Self.extractJSON(content)
        guard !obj.isEmpty else { throw JevError.thinkingOnly(stage) }

        var answers: [String: Any] = [:]
        for (name, raw) in questions {
            guard let q = raw as? [String: Any], let ans = obj[name] as? [String: Any] else { continue }
            if q["type"] as? String == "score" {
                answers[name] = ["score": ans["score"] ?? 0, "probabilities": ans["probabilities"] ?? [:]]
            } else {
                answers[name] = [
                    "choice": ans["choice"] ?? "",
                    "confidence": ans["confidence"] ?? 0,
                    "probabilities": ans["probabilities"] ?? [:],
                ]
            }
        }
        return ["answers": answers]
    }

    /// 剥掉 markdown 代码围栏，抠出第一个完整 JSON 对象。
    private static func extractJSON(_ s: String) -> [String: Any] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "` \n\t"))
            if t.lowercased().hasPrefix("json") { t = String(t.dropFirst(4)) }
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else { return [:] }
        let sub = String(t[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any] ?? [:]
    }

    private func doubleValue(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private func doubleDict(_ v: Any?) -> [String: Double] {
        guard let d = v as? [String: Any] else { return [:] }
        return d.mapValues(doubleValue)
    }
}
