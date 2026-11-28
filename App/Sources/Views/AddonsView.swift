import SwiftUI

/// Add-ons for one bot: Skills Hub skills, plugins and MCP servers, browsed and installed from the phone that owns
/// the Mac. Nothing installs without a tap, a skill is scanned by Hermes first (a blocking verdict can't be
/// overridden here), a plugin asking for new powers says which, and settings only go where they're declared.
struct AddonsView: View {
    let profile: String
    var botName: String? = nil
    @State private var kind: AddonKind = .skills
    @State private var query = ""
    @State private var catalogs: [AddonKind: AddonCatalog] = [:]
    @State private var loading = false
    @State private var failure: String?

    private var catalog: AddonCatalog? { catalogs[kind] }
    private var items: [AddonItem] { catalog?.items ?? [] }
    private var updates: [AddonItem] { items.filter { $0.installed && $0.updateAvailable } }
    private var installed: [AddonItem] { items.filter { $0.installed && !$0.updateAvailable } }
    private var discover: [AddonItem] {
        let rest = items.filter { !$0.installed }
        guard query.isEmpty, let featured = catalog?.featured, !featured.isEmpty else { return rest }
        // Featured first, in Hermes's order; the rest after.
        let rank = Dictionary(uniqueKeysWithValues: featured.enumerated().map { ($1, $0) })
        return rest.sorted { (rank[$0.id] ?? .max, $0.name) < (rank[$1.id] ?? .max, $1.name) }
    }

    var body: some View {
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(AddonKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(kind.blurb + (botName.map { " For \($0)." } ?? ""))
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(HMDesign.text2)
                    Button("Try again") { Task { await load(force: true) } }
                }.hmRows()
            }
            if let timedOut = catalog?.timedOut, !timedOut.isEmpty {
                Section {
                    Text("Some sources didn't answer in time: \(timedOut.joined(separator: ", ")). Results may be incomplete.")
                        .font(.footnote).foregroundStyle(HMDesign.text2)
                }.hmRows()
            }
            group("Updates", updates)
            group("Installed", installed)
            group(query.isEmpty ? (catalog?.featured.isEmpty == false ? "Featured and more" : "Discover") : "Results", discover)
            if !loading, failure == nil, items.isEmpty {
                Section {
                    Text(query.isEmpty ? "Nothing here yet." : "Nothing matches \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(HMDesign.text2)
                }.hmRows()
            }
            if let note = catalog?.note, !note.isEmpty {
                Section { Text(note).font(.footnote).foregroundStyle(HMDesign.text2) }.hmRows()
            }
        }
        .hmCanvas()
        .navigationTitle("Add-ons")
        .searchable(text: $query, prompt: "Search \(kind.title.lowercased())")
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .task(id: "\(kind.rawValue)|\(query)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }   // wait for a pause in typing
            guard !Task.isCancelled else { return }
            await load(force: false)
        }
        .refreshable { await load(force: true) }
        .navigationDestination(for: AddonRoute.self) { route in
            AddonDetailView(kind: route.kind, item: route.item, profile: profile) { await load(force: true) }
        }
    }

    @ViewBuilder private func group(_ title: String, _ rows: [AddonItem]) -> some View {
        if !rows.isEmpty {
            Section(header: HMHeader(title)) {
                ForEach(rows) { item in
                    NavigationLink(value: AddonRoute(kind: kind, item: item)) { AddonRow(item: item, kind: kind) }
                }
            }.hmRows()
        }
    }

    private func load(force: Bool) async {
        if !force, query.isEmpty, catalogs[kind] != nil { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await API.shared.addonCatalog(kind, query: query, profile: profile)
            guard !Task.isCancelled else { return }
            catalogs[kind] = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

struct AddonRoute: Hashable {
    let kind: AddonKind
    let item: AddonItem
}

private struct AddonRow: View {
    let item: AddonItem
    let kind: AddonKind

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    TrustPill(item: item)
                }
                if !item.description.isEmpty {
                    Text(item.description).font(.footnote).foregroundStyle(HMDesign.text2).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            state
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind {
        case .skills: .indigo
        case .plugins: .teal
        case .mcp: .orange
        }
    }

    @ViewBuilder private var state: some View {
        if item.updateAvailable {
            Text("Update").font(.caption.weight(.semibold)).foregroundStyle(HMDesign.accent)
        } else if item.installed {
            if item.enabled == false {
                Text("Off").font(.caption).foregroundStyle(HMDesign.text2)
            } else if item.needsSetup {
                Text("Set up").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(HMDesign.success)
                    .accessibilityLabel("Installed")
            }
        } else {
            Text("Get").font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(HMDesign.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(HMDesign.accent)
        }
    }
}

private struct TrustPill: View {
    let item: AddonItem
    var body: some View {
        Text(item.trustLabel)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch item.trust {
        case "builtin", "trusted": HMDesign.success
        case "curated": .blue
        default: .orange
        }
    }
}

/// One add-on: what it is, where it's from, how much to trust it, what it needs, and the buttons to get it.
struct AddonDetailView: View {
    let kind: AddonKind
    @State var item: AddonItem
    let profile: String
    let changed: () async -> Void
    @State private var detail: AddonDetail?
    @State private var failure: String?
    @State private var installing = false
    @State private var working: String?
    @State private var result: AddonChange?
    @State private var confirmRemove = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.title2.weight(.semibold))
                        TrustPill(item: item)
                    }
                    if !item.description.isEmpty { Text(item.description).foregroundStyle(HMDesign.text2) }
                    HStack(spacing: 10) {
                        if !item.sourceLabel.isEmpty { Label(item.sourceLabel, systemImage: "shippingbox").font(.caption) }
                        if let version = item.version { Label(version, systemImage: "number").font(.caption) }
                        if let repo = item.repo, let url = URL(string: repo.hasPrefix("http") ? repo : "https://github.com/\(repo)") {
                            Link(destination: url) { Label("Source", systemImage: "link").font(.caption) }
                        }
                    }
                    .foregroundStyle(HMDesign.text2)
                }
                .padding(.vertical, 4)
                actions
            }.hmRows()

            if let result { ResultSection(result: result) }
            if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle") }.hmRows() }

            if let detail {
                if !detail.capabilities.isEmpty {
                    Section(header: HMHeader("What it can do")) {
                        ForEach(detail.capabilities, id: \.self) { Label($0, systemImage: "key").font(.subheadline) }
                    }.hmRows()
                }
                if !detail.env.isEmpty {
                    Section(header: HMHeader("Needs")) {
                        ForEach(detail.env, id: \.name) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(s.name).font(.system(.subheadline, design: .monospaced))
                                    if s.secret { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(HMDesign.text2) }
                                    if !s.required { Text("optional").font(.caption2).foregroundStyle(HMDesign.text2) }
                                }
                                if let d = s.description { Text(d).font(.caption).foregroundStyle(HMDesign.text2) }
                            }
                        }
                    }.hmRows()
                }
                if !detail.suggest.isEmpty {
                    Section(header: HMHeader("Try asking")) {
                        ForEach(detail.suggest, id: \.self) { Text("\u{201C}\($0)\u{201D}").font(.subheadline) }
                    }.hmRows()
                }
                if let readme = detail.readme, !readme.isEmpty {
                    Section(header: HMHeader(kind == .skills ? "SKILL.md" : "About")) {
                        MarkdownText(text: readme).font(.subheadline)
                    }.hmRows()
                }
                if !detail.files.isEmpty {
                    Section(header: HMHeader("Files")) {
                        ForEach(detail.files.prefix(40), id: \.self) {
                            Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(HMDesign.text2)
                        }
                    }.hmRows()
                }
            } else if failure == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }.hmRows()
            }
        }
        .hmCanvas()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
        .sheet(isPresented: $installing) {
            AddonInstallSheet(kind: kind, item: item, profile: profile, env: detail?.env ?? []) { change in
                result = change
                await refresh()
            }
        }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await run("Removing…") { try await API.shared.addonUninstall(kind, id: item.id, profile: profile) } } }
        } message: {
            Text("Hermes stops using it. You can install it again any time.")
        }
    }

    @ViewBuilder private var actions: some View {
        if let working {
            HStack { ProgressView(); Text(working).foregroundStyle(HMDesign.text2) }
        } else if !item.installed {
            Button { installing = true } label: {
                Label(kind == .skills ? "Scan and install" : "Install", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            if item.updateAvailable {
                Button { Task { await run("Updating…") { try await API.shared.addonUpdate(kind, id: item.id, profile: profile) } } } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if kind != .skills, let enabled = item.enabled {
                Toggle("Enabled", isOn: Binding(get: { enabled }, set: { on in
                    Task { await run(on ? "Turning on…" : "Turning off…") { try await API.shared.addonEnable(kind, id: item.id, profile: profile, enabled: on) } }
                }))
            }
            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func loadDetail() async {
        do {
            let found = try await API.shared.addonDetail(kind, id: item.id, profile: profile)
            detail = found
            item = found.item
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refresh() async {
        await changed()
        await loadDetail()
    }

    /// Run a change; a background one is followed until it ends. Consent requests come back as a result to show.
    private func run(_ label: String, _ change: () async throws -> AddonChange) async {
        working = label
        failure = nil
        defer { working = nil }
        do {
            var outcome = try await change()
            if outcome.status == "running", let action = outcome.action {
                outcome = try await AddonInstallSheet.follow(action, start: outcome) { working = $0 }
            }
            result = outcome
            await refresh()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ResultSection: View {
    let result: AddonChange
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(result.message.isEmpty ? "Done." : result.message,
                      systemImage: result.status == "blocked" ? "hand.raised.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.status == "blocked" ? .orange : HMDesign.success)
                if let note = AddonChange.restartNote(result.restart) {
                    Text(note).font(.footnote).foregroundStyle(HMDesign.text2)
                }
            }
            if result.restart == "restart_hermes" { RestartHermesButton() }
        }.hmRows()
    }
}

/// Restart Hermes once nothing is running (never interrupts a reply).
private struct RestartHermesButton: View {
    @State private var state: String?
    var body: some View {
        Button {
            Task {
                state = "Asking…"
                do { state = try await API.shared.restart("hermes").message }
                catch { state = error.localizedDescription }
            }
        } label: { Label("Restart Hermes when idle", systemImage: "arrow.clockwise") }
        if let state { Text(state).font(.footnote).foregroundStyle(HMDesign.text2) }
    }
}

/// The install, step by step: Hermes's scan (skills) or the source and trust (plugins, MCP), the settings an MCP
/// server declares, any new powers a plugin asks for, then progress until it's in.
struct AddonInstallSheet: View {
    let kind: AddonKind
    let item: AddonItem
    let profile: String
    let env: [AddonSetting]
    let done: (AddonChange) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scan: AddonScan?
    @State private var scanFailure: String?
    @State private var values: [String: String] = [:]
    @State private var acknowledged = false
    @State private var consentNeeded: [String]?
    @State private var progress: String?
    @State private var log = ""
    @State private var failure: String?

    private var missingRequired: Bool { env.contains { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
    private var needsAcknowledge: Bool { item.isCommunity || scan?.needsCare == true || consentNeeded != nil }
    private var canInstall: Bool {
        scan != nil && scan?.blocked != true && !missingRequired && (!needsAcknowledge || acknowledged) && progress == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("From", value: [item.sourceLabel, item.repo].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    LabeledContent("Trust", value: item.trustLabel)
                }
                scanSection
                if !env.isEmpty {
                    Section {
                        ForEach(env, id: \.name) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                if s.secret {
                                    SecureField(s.name + (s.required ? "" : " (optional)"), text: binding(s.name))
                                } else {
                                    TextField(s.name + (s.required ? "" : " (optional)"), text: binding(s.name))
                                }
                                if let d = s.description { Text(d).font(.caption).foregroundStyle(HMDesign.text2) }
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } header: { Text("Settings") } footer: {
                        Text("Saved on your Mac in Hermes's settings. Secrets are never shown again or sent anywhere else.")
                    }
                }
                if let consentNeeded {
                    Section {
                        ForEach(consentNeeded, id: \.self) { Label($0, systemImage: "key.fill") }
                    } header: { Text("It asks to") } footer: {
                        Text("Hermes paused the install until you agree to these.")
                    }
                }
                if needsAcknowledge, scan?.blocked != true {
                    Section {
                        Toggle(isOn: $acknowledged) {
                            Text(consentNeeded != nil ? "Allow these and install"
                                 : item.isCommunity ? "I know this is community-made and want it" : "I've read the scan and want it")
                        }
                    }
                }
                if let progress {
                    Section {
                        HStack { ProgressView(); Text(progress) }
                        if !log.isEmpty {
                            Text(log).font(.system(.caption2, design: .monospaced)).foregroundStyle(HMDesign.text2)
                                .lineLimit(12).textSelection(.enabled)
                        }
                    }
                }
                if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            }
            .navigationTitle("Install \(item.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(progress != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") { Task { await install() } }.disabled(!canInstall).fontWeight(.semibold)
                }
            }
            .task { await runScan() }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    @ViewBuilder private var scanSection: some View {
        Section {
            if let scan {
                Label(scanTitle(scan), systemImage: scan.blocked ? "hand.raised.fill" : scan.needsCare ? "exclamationmark.shield" : "checkmark.shield.fill")
                    .foregroundStyle(scan.blocked ? .red : scan.needsCare ? .orange : HMDesign.success)
                if let reason = scan.reason, !reason.isEmpty { Text(reason).font(.footnote).foregroundStyle(HMDesign.text2) }
                let counts = scan.severityCounts.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                if !counts.isEmpty {
                    Text(counts.map { "\($0.value) \($0.key)" }.joined(separator: " · ")).font(.footnote)
                }
                ForEach(scan.findings.prefix(8), id: \.self) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(f.severity.capitalized): \(f.title)").font(.caption)
                        if let file = f.file { Text(file).font(.system(.caption2, design: .monospaced)).foregroundStyle(HMDesign.text2) }
                    }
                }
            } else if let scanFailure {
                Label(scanFailure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Scan again") { Task { await runScan() } }
            } else {
                HStack { ProgressView(); Text(kind == .skills ? "Hermes is scanning it…" : "Checking…") }
            }
        } header: { Text(kind == .skills ? "Security scan" : "Check") }
    }

    private func scanTitle(_ scan: AddonScan) -> String {
        if scan.blocked { return "Hermes blocks this install" }
        if scan.verdict == "not_scanned" { return scan.needsCare ? "Not scanned. Check the source first" : "Curated by Hermes" }
        return scan.needsCare ? "Hermes found things to look at" : "Scan passed"
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func runScan() async {
        scanFailure = nil
        scan = nil
        do { scan = try await API.shared.addonScan(kind, id: item.id, profile: profile) }
        catch { scanFailure = error.localizedDescription }
    }

    private func install() async {
        guard let scan else { return }
        failure = nil
        progress = "Starting…"
        log = ""
        do {
            let settings = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            var outcome = try await API.shared.addonInstall(kind, id: item.id, profile: profile, scanID: scan.scanID,
                                                            env: settings, consent: consentNeeded != nil && acknowledged)
            if outcome.status == "consent_required" {
                // Nothing changed yet: show what it wants and ask, then the person installs again.
                consentNeeded = outcome.capabilities.isEmpty ? ["New capabilities"] : outcome.capabilities
                acknowledged = false
                progress = nil
                return
            }
            if outcome.status == "running", let action = outcome.action {
                outcome = try await Self.follow(action, start: outcome) { progress = $0 } log: { log = $0 }
            }
            progress = nil
            await done(outcome)
            dismiss()
        } catch {
            progress = nil
            failure = error.localizedDescription
        }
    }

    /// Poll a background install/update until it ends (Hermes keeps its log), up to ten minutes.
    static func follow(_ action: String, start: AddonChange, status: (String) -> Void,
                       log: (String) -> Void = { _ in }) async throws -> AddonChange {
        var result = start
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(1500))
            let now = try await API.shared.addonAction(action)
            log(now.logTail)
            switch now.state {
            case "done":
                result.message = now.message.isEmpty ? "Installed." : now.message
                result.restart = now.restart
                return result
            case "failed":
                throw APIError.http(502, now.message.isEmpty ? "It didn't finish. The log on your Mac has the details." : now.message)
            default:
                status(now.message.isEmpty ? "Working…" : now.message)
            }
        }
        throw APIError.http(504, "Still working after ten minutes. Check again from Add-ons in a bit.")
    }
}
