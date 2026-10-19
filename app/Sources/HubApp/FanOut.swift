import HubCore
import SwiftUI

/// Fan out a Task: several Workers try it, each in its own worktree on its own branch, so the
/// human can compare what they did and keep one.
struct FanOutModal: View {
    @EnvironmentObject private var model: AppModel
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var form = FanOutForm()
    @FocusState private var titleFocused: Bool

    private var repo: String? { model.selectedRepo }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fan out a Task")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Several Workers try the same Task, each on its own branch. Compare what they did, then keep one.")
                        .foregroundStyle(Ledger.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)

                FieldLabel("Task")
                TextField("A short name, like Speed up the bench", text: $form.title)
                    .textFieldStyle(.plain)
                    .ledgerField()
                    .focused($titleFocused)
                    .padding(.horizontal, 24)
                    .onChange(of: form.title) {
                        if !form.branchEdited { form.branch = fanoutBranch(form.title) }
                    }

                FieldLabel("What to do")
                    .padding(.top, 14)
                TextField("Everything a Worker needs: the goal, where to look, how to check it works", text: $form.spec, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(4...8)
                    .ledgerField()
                    .padding(.horizontal, 24)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                    GridRow {
                        label("Profile")
                        Picker("Profile", selection: $form.profile) {
                            ForEach(form.profiles) { profile in
                                Text("\(profile.name), \(profile.model)").tag(profile.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        label("Tries")
                        Picker("Tries", selection: $form.count) {
                            ForEach(2...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        label("Branch")
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("feat/task", text: branchBinding)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .autocorrectionDisabled()
                                .ledgerField()
                            Text(branchNote)
                                .font(.system(size: 12))
                                .foregroundStyle(Ledger.ink3)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if let note = orchestratorNote {
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }
                if let problem = form.problem {
                    Text(problem)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.failInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close)
                        .buttonStyle(.ledger)
                        .keyboardShortcut(.cancelAction)
                    Button(form.starting ? "Starting \(form.count) Workers…" : "Start \(form.count) Workers", action: start)
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready || form.starting || model.daemonDown)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)
            }
            .frame(width: 560)
            .background(Ledger.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // A hairline, not a shadow, sets it apart from the dimmed window.
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ledger.rule))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            DispatchQueue.main.async { titleFocused = true }
            model.loadProfiles { profiles in
                // Tries by a profile that edits files differ; the rest come after.
                form.profiles = profiles.filter(\.writes) + profiles.filter { !$0.writes }
                if form.profile.isEmpty { form.profile = form.profiles.first?.name ?? "" }
            }
        }
        .onExitCommand(perform: close)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Ledger.ink2)
            .frame(width: 56, alignment: .leading)
    }

    private var branchBinding: Binding<String> {
        Binding { form.branch } set: {
            form.branch = $0
            form.branchEdited = true
        }
    }

    private var branchNote: String {
        let branch = form.branch.trimmingCharacters(in: .whitespaces)
        return form.count == 2 ? "\(branch)-1 and \(branch)-2" : "\(branch)-1 to \(branch)-\(form.count)"
    }

    private var orchestratorNote: String? {
        guard let orchestrator = model.fanOutOrchestrator else { return nil }
        return "\(orchestrator.displayName) hears how each try ends, as with Workers it starts."
    }

    private var ready: Bool {
        repo != nil && !form.profile.isEmpty
            && !form.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !form.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !form.branch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func start() {
        guard ready, let repo, !form.starting else { return }
        form.starting = true
        form.problem = nil
        model.fanOut(repo: repo, agent: model.fanOutOrchestrator?.id, profile: form.profile,
                     title: form.title.trimmingCharacters(in: .whitespaces), spec: form.spec,
                     branch: form.branch.trimmingCharacters(in: .whitespaces), count: form.count) { problem in
            form.starting = false
            if let problem, model.selectedWorker == nil {
                form.problem = problem
            } else {
                if let problem { model.error = problem }
                close()
            }
        }
    }

    private func close() {
        model.fanOutShown = false
    }
}

final class FanOutForm: ObservableObject {
    @Published var title = ""
    @Published var spec = ""
    @Published var profile = ""
    @Published var profiles: [WorkerProfile] = []
    @Published var count = 3
    @Published var branch = ""
    /// The human typed a branch; the Task's name no longer renames it.
    @Published var branchEdited = false
    @Published var starting = false
    @Published var problem: String?
}

/// Every try of a fan-out side by side: what each changed and reported, and a way to keep one.
struct CompareView: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let fanout: String

    private var tries: [WorkerRow] {
        model.snapshot(repo).workers
            .filter { $0.fanout == fanout }
            .sorted { ($0.branch ?? "").localizedStandardCompare($1.branch ?? "") == .orderedAscending }
    }

    var body: some View {
        let tries = tries
        let title = "\u{201C}\(tries.first?.title ?? "")\u{201D}"
        // One try left: the others were closed when it was kept.
        let kept = tries.count == 1
            ? model.kept[fanout] ?? "Kept \(tries[0].id): \(tries[0].branch ?? "its branch") is merged. The other tries are closed; their branches stay."
            : nil
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kept == nil ? "\(tries.count) tries of \(title)" : "The kept try of \(title)")
                    .fontWeight(.semibold)
                Text(kept ?? "Each try works on its own branch. Keep one: its branch is merged into the repo and the others close.")
                    .foregroundStyle(kept == nil ? Ledger.ink3 : Ledger.okInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kept == nil ? Ledger.paper : Ledger.okWash)
            Divider().overlay(Ledger.rule)
            GeometryReader { geometry in
                let gap: CGFloat = 12
                let width = max(250, (geometry.size.width - 36 - gap * CGFloat(tries.count - 1)) / CGFloat(max(tries.count, 1)))
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(tries) { worker in
                            TryColumn(repo: repo, worker: worker, alone: tries.count == 1)
                                .frame(width: width)
                        }
                    }
                    .padding(18)
                    // Smaller than the view, the columns still start at its top left.
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .background(Ledger.paper)
        }
    }
}

/// One try in a fan-out: its state, files changed, Final Report, and Keep.
struct TryColumn: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let worker: WorkerRow
    /// The others are closed: there is nothing left to keep it over.
    let alone: Bool
    @StateObject private var diff = TryDiff()
    @StateObject private var confirmKeep = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(worker.id) \(worker.profile)").fontWeight(.semibold)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    StateMark(color: worker.markColor)
                    Text(worker.isActive ? "Running" : worker.phaseLabel)
                }
                .font(.system(size: 12))
                .foregroundStyle(worker.markColor)
            }
            Text(worker.branch ?? worker.place)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Ledger.ink3)
                .lineLimit(1)
                .truncationMode(.middle)

            // Once kept, its branch is merged: a diff against the repo shows nothing left to compare.
            if !alone {
                files
                Divider().overlay(Ledger.rule)
            }
            report

            HStack(spacing: 8) {
                Button("Changes") {
                    model.select(.worker(repo: repo, id: worker.id))
                    model.show(.changes, repo: repo, worker: worker)
                }
                .buttonStyle(.ledger)
                Spacer(minLength: 4)
                if !alone {
                    Button("Keep this one") { confirmKeep.on = true }
                        .buttonStyle(.ledgerPrimary)
                        .disabled(worker.isActive || worker.branch == nil)
                        .help(worker.isActive ? "\(worker.id) is still working. Keep it once it sends its Final Report." : "Merge \(worker.branch ?? "its branch") and close the other tries.")
                }
            }
            .padding(.top, 2)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Read again as it works and when it settles.
        .task(id: "\(worker.id) \(worker.phase) \(worker.progress ?? "")") {
            if !alone { load() }
        }
        .confirmationDialog("Keep \(worker.id) and merge \(worker.branch ?? "")?", isPresented: $confirmKeep.on) {
            Button("Merge \(worker.id)") { model.keep(worker, repo: repo) }
        } message: {
            Text("Anything \(worker.id) left uncommitted is committed, then \(worker.branch ?? "its branch") is merged into the repo's current branch. The other tries close and their worktrees are removed, uncommitted work included; their branches stay.")
        }
    }

    @ViewBuilder
    private var files: some View {
        if let problem = diff.problem {
            Text(problem).foregroundStyle(Ledger.failInk).lineLimit(3)
        } else if let files = diff.files {
            let added = files.reduce(0) { $0 + $1.additions }
            let removed = files.reduce(0) { $0 + $1.deletions }
            if files.isEmpty {
                Text("No changes yet").foregroundStyle(Ledger.ink3)
            } else {
                HStack(spacing: 6) {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    Text("+\(added)").foregroundStyle(Ledger.okInk)
                    Text("-\(removed)").foregroundStyle(Ledger.failInk)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Text(file.path)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("+\(file.additions)").foregroundStyle(Ledger.okInk)
                            Text("-\(file.deletions)").foregroundStyle(Ledger.failInk)
                        }
                        .font(.system(size: 11.5))
                    }
                    if files.count > 8 {
                        Text("and \(files.count - 8) more").foregroundStyle(Ledger.ink3)
                    }
                }
            }
        } else {
            Text("Reading its changes…").foregroundStyle(Ledger.ink3)
        }
    }

    @ViewBuilder
    private var report: some View {
        if let text = worker.finalReport {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ReportSection.parse(text).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = section.title {
                            Text(title).fontWeight(.semibold)
                        }
                        Text(section.body)
                            .foregroundStyle(Ledger.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            Text(worker.isActive ? (worker.progress ?? "Working; no status sent yet.") : "No Final Report.")
                .foregroundStyle(Ledger.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() {
        model.loadDiff(worker) { result in
            switch result {
            case .success(let read):
                diff.files = parseDiff(read.diff)
                diff.problem = nil
            case .failure(let error):
                diff.problem = "\(error)"
            }
        }
    }
}

final class TryDiff: ObservableObject {
    @Published var files: [DiffFile]?
    @Published var problem: String?
}
