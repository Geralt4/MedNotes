import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The graph: settings kept in the store, query results, filtering, and opening a node.
extension AppSession {
    func loadGraphSettings() async {
        guard let store else { return }
        func read(_ key: String) async -> GraphSettings {
            guard let json = try? await store.db.appState(key: key),
                  let data = json.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(GraphSettings.self, from: data) else { return GraphSettings() }
            return settings.clamped
        }
        let global = await read(Self.globalGraphKey)
        let local = await read(Self.localGraphKey)
        guard store === self.store else { return }
        graphSettingsLoaded = false
        graphSettings = global
        localGraphSettings = local
        graphSettingsLoaded = true
        scheduleGraphQuerySets(immediately: true)
    }

    // MARK: Filtering the graph

    /// What a change to the settings needs: new query results when a query or
    /// group changed (looked up in the store, so debounced like the notes
    /// search), otherwise only the cheap filter pass. Forces and display
    /// options need neither; the canvas reads them directly.
    func graphSettingsChanged(from old: GraphSettings) {
        let new = graphSettings
        func queries(_ settings: GraphSettings) -> [String] { [settings.query] + settings.groups.map(\.query) }
        if queries(old) != queries(new) || old.groups.map(\.id) != new.groups.map(\.id) {
            scheduleGraphQuerySets()
        } else if old.showPatients != new.showPatients || old.showEvents != new.showEvents
                    || old.showOrphans != new.showOrphans || old.groups != new.groups {
            applyGraphFilter()
        }
    }

    private func scheduleGraphQuerySets(immediately: Bool = false) {
        graphQueryTask?.cancel()
        graphQueryTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, let self else { return }
            await self.refreshGraphQuerySets()
        }
    }

    private func refreshGraphQuerySets() async {
        guard let asked = store else { return }
        let settings = graphSettings
        let sets = await graphQuerySets(for: settings)
        func queries(_ settings: GraphSettings) -> [String] { [settings.query] + settings.groups.map(\.query) }
        // A lock may have come in, or the settings may have been edited, while
        // the store was asked; an edit has its own pass.
        guard !Task.isCancelled, asked === store, queries(settings) == queries(graphSettings) else { return }
        graphMatching = sets.matching
        graphGroupMatches = sets.groups
        applyGraphFilter()
    }

    private func applyGraphFilter() {
        filteredGraph = GraphFilter.apply(
            graphData, settings: graphSettings, matching: graphMatching, groupMatches: graphGroupMatches)
    }

    /// Saves shortly after the last change, so a slider drag is one write.
    func scheduleGraphSettingsSave(_ key: String) {
        guard graphSettingsLoaded, let store else { return }
        graphSaveTasks[key]?.cancel()
        graphSaveTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, store === self.store, self.graphSettingsLoaded else { return }
            let settings = key == Self.globalGraphKey ? self.graphSettings : self.localGraphSettings
            guard let data = try? JSONEncoder().encode(settings),
                  let json = String(data: data, encoding: .utf8) else { return }
            try? await store.db.setAppState(key: key, json: json)
        }
    }

    /// The notes a graph's filter and colour groups pick out, as graph node
    /// ids; nil `matching` when the filter is empty.
    func graphQuerySets(for settings: GraphSettings) async -> (matching: Set<String>?, groups: [UUID: Set<String>]) {
        guard let store else { return (nil, [:]) }
        func nodeIDs(_ text: String) async -> Set<String> {
            let ids = (try? await store.notes.matchingIDs(text)) ?? []
            return Set(ids.map { "n:\($0)" })
        }
        let matching: Set<String>? = settings.hasQuery ? await nodeIDs(settings.query) : nil
        var groups: [UUID: Set<String>] = [:]
        for group in settings.groups where !group.query.trimmingCharacters(in: .whitespaces).isEmpty {
            groups[group.id] = await nodeIDs(group.query)
        }
        return (matching, groups)
    }

    func loadGraph() async {
        guard let store else { return }
        let data: LinkingService.GraphData
        do {
            data = try await store.linking.graph()
        } catch {
            data = LinkingService.GraphData()
        }
        // A lock may have come in while the store was read: nothing of it is shown.
        guard store === self.store else { return }
        graphData = data
        graphGeneration &+= 1
        // Notes may have changed since the last pass: ask again, then filter.
        graphQueryTask?.cancel()
        await refreshGraphQuerySets()
        if store !== self.store { return }
        applyGraphFilter()
    }

    func jumpToGraphNode(_ node: LinkingService.GraphNode) async {
        // Node ids are "<kind>:<uuid>" — drop the prefix *and* the separator.
        let raw = String(node.id.dropFirst(2))
        switch node.id.first {
        case "n":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealNote(uuid)
        case "p":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealPatient(uuid)
        case "e":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealEvent(uuid)
        default:
            break
        }
    }
}
