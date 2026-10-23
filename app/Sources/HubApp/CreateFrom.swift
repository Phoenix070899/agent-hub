import HubCore
import SwiftUI

/// Where Create from looks: anything (Smart), a GitHub issue, an existing branch, or a name for a
/// new branch.
enum CreateFromTab: CaseIterable, Identifiable {
    case smart, github, branch, name

    var id: Self { self }

    var title: String {
        switch self {
        case .smart: "Smart"
        case .github: "GitHub"
        case .branch: "Branch"
        case .name: "Name"
        }
    }

    var icon: String {
        switch self {
        case .smart: "sparkles"
        case .github: "number"
        case .branch: "arrow.triangle.branch"
        case .name: "textformat"
        }
    }

    var placeholder: String {
        switch self {
        case .smart: "Type a name, #1234, a branch, or a GitHub issue link"
        case .github: "An issue number, like 1234, or its link"
        case .branch: "Find a branch, or name a new one"
        case .name: "A name for the new branch, like Magic link login"
        }
    }
}

/// Create from, in the Start a session dialog: an agent can work on its own branch in its own
/// worktree, so several Orchestrators work on different features without touching each other's
/// files. Left empty, the agent works in the repo's own checkout.
struct CreateFromSection: View {
    @ObservedObject var form: NewSessionForm
    let submit: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                (Text("Create from ").foregroundStyle(Ledger.ink2) + Text("(optional)").foregroundStyle(Ledger.ink3))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 8)
                basePicker
            }

            HStack(spacing: 18) {
                ForEach(CreateFromTab.allCases) { tab in
                    TabButton(tab: tab, picked: form.tab == tab) {
                        form.tab = tab
                        form.problem = nil
                        if tab == .branch { form.from = "" }
                        fieldFocused = true
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Ledger.rule).frame(height: 1) }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ledger.ink3)
                TextField(form.tab.placeholder, text: $form.from)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit(submit)
            }
            .ledgerField()
            .padding(.top, 10)
            .onChange(of: form.from) {
                form.problem = nil
                if form.tab == .branch, form.pickedBranch != form.from { form.pickedBranch = nil }
            }

            if form.tab == .branch {
                branchList.padding(.top, 6)
            }

            if let problem = form.problem {
                note(problem, color: Ledger.failInk)
            } else if let (text, warn) = summary {
                note(text, color: warn ? Ledger.failInk : Ledger.ink2)
            }
        }
        // Where the dialog starts typing, as Orca's does; after the terminal lets go of the keyboard.
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    /// New branches start from this branch.
    private var basePicker: some View {
        Menu {
            ForEach(form.branches) { branch in
                Button(branch.name) { form.base = branch.name }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(form.base.isEmpty ? "HEAD" : form.base)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Ledger.ink2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Ledger.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New branches start from \(form.base.isEmpty ? "the repo's checkout" : form.base)")
        .accessibilityLabel("Start new branches from \(form.base)")
    }

    private var branchList: some View {
        let text = form.from.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = form.branches.filter { text.isEmpty || $0.name.lowercased().contains(text) }.prefix(5)
        return VStack(spacing: 2) {
            if shown.isEmpty {
                Text(form.branches.isEmpty ? "Reading branches…" : text.isEmpty ? "No branches." : "No branch matches; Return makes a new one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            ForEach(Array(shown)) { branch in
                Button {
                    form.pickedBranch = branch.name
                    form.from = branch.name
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: form.pickedBranch == branch.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(form.pickedBranch == branch.name ? Ledger.ink : Ledger.ink3)
                        Text(branch.name)
                            .font(.system(size: 12.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(place(of: branch))
                            .font(.system(size: 12))
                            .foregroundStyle(Ledger.ink3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(form.pickedBranch == branch.name ? Ledger.chosen : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(form.pickedBranch == branch.name ? .isSelected : [])
            }
        }
    }

    private func place(of branch: RepoBranch) -> String {
        if let agent = branch.agent { return "a\(agent) works here" }
        if branch.name == form.current { return "the repo's checkout" }
        return branch.checkout == nil ? "" : "has a worktree"
    }

    /// What will happen, and whether it needs a second look.
    private var summary: (String, Bool)? {
        let base = form.base.isEmpty ? "the repo's checkout" : form.base
        switch form.choice {
        case nil:
            return form.tab == .branch
                ? ("Pick a branch or type a new one; left empty, it works in the repo's checkout.", false)
                : ("Empty: it works in the repo's checkout\(form.current.isEmpty ? "" : " of \(form.current)").", false)
        case .issue(let typed)?:
            guard issueReference(typed) != nil else {
                return ("Type an issue number, like 12, or its link.", true)
            }
            return ("Reads the issue, then works on a new branch from \(base) in its own worktree.", false)
        case .branch(let name)?:
            return existing(name)
        case .newBranch(let name)?:
            return ("No branch \(name) yet. Works on a new branch \(name) from \(base), in its own worktree.", false)
        case .name(let text)?:
            let branch = fanoutBranch(text)
            if form.branches.contains(where: { $0.name == branch }) {
                let (text, warn) = existing(branch)
                return ("\(branch) already exists. " + text, warn)
            }
            return ("Works on a new branch \(branch) from \(base), in its own worktree.", false)
        }
    }

    /// Where an agent on existing branch `name` works: wherever the branch is checked out.
    private func existing(_ name: String) -> (String, Bool) {
        let branch = form.branches.first { $0.name == name }
        if let agent = branch?.agent {
            return ("a\(agent) already works on \(name); both would change the same files.", true)
        }
        if name == form.current { return ("Works in the repo's checkout, on \(name).", false) }
        return branch?.checkout == nil
            ? ("Works on \(name) in a new worktree.", false)
            : ("Works on \(name) in its worktree.", false)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.top, 6)
    }
}

/// One Create from tab: icon and title, underlined when picked.
private struct TabButton: View {
    let tab: CreateFromTab
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon).font(.system(size: 12))
                Text(tab.title)
            }
            .font(.system(size: 13, weight: picked ? .semibold : .regular))
            .foregroundStyle(picked ? Ledger.ink : Ledger.ink3)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if picked { Rectangle().fill(Ledger.ink).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
