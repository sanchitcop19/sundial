import SwiftUI
import SundialCore

/// First-run setup. Everything here is detected from the machine, so the
/// questions are about this person's actual browsers, folders and apps rather
/// than a generic checklist.
struct OnboardingView: View {
    @EnvironmentObject var engine: Engine
    var onFinish: () -> Void

    @State private var env = Environment()
    @State private var domains = ""
    @State private var workIdentities: Set<String> = []
    @State private var rootChoice: [String: Outcome] = [:]
    @State private var appChoice: [String: Outcome] = [:]
    @State private var includePersonalSites = true
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    domainsCard
                    if !env.browsers.filter({ !$0.identities.isEmpty }).isEmpty { browsersCard }
                    if !env.codeRoots.isEmpty { codeCard }
                    appsCard
                    Card {
                        Toggle("Treat well-known streaming and social sites as personal",
                               isOn: $includePersonalSites)
                        Text("A short list: Netflix, YouTube, Reddit and similar. Anything else "
                             + "stays unclassified until you say otherwise.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Set up Sundial").font(.system(size: 17, weight: .semibold))
            Text("A few answers now means less correcting later. Nothing here is final — "
                 + "every rule can be changed, and changing one also re-decides the past.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var domainsCard: some View {
        Card(title: "Where do you work?") {
            VStack(alignment: .leading, spacing: 5) {
                TextField("acme.com, acme.atlassian.net", text: $domains)
                    .textFieldStyle(.roundedBorder)
                Text("Your company's web domains, separated by commas. Anything on them counts "
                     + "as work, including subdomains.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var browsersCard: some View {
        Card(title: "Browser profiles") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tick the profiles and containers you use for work. This is usually the "
                     + "single most accurate signal there is.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(env.browsers.filter { !$0.identities.isEmpty }) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.name).font(.system(size: 11, weight: .semibold))
                        ForEach(b.identities, id: \.self) { ident in
                            let key = "\(b.bundleId)|\(ident)"
                            Toggle(ident, isOn: Binding(
                                get: { workIdentities.contains(key) },
                                set: { on in
                                    if on { workIdentities.insert(key) } else { workIdentities.remove(key) }
                                }))
                                .font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    private var codeCard: some View {
        Card(title: "Code folders") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(env.codeRoots) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(root.display).font(.system(size: 11, design: .monospaced))
                            Text("\(root.repoCount) repositories")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { rootChoice[root.path].map { $0 == .work ? 1 : 2 } ?? 0 },
                            set: { v in
                                rootChoice[root.path] = v == 1 ? .work : (v == 2 ? .personal : nil)
                            })) {
                            Text("Skip").tag(0)
                            Text("Work").tag(1)
                            Text("Personal").tag(2)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                }
            }
        }
    }

    private var appsCard: some View {
        Card(title: "Apps") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Only the ones with an obvious answer are pre-filled. Leave anything you are "
                     + "unsure about on Skip — it will show up in Review the first time you use it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(env.apps.filter { $0.suggested != nil }) { app in
                    HStack {
                        Text(app.name).font(.system(size: 11))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appChoice[app.bundleId].map { $0 == .work ? 1 : 2 } ?? 0 },
                            set: { v in
                                appChoice[app.bundleId] = v == 1 ? .work : (v == 2 ? .personal : nil)
                            })) {
                            Text("Skip").tag(0)
                            Text("Work").tag(1)
                            Text("Personal").tag(2)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(ruleCount) rules will be created")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Skip for now") { engine.completeSetup(with: RuleSet()); onFinish() }
            Button("Start tracking") { finish() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .padding(14)
    }

    private var ruleCount: Int { StarterRules.build(choices).rules.count }

    private var choices: SetupChoices {
        var c = SetupChoices()
        c.workDomains = domains.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        c.workBrowserIdentities = workIdentities.map { $0.components(separatedBy: "|") }
        c.workCodeRoots = rootChoice.filter { $0.value == .work }.map(\.key)
        c.personalCodeRoots = rootChoice.filter { $0.value == .personal }.map(\.key)
        c.workApps = appChoice.filter { $0.value == .work }.map(\.key)
        c.personalApps = appChoice.filter { $0.value == .personal }.map(\.key)
        c.includePersonalSites = includePersonalSites
        return c
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        env = engine.detectEnvironment()
        for app in env.apps { if let s = app.suggested { appChoice[app.bundleId] = s } }
        // A folder literally called "work" is a safe default; the rest are not.
        for root in env.codeRoots where (root.path as NSString).lastPathComponent
            .localizedCaseInsensitiveContains("work") {
            rootChoice[root.path] = .work
        }
    }

    private func finish() {
        engine.completeSetup(with: StarterRules.build(choices))
        onFinish()
    }
}
