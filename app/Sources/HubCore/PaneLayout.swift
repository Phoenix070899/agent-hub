import Foundation

/// A terminal a tab shows: the session's Orchestrator, one of its Workers (`w12`), or a shell.
public enum TabRef: Hashable, Codable, Sendable {
    case orchestrator
    case worker(String)
    case shell(Int)
}

/// One pane: its own tabs, one of them showing.
public struct TabGroup: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var tabs: [TabRef]
    public var active: Int

    public init(id: Int, tabs: [TabRef], active: Int = 0) {
        self.id = id
        self.tabs = tabs
        self.active = active
    }

    public var activeTab: TabRef? { tabs.indices.contains(active) ? tabs[active] : tabs.last }
}

/// Which way a split lays its two panes out.
public enum SplitAxis: String, Codable, Sendable {
    /// Side by side: Split Right.
    case horizontal
    /// One above the other: Split Down.
    case vertical
}

/// A session's panes as a split tree; every leaf is a pane with its own tabs.
public indirect enum PaneLayout: Equatable, Codable, Sendable {
    case group(TabGroup)
    case split(SplitAxis, PaneLayout, PaneLayout)

    /// One pane showing the Orchestrator.
    public static let single = PaneLayout.group(TabGroup(id: 0, tabs: [.orchestrator]))

    /// Panes in reading order: left before right, top before bottom.
    public var groups: [TabGroup] {
        switch self {
        case .group(let group): return [group]
        case .split(_, let first, let second): return first.groups + second.groups
        }
    }

    public func group(_ id: Int) -> TabGroup? { groups.first { $0.id == id } }

    /// The pane showing `tab` among its tabs, if any.
    public func groupHolding(_ tab: TabRef) -> TabGroup? { groups.first { $0.tabs.contains(tab) } }

    public var nextGroupID: Int { (groups.map(\.id).max() ?? -1) + 1 }

    /// Applies `change` to one pane.
    public func updating(_ id: Int, _ change: (inout TabGroup) -> Void) -> PaneLayout {
        switch self {
        case .group(var group) where group.id == id:
            change(&group)
            return .group(group)
        case .group:
            return self
        case .split(let axis, let first, let second):
            return .split(axis, first.updating(id, change), second.updating(id, change))
        }
    }

    /// Shows `tab`: where it is already open, else as a new tab in pane `id`. Returns the layout
    /// and the pane now showing it.
    public func opening(_ tab: TabRef, in id: Int) -> (PaneLayout, Int) {
        if let holder = groupHolding(tab) {
            return (updating(holder.id) { $0.active = $0.tabs.firstIndex(of: tab) ?? $0.active }, holder.id)
        }
        let target = group(id) != nil ? id : groups[0].id
        return (updating(target) { group in
            group.tabs.insert(tab, at: min(group.active + 1, group.tabs.count))
            group.active = min(group.active + 1, group.tabs.count - 1)
        }, target)
    }

    /// Splits pane `id`, putting a new pane holding `tab` after it (right or below).
    public func splitting(_ id: Int, _ axis: SplitAxis, with tab: TabRef) -> (PaneLayout, Int) {
        let newID = nextGroupID
        func split(_ node: PaneLayout) -> PaneLayout {
            switch node {
            case .group(let group) where group.id == id:
                return .split(axis, node, .group(TabGroup(id: newID, tabs: [tab])))
            case .group:
                return node
            case .split(let a, let first, let second):
                return .split(a, split(first), split(second))
            }
        }
        return (split(self), newID)
    }

    /// Without `tab`. A pane left empty goes, its sibling taking the space; the last pane falls
    /// back to the Orchestrator.
    public func closing(_ tab: TabRef) -> PaneLayout {
        guard let holder = groupHolding(tab) else { return self }
        var layout = updating(holder.id) { group in
            let index = group.tabs.firstIndex(of: tab)!
            group.tabs.remove(at: index)
            if group.active >= index { group.active = max(group.active - 1, 0) }
        }
        if layout.group(holder.id)?.tabs.isEmpty == true {
            layout = layout.removingGroup(holder.id)
        }
        return layout
    }

    func removingGroup(_ id: Int) -> PaneLayout {
        switch self {
        case .group(let group) where group.id == id:
            return .group(TabGroup(id: id, tabs: [.orchestrator]))
        case .group:
            return self
        case .split(let axis, let first, let second):
            if case .group(let g) = first, g.id == id { return second }
            if case .group(let g) = second, g.id == id { return first }
            return .split(axis, first.removingGroup(id), second.removingGroup(id))
        }
    }

    /// Without tabs whose terminal is gone: shells not open, Workers no longer listed.
    public func keeping(shells: Set<Int>, workers: Set<String>) -> PaneLayout {
        groups.flatMap(\.tabs).reduce(self) { layout, tab in
            switch tab {
            case .shell(let id) where !shells.contains(id): return layout.closing(tab)
            case .worker(let id) where !workers.contains(id): return layout.closing(tab)
            default: return layout
            }
        }
    }

    /// The pane after (or before) pane `id` in reading order, wrapping around.
    public func neighbor(of id: Int, forward: Bool) -> Int {
        let ids = groups.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.count > 1 else { return id }
        return ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
    }
}
