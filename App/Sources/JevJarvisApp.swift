import SwiftUI
import UIKit

/// 配置的唯一可写入口：App 侧改完立刻落 App Group，键盘下次分析就能读到。
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: JevConfig {
        didSet { JevStore.saveConfig(config) }
    }
    @Published var language: JevLanguage {
        didSet { JevStore.saveLanguage(language) }
    }

    init() {
        config = JevStore.loadConfig()
        language = JevStore.loadLanguage()
    }

    /// 键盘那边也能改共享配置（话术槽位就能直接在键盘上选），回到前台时把外部改动收进来——
    /// 否则 App 里这份旧值会在下次编辑时把键盘的选择覆盖掉。
    func reloadIfChanged() {
        let fresh = JevStore.loadConfig()
        if fresh != config { config = fresh }
        let freshLanguage = JevStore.loadLanguage()
        if freshLanguage != language { language = freshLanguage }
    }

    var toneCatalog: [String: String] { allTones(custom: config.customTones) }
}

@main
struct JevJarvisApp: App {
    @StateObject private var store = ConfigStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                SetupView()
                    .tabItem { Label(jevLocalized(store.language, zh: "开始", en: "Home"), systemImage: "keyboard") }
                ProvidersView()
                    .tabItem { Label(jevLocalized(store.language, zh: "模型", en: "Models"), systemImage: "brain.head.profile") }
                TonesView()
                    .tabItem { Label(jevLocalized(store.language, zh: "话术", en: "Tones"), systemImage: "theatermasks") }
                ContextView()
                    .tabItem { Label(jevLocalized(store.language, zh: "上下文", en: "Context"), systemImage: "text.bubble") }
                PlaygroundView()
                    .tabItem { Label(jevLocalized(store.language, zh: "试一试", en: "Try it"), systemImage: "flask") }
            }
            .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.reloadIfChanged() }
        }
    }
}

/// 「上下文」页：多档案管理。每个档案 = 备注名 + 关系摘要；键盘分析时可手动切换，
/// 或按聊天对象自动匹配（备注名 = 对方的微信昵称/备注，出现在粘贴文本里就自动切）。
struct ContextView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var profiles: [JevStore.ContextProfile] = []
    @State private var activeID: UUID?
    @State private var editingID: UUID?
    @State private var draftName = ""
    @State private var draftSummary = ""
    @State private var rawInput = ""
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        Form {
            if let idx = editingIndex {
                editorSection(idx)
            } else {
                listSection
            }
        }
        .navigationTitle(jevLocalized(store.language, zh: "上下文", en: "Context"))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(jevLocalized(store.language, zh: "收起键盘", en: "Dismiss")) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private var editingIndex: Int? {
        guard let editingID else { return nil }
        return profiles.firstIndex { $0.id == editingID }
    }

    private func reload() {
        JevStore.migrateLegacyContextSummaryIfNeeded()
        profiles = JevStore.contextProfiles
        activeID = JevStore.activeContextProfileID
    }

    private func persist() {
        JevStore.saveContextProfiles(profiles)
    }

    // MARK: 档案列表

    private var listSection: some View {
        Section {
            ForEach(profiles) { p in
                HStack(spacing: 10) {
                    Image(systemName: activeID == p.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(activeID == p.id ? Color.green : Color.secondary)
                        .onTapGesture {
                            activeID = p.id
                            JevStore.activeContextProfileID = p.id
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.subheadline.weight(.medium))
                        Text(p.summary.prefix(40) + (p.summary.count > 40 ? "…" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(p.updatedAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingID = p.id
                        draftName = p.name
                        draftSummary = p.summary
                        rawInput = ""
                        notice = nil
                    }
                }
            }
            Button {
                var p = JevStore.ContextProfile(name: jevLocalized(store.language, zh: "新档案", en: "New profile"), summary: "", updatedAt: Date())
                profiles.append(p)
                persist()
                editingID = p.id
                draftName = p.name
                draftSummary = ""
                rawInput = ""
                notice = nil
                _ = p
            } label: {
                Label(jevLocalized(store.language, zh: "新建档案", en: "New profile"), systemImage: "plus.circle")
            }
        } header: {
            Text(jevLocalized(store.language, zh: "上下文档案（点名字编辑，点圆圈切换使用）", en: "Profiles (tap name to edit, circle to activate)"))
        } footer: {
            Text(jevLocalized(store.language, zh: "把备注名写成对方的微信昵称/备注：粘贴该对象的聊天记录分析时自动匹配。一次只用一个档案。", en: "Name profiles after contacts to auto-match on paste. One profile is used at a time."))
        }
    }

    // MARK: 档案编辑

    private func editorSection(_ idx: Int) -> some View {
        Section {
            TextField(jevLocalized(store.language, zh: "备注名（如：小美、老板）", en: "Profile name (e.g. Mei, Boss)"), text: $draftName)
                .onChange(of: draftName) { _ in saveEdits(idx) }
            TextEditor(text: $draftSummary)
                .frame(minHeight: 110)
                .font(.callout)
                .autocorrectionDisabled()
                .onChange(of: draftSummary) { _ in saveEdits(idx) }
            if busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(jevLocalized(store.language, zh: "压缩中…", en: "Summarizing…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                summarize(idx, merge: false)
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text(jevLocalized(store.language, zh: "从聊天记录重新生成摘要", en: "Regenerate summary"))
                }
            }
            .disabled(busy || rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                summarize(idx, merge: true)
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.merge")
                    Text(jevLocalized(store.language, zh: "用新记录合并更新（保留旧摘要）", en: "Merge update"))
                }
            }
            .disabled(busy || rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                activeID = editingID
                JevStore.activeContextProfileID = editingID
            } label: {
                HStack {
                    Image(systemName: activeID == editingID ? "checkmark.circle.fill" : "checkmark.circle")
                    Text(activeID == editingID
                         ? jevLocalized(store.language, zh: "当前使用中", en: "Active")
                         : jevLocalized(store.language, zh: "设为当前使用", en: "Set as active"))
                }
            }
            TextEditor(text: $rawInput)
                .frame(minHeight: 80)
                .font(.callout)
                .autocorrectionDisabled()
            Button(role: .destructive) {
                profiles.remove(at: idx)
                persist()
                if activeID == editingID { activeID = nil; JevStore.activeContextProfileID = nil }
                editingID = nil
            } label: {
                Label(jevLocalized(store.language, zh: "删除档案", en: "Delete profile"), systemImage: "trash")
            }
            Button {
                editingID = nil
            } label: {
                Label(jevLocalized(store.language, zh: "返回列表", en: "Back to list"), systemImage: "chevron.left")
            }
        } header: {
            Text(jevLocalized(store.language, zh: "编辑档案（改动即时保存）", en: "Edit profile (saved instantly)"))
        } footer: {
            Text(jevLocalized(store.language, zh: "微信里长按消息 → 多选 → 合并转发 → 复制，粘贴到下面点「生成摘要」。原文只用于本次压缩，不会保存。", en: "Paste chat history (WeChat: select → merge forward → copy) and tap Summarize. Raw text is not stored."))
        }
    }

    private func saveEdits(_ idx: Int) {
        guard profiles.indices.contains(idx) else { return }
        profiles[idx].name = draftName.trimmingCharacters(in: .whitespaces)
        profiles[idx].summary = draftSummary
        profiles[idx].updatedAt = Date()
        persist()
    }

    private func summarize(_ idx: Int, merge: Bool) {
        let raw = String(rawInput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
        guard !raw.isEmpty else { return }
        busy = true
        notice = nil
        let rules = """
        1. 只输出摘要正文：不要标题、不要序号、不要任何解释。
        2. 覆盖：对方是谁/怎么称呼、关系与当前氛围、最近在聊什么、有没有没聊完的话题或约定、雷区和注意点、两人的梗或惯用称呼。
        3. 平实的陈述句，人名和称呼保留原样。不超过 200 字。
        """
        let prompt: String
        if merge {
            let old = profiles.indices.contains(idx) ? profiles[idx].summary : ""
            prompt = """
            下面是一份已有的「关系摘要」和一段更新的聊天记录。请把新记录里的新信息融进摘要，输出更新后的完整摘要（仍不超过 200 字）：仍然有效的内容保留，已经过时的（如已完成的约定）删除或改写。\(rules)

            已有摘要：
            \(old)

            更新的聊天记录：
            \(raw)
            """
        } else {
            prompt = """
            下面是一段聊天记录。请把它压缩成一份「关系摘要」，作为后续针对单条新消息生成回复时的背景信息。要求：
            \(rules)

            聊天记录：
            \(raw)
            """
        }
        let draft = JevDraft(cfg: store.config)
        Task { @MainActor in
            defer { busy = false }
            do {
                let out = try await draft.call(prompt: prompt)
                let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw JevError.emptyReply }
                draftSummary = cleaned
                if profiles.indices.contains(idx) {
                    profiles[idx].summary = cleaned
                    profiles[idx].updatedAt = Date()
                    persist()
                }
                rawInput = ""
                notice = jevLocalized(store.language, zh: "已生成摘要并保存（原文未保留）", en: "Summary saved (raw text discarded)")
            } catch {
                notice = jevLocalized(store.language, zh: "生成失败：", en: "Failed: ") + error.localizedDescription
            }
        }
    }
}
