import SwiftUI
import SwiftData

/// The Marine Life tab: the species seen on the dives and the species catalogue.
struct MarineLifeView: View {
    @Environment(DiveStore.self) private var store
    /// Shows the Dives tab, after "View dives" set the list's marine life filter.
    @Environment(\.showDiveList) private var showDiveList
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @Query(sort: \Species.commonName) private var catalogue: [Species]

    @State private var appeared = false
    @State private var statsReady = false
    /// The tab is shown. A tab stays loaded after its first visit: the statistics are
    /// recomputed only while it is shown (and when it is shown again, if anything changed).
    @State private var isShown = false
    /// Catalogue species opened from the list, shown in a sheet.
    @State private var shownSpecies: Species?
    /// Sightings not in the catalogue, shown in a sheet like a catalogue species.
    @State private var shownUnlinkedSpecies: SpeciesAggregate?
    /// The catalogue species whose row was swiped to delete, until confirmed.
    @State private var speciesToDelete: Species?

    // Cached aggregates
    @State private var cachedSpecies: [SpeciesAggregate] = []
    /// Distinct names recorded on the dives shown (the selected diver's) that are no
    /// catalogue species.
    @State private var cachedNotInCatalogueCount = 0
    @State private var cachedTotalSpecies: Int = 0
    @State private var cachedTotalSightings: Int = 0
    @State private var cachedDivesWithLife: Int = 0

    @State private var searchText: String = ""
    /// Stored category value to show only ("" = all categories).
    @State private var categoryFilter: String = ""
    /// Shows only the catalogue species not linked to iNaturalist yet.
    @State private var notLinkedFilter = false
    /// iNaturalist taxon to show only, as "rank|name" ("" = all), e.g. "family|Nephropidae".
    @State private var taxonFilter: String = ""
    @State private var showAddSpecies = false
    @State private var showFilterSheet = false
    @State private var buildPlan: SpeciesCatalog.BuildPlan?
    @State private var buildResult: (created: Int, linked: Int)?
    @State private var speciesProposals: [SpeciesPhotoProposal] = []
    @State private var showNoSpeciesInPhotos = false

    /// Bumped after a catalogue action here; with `store.sightingsVersion` (sightings saved,
    /// full rebuilds) it makes the statistics recompute only when something changed.
    @State private var contentVersion = 0
    /// The statistics' inputs: sightingsVersion (any sighting saved — a quantity or
    /// species-link edit leaves the dive summaries unchanged — or a full rebuild),
    /// contentVersion (catalogue actions here), the catalogue, the diver, the language, and the
    /// names shown (`Species.displayName` follows the names language and the iNaturalist names setting).
    private var statsKey: String {
        "\(store.sightingsVersion):\(contentVersion):\(catalogueHash):\(selectedDiver):\(UserPreferences.shared.languageMode.rawValue):\(UserPreferences.shared.taxonomyNameLanguage):\(UserPreferences.shared.useINaturalistCommonNames)"
    }
    /// The inputs the shown statistics were computed for.
    @State private var computedStatsKey = ""
    /// Built once per statistics pass, not on every redraw.
    @State private var cachedNumberMap: [PersistentIdentifier: Int] = [:]
    @State private var cachedSpeciesByID: [PersistentIdentifier: Species] = [:]
    /// Group names per rank and the categories in use, rebuilt when the catalogue changes
    /// (reading a classification decodes JSON, too costly to repeat on every redraw).
    @State private var cachedTaxonNames: [String: [String]] = [:]
    /// Common name of each group ("Actinopterygii" → "Ray-finned Fishes"), when known.
    @State private var cachedGroupCommonNames: [String: String] = [:]
    @State private var cachedUsedCategories: [String] = []
    /// Catalogue species in the selected taxon (empty when no taxon is selected).
    @State private var cachedTaxonSpeciesIDs: Set<PersistentIdentifier> = []

    struct SpeciesAggregate: Identifiable, Hashable {
        /// "s:<species id>" for a catalogue species, "n:<lowercased name>" for sightings not
        /// yet in the catalogue.
        let id: String
        let name: String         // common name, or the most common spelling of the sightings
        let scientificName: String?
        let category: String?
        let speciesID: PersistentIdentifier?
        let entryCount: Int      // total number of sighting records
        let diveCount: Int       // number of distinct dives where seen
        let lastSeen: Date?
        let diveIDs: Set<UUID>
        let quantityCounts: [SightingQuantity: Int]  // times each range was recorded
        /// The species' other names (other, iNaturalist and stored common names) and the names
        /// its sightings were recorded with, for the search.
        let otherNames: [String]
        /// A catalogue species linked to an iNaturalist taxon.
        let isLinked: Bool
    }

    /// The selected diver has no dive. From the dive summaries, not the dives: `store.dives`
    /// can briefly hold a dive another device deleted (until the next debounced
    /// rebuild), and reading a deleted dive crashes.
    private var selectedDiverHasNoDive: Bool {
        !selectedDiver.isEmpty && !store.cachedSummaries.isEmpty
            && !store.cachedSummaries.contains { $0.diverName == selectedDiver }
    }

    /// The diver the catalogue actions (Build Catalogue from Sightings, Find Species in Photos)
    /// work on, as the tab shows it; nil for every diver.
    private var diverScope: String? { selectedDiver.isEmpty ? nil : selectedDiver }

    /// The photos with IPTC text, of the selected diver's dives only when one is selected
    /// (compared as `DiverFilter.apply` does; a photo with no dive is nobody's).
    private var photosWithIPTCInScope: [DivePhoto] {
        let photos = SpeciesPhotoMatcher.photosWithIPTC(in: modelContext)
        guard let diverScope else { return photos }
        return photos.filter { photo in
            guard let dive = photo.dive, !dive.isDeleted, dive.modelContext != nil else { return false }
            return dive.diverName.trimmingCharacters(in: .whitespaces) == diverScope
        }
    }

    /// Changes when a catalogue species is added, removed or renamed, gets other names (its
    /// save links the sightings that use them), or gets iNaturalist
    /// data (a lookup sets `inatFetchedAt`; fetching names in another language changes the
    /// size of the stored names and classification).
    private var catalogueHash: Int {
        catalogue.reduce(0) { h, species in
            (h &* 31) &+ species.id.hashValue &+ species.commonName.hashValue
                &+ (species.scientificName?.hashValue ?? 0) &+ (species.category?.hashValue ?? 0)
                &+ (species.altNames?.hashValue ?? 0)
                &+ (species.inatFetchedAt?.hashValue ?? 0)
                &+ (species.inatCommonNamesData?.count ?? 0) &* 7 &+ (species.taxonomyData?.count ?? 0)
        }
    }

    /// Ranks offered in the taxonomy filter.
    private static let filterRanks = ["class", "order", "family", "genus"]

    private var taxonFilterParts: (rank: String, name: String)? {
        let parts = taxonFilter.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Catalogue species in the selected taxon.
    private var speciesInTaxon: [Species] {
        cachedTaxonSpeciesIDs.compactMap { liveSpecies($0) }
    }

    /// The cached species with `id`, unless it was deleted since the cache was built (here,
    /// in its page, or on another device): reading a deleted SwiftData object is unsafe, and
    /// the caches are rebuilt only when the statistics task runs again.
    private func liveSpecies(_ id: PersistentIdentifier) -> Species? {
        guard let species = cachedSpeciesByID[id], !species.isDeleted, species.modelContext != nil else { return nil }
        return species
    }

    /// Names at `rank` used by the catalogue's iNaturalist classifications.
    private func taxonNames(rank: String) -> [String] {
        cachedTaxonNames[rank] ?? []
    }

    /// Rebuilds the taxonomy and category caches from the catalogue.
    private func rebuildCatalogueCaches() {
        var names: [String: Set<String>] = [:]
        var commonNames: [String: String] = [:]
        var byID: [PersistentIdentifier: Species] = [:]
        for species in catalogue {
            byID[species.persistentModelID] = species
            for rank in species.taxonomy where Self.filterRanks.contains(rank.rank) {
                names[rank.rank, default: []].insert(rank.name)
                if commonNames[rank.name] == nil, let common = rank.commonName, !common.isEmpty {
                    commonNames[rank.name] = common
                }
            }
        }
        cachedSpeciesByID = byID
        cachedTaxonNames = names.mapValues { $0.sorted() }
        cachedGroupCommonNames = commonNames
        let used = Set(catalogue.compactMap(\.category).filter { !$0.isEmpty })
        cachedUsedCategories = SpeciesCategory.allCases.map(\.storedValue).filter { used.contains($0) }
            + SpeciesCategory.customCategories(in: catalogue)
        rebuildTaxonSelection()
    }

    private func pruneDeletedSpecies() {
        let live = Set(catalogue.map(\.persistentModelID))
        cachedSpeciesByID = cachedSpeciesByID.filter { live.contains($0.key) }
        cachedTaxonSpeciesIDs.formIntersection(live)
        cachedSpecies.removeAll { aggregate in aggregate.speciesID.map { !live.contains($0) } ?? false }
    }

    private func rebuildTaxonSelection() {
        guard let (rank, name) = taxonFilterParts else { cachedTaxonSpeciesIDs = []; return }
        cachedTaxonSpeciesIDs = Set(catalogue.filter { $0.taxonName(rank: rank) == name }.map(\.persistentModelID))
    }

    /// The "not linked" filter applies only while iNaturalist lookups are on (its menu item is
    /// hidden otherwise).
    private var notLinkedFilterActive: Bool { notLinkedFilter && UserPreferences.shared.fetchTaxonomyOnline }

    /// Read once per body pass (`speciesListSection`): it searches every name of every row.
    private var filteredSpecies: [SpeciesAggregate] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let taxonIDs = taxonFilterParts == nil ? nil : cachedTaxonSpeciesIDs
        // Categories whose localized name matches, looked up once per category, not per row.
        // (Every category of the rows, custom ones included.)
        let matchingCategories = trimmed.isEmpty ? [] : Set(cachedSpecies.compactMap(\.category)).filter {
            SpeciesCategory.displayName($0)?.localizedCaseInsensitiveContains(trimmed) ?? false
        }
        return cachedSpecies.filter { aggregate in
            if !categoryFilter.isEmpty, aggregate.category != categoryFilter { return false }
            if notLinkedFilterActive, aggregate.speciesID == nil || aggregate.isLinked { return false }
            if let taxonIDs {
                guard let id = aggregate.speciesID, taxonIDs.contains(id) else { return false }
            }
            guard !trimmed.isEmpty else { return true }
            return aggregate.name.localizedCaseInsensitiveContains(trimmed)
                || (aggregate.scientificName?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || aggregate.otherNames.contains { $0.localizedCaseInsensitiveContains(trimmed) }
                || aggregate.category.map { matchingCategories.contains($0) } ?? false
        }
    }

    /// Categories used in the catalogue, for the filter menu.
    private var usedCategories: [String] { cachedUsedCategories }


    /// - Returns: false when the pass was cancelled or superseded (nothing was published).
    private func computeStats() async -> Bool {
        typealias Accumulator = (name: String, scientific: String?, category: String?, speciesID: PersistentIdentifier?,
                                 entryCount: Int, dives: Set<UUID>, last: Date?, casings: [String: Int],
                                 qtyCounts: [SightingQuantity: Int], otherNames: Set<String>)

        // Dive numbers for the pages pushed from here, once per pass.
        let total = store.dives.count
        cachedNumberMap = Dictionary(store.dives.enumerated().map { ($0.element.persistentModelID, total - $0.offset) },
                                     uniquingKeysWith: { first, _ in first })

        // Every sighting, as plain values read from the store off the main thread, the diver
        // filter applied on the dives as stored (DiveStore.sightingValues / SightingReader).
        // Nil: a newer pass superseded this one.
        let speciesByName = SpeciesNameIndex(catalogue: catalogue).speciesIDsByKey
        guard let values = await store.sightingValues(diverName: selectedDiver.isEmpty ? nil : selectedDiver,
                                                      speciesByName: speciesByName, namesKey: catalogueHash,
                                                      container: modelContext.container),
              !Task.isCancelled else { return false }
        // Display data of each catalogue species, read once (live query results).
        var speciesInfo: [PersistentIdentifier: (id: UUID, name: String, scientific: String?, category: String?,
                                                 otherNames: Set<String>)] = [:]
        var linkedSpecies = Set<PersistentIdentifier>()
        for species in catalogue {
            if species.inatTaxonID != nil { linkedSpecies.insert(species.persistentModelID) }
            let names = Set([species.commonName] + (species.altNames ?? []) + species.inatCommonNames.values.filter { !$0.isEmpty })
            speciesInfo[species.persistentModelID] = (species.id, species.displayName, species.scientificName,
                                                      species.category, names)
        }

        var byKey: [String: Accumulator] = [:]
        var divesWithSightings = Set<PersistentIdentifier>()
        let yieldInterval = 500
        for (idx, value) in values.enumerated() {
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return false }
            }
            // A linked species the catalogue does not show yet (added on another device, not
            // merged) is looked up by name, as an unlinked sighting is.
            let linked = value.speciesPID.flatMap { speciesInfo[$0] != nil ? $0 : nil }
            if let pid = linked ?? speciesByName[SpeciesCatalog.key(value.name)], let info = speciesInfo[pid] {
                let key = "s:\(info.id.uuidString)"
                var existing = byKey[key] ?? (info.name, info.scientific, info.category, pid, 0, [], nil, [:], [:], info.otherNames)
                existing.otherNames.insert(value.name)
                existing.entryCount += 1
                existing.qtyCounts[SightingQuantity.from(count: value.count), default: 0] += 1
                existing.dives.insert(value.diveID)
                existing.last = max(existing.last ?? value.timestamp, value.timestamp)
                byKey[key] = existing
            } else {
                let key = "n:\(value.name.lowercased())"
                var existing = byKey[key] ?? (value.name, nil, nil, nil, 0, [], nil, [:], [:], [])
                existing.entryCount += 1
                existing.qtyCounts[SightingQuantity.from(count: value.count), default: 0] += 1
                existing.dives.insert(value.diveID)
                existing.last = max(existing.last ?? value.timestamp, value.timestamp)
                let newCount = existing.casings[value.name, default: 0] + 1
                existing.casings[value.name] = newCount
                // Keep most-frequent casing as display name
                if newCount > (existing.casings[existing.name] ?? 0) {
                    existing.name = value.name
                }
                byKey[key] = existing
            }
            divesWithSightings.insert(value.divePID)
        }

        // Catalogue species not seen on any dive yet (shown when no diver is selected).
        if selectedDiver.isEmpty {
            for (pid, info) in speciesInfo where byKey["s:\(info.id.uuidString)"] == nil {
                byKey["s:\(info.id.uuidString)"] = (info.name, info.scientific, info.category, pid, 0, [], nil, [:], [:], info.otherNames)
            }
        }

        let aggregates: [SpeciesAggregate] = byKey.map { key, value in
            SpeciesAggregate(
                id: key,
                name: value.name,
                scientificName: value.scientific,
                category: value.category,
                speciesID: value.speciesID,
                entryCount: value.entryCount,
                diveCount: value.dives.count,
                lastSeen: value.last,
                diveIDs: value.dives,
                quantityCounts: value.qtyCounts,
                otherNames: value.otherNames.sorted(),
                isLinked: value.speciesID.map { linkedSpecies.contains($0) } ?? false
            )
        }
        .sorted {
            if $0.diveCount != $1.diveCount { return $0.diveCount > $1.diveCount }
            if $0.entryCount != $1.entryCount { return $0.entryCount > $1.entryCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if Task.isCancelled { return false }

        // Names not in the catalogue for the banner, in the dives shown (the selected diver's,
        // as "Add to Catalogue…" converts them), by the same species rule as above.
        var namesNotInCatalogue = Set<String>()
        for (idx, value) in values.enumerated() {
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return false }
            }
            let linked = value.speciesPID.flatMap { speciesInfo[$0] != nil ? $0 : nil }
            let name = SpeciesCatalog.key(value.name)
            if !name.isEmpty, (linked ?? speciesByName[name]) == nil { namesNotInCatalogue.insert(name) }
        }

        cachedNotInCatalogueCount = namesNotInCatalogue.count
        cachedSpecies = aggregates
        // Species actually seen: catalogue species never recorded on a dive are listed, not counted.
        cachedTotalSpecies = aggregates.filter { $0.entryCount > 0 }.count
        cachedTotalSightings = values.count
        cachedDivesWithLife = divesWithSightings.count
        statsReady = true
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if selectedDiverHasNoDive {
                    NoEntriesForDiverView(
                        title: DiverFilter.noDivesTitle(for: selectedDiver),
                        description: DiverFilter.noDivesDescription(for: selectedDiver)
                    )
                } else if !statsReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A List (not a ScrollView) so species rows get the system swipe to delete
                    // on every version, with touch, trackpad and mouse. The cards are drawn by
                    // the rows themselves: the statistics on a clear row, the species card as
                    // one slice per row, drawn by each row's content (see `speciesCardRow`).
                    List {
                        // Spacing as padding, not row insets: macOS ignores vertical row insets.
                        heroStatsRow
                            .padding(.bottom, 24)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        speciesListRows
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                    .contentMargins(.bottom, 30, for: .scrollContent)
                    .softTopScrollEdge()
                    .opacity(appeared ? 1.0 : 0.0)
                    .offset(y: appeared ? 0 : 20)
                }
            }
            // No title, as on the other tab roots (the tab bar names the tab).
            .navigationTitle("")
            .toolbar { toolbarContent }
            .background(AppBackground().ignoresSafeArea())
            .onChange(of: taxonFilter) { _, _ in rebuildTaxonSelection() }
            // Species deleted or merged (here or on another device): dropped from the caches
            // at once, before the statistics are recomputed.
            .onChange(of: catalogue.count) { _, _ in pruneDeletedSpecies() }
            .task(id: isShown ? statsKey : "") {
                // Back from a pushed page, or back to the tab, re-runs the task: nothing to do
                // when nothing changed.
                guard isShown, statsKey != computedStatsKey else { return }
                let firstPass = !statsReady
                rebuildCatalogueCaches()
                // The list stays on screen (and keeps its scroll position) while it refreshes;
                // only the first pass shows a spinner and fades the list in.
                guard await computeStats(), !Task.isCancelled else { return }
                computedStatsKey = statsKey
                if firstPass {
                    withAnimation(.easeOut(duration: 0.6)) {
                        appeared = true
                    }
                }
            }
            .diverFilterReset(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
            // The row's own data: the sheet stays filled when the statistics are recomputed while
            // it is open (e.g. its sightings are linked to a new species from a pushed dive).
            .sheet(item: $shownUnlinkedSpecies) { aggregate in
                unlinkedSightingsSheet(for: aggregate)
                    .standardSheetPresentation()
            }
            .sheet(item: $shownSpecies) { species in
                // "View Dives with This Critter" closes the sheet, then shows the dive list.
                SpeciesSheet(species: species, numberMap: cachedNumberMap, showDiveList: showDiveList)
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showAddSpecies) {
                EditSpeciesView(species: nil)
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showFilterSheet) {
                MarineLifeFilterSheet(
                    categories: usedCategories,
                    taxonNames: Self.filterRanks.map { (rank: $0, names: taxonNames(rank: $0)) },
                    groupCommonNames: cachedGroupCommonNames,
                    showsNotLinked: UserPreferences.shared.fetchTaxonomyOnline,
                    activeFilterCount: activeFilterCount,
                    categoryFilter: $categoryFilter,
                    taxonFilter: $taxonFilter,
                    notLinkedFilter: $notLinkedFilter,
                    reset: resetFilters
                )
                .standardSheetPresentation()
            }
            .sheet(isPresented: Binding(
                get: { !speciesProposals.isEmpty },
                set: { if !$0 { speciesProposals = [] } }
            )) {
                SpeciesPhotoReviewSheet(proposals: speciesProposals)
                    .standardSheetPresentation()
            }
            .alert("No New Species Found", isPresented: $showNoSpeciesInPhotos) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("No photo caption or keyword names a species that is not already linked to the photo.")
            }
            .alert("Build Catalogue from Sightings", isPresented: Binding(
                get: { buildPlan != nil },
                set: { if !$0 { buildPlan = nil } }
            ), presenting: buildPlan) { plan in
                if plan.sightingsToLink > 0 {
                    Button("Build") {
                        // The diver the plan was made for (the confirmed counts).
                        let result = SpeciesCatalog.buildFromSightings(in: modelContext, diverName: plan.diverName)
                        buildResult = (result.created, result.linked)
                        contentVersion += 1
                        // Species created under a scientific name are linked to iNaturalist
                        // in the background when lookups are on (one request per second).
                        INaturalistUpdater.updateInBackground(result.newSpecies, in: modelContext)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { plan in
                if plan.sightingsToLink == 0 {
                    Text("Every sighting is already in the catalogue.")
                } else {
                    Text(verbatim: String(format: NSLocalizedString("%@ sightings will be linked to catalogue species, and %@ new species will be created from their names. Sighting names are not changed.", bundle: .forAppLanguage(), value: "%@ sightings will be linked to catalogue species, and %@ new species will be created from their names. Sighting names are not changed.", comment: "Build catalogue confirmation: sightings to link, species to create (locale-formatted numbers)"), Double(plan.sightingsToLink).localizedString(decimals: 0), Double(plan.newSpeciesNames.count).localizedString(decimals: 0)))
                }
            }
            .alert("Delete Species", isPresented: Binding(
                get: { speciesToDelete != nil },
                set: { if !$0 { speciesToDelete = nil } }
            ), presenting: speciesToDelete) { species in
                Button("Delete", role: .destructive) {
                    // Deleted or merged meanwhile (here or on another device): nothing to do.
                    guard !species.isDeleted, species.modelContext != nil else { return }
                    SpeciesCatalog.delete(species, in: modelContext)
                }
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("The species is removed from the catalogue. Its sightings stay on their dives with the names they were recorded with, and its photos stay on their dives.")
            }
            .alert("Catalogue Built", isPresented: Binding(
                get: { buildResult != nil },
                set: { if !$0 { buildResult = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: String(format: NSLocalizedString("Species created: %@. Sightings linked: %@.", bundle: .forAppLanguage(), value: "Species created: %@. Sightings linked: %@.", comment: "Build catalogue result (locale-formatted numbers)"), Double(buildResult?.created ?? 0).localizedString(decimals: 0), Double(buildResult?.linked ?? 0).localizedString(decimals: 0)))
            }
        }
        // The tab's whole stack (pushed pages included): shown until another tab is selected.
        // Coming back recomputes only if something changed meanwhile (statsKey; DiveStore bumps
        // sightingsVersion for sightings added, removed or edited, here or on another device).
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)

        #if os(macOS)
        // One ToolbarItemGroup so macOS shares a single glass capsule, as the iOS
        // navigation bar does; separate items (especially menus) get separate capsules.
        ToolbarItemGroup(placement: .primaryAction) {
            addSpeciesButton
            filterButton
            catalogueMenu
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            addSpeciesButton
        }
        ToolbarItem(placement: .primaryAction) {
            filterButton
        }
        ToolbarItem(placement: .primaryAction) {
            catalogueMenu
        }
        #endif
    }

    // Toolbar controls, shared by the iOS and macOS toolbar layouts above.

    private var addSpeciesButton: some View {
        Button {
            showAddSpecies = true
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("Add Species"))
    }

    private var catalogueMenu: some View {
        Menu {
            Button {
                buildPlan = SpeciesCatalog.planBuild(in: modelContext, diverName: diverScope)
            } label: {
                Label("Build Catalogue from Sightings", systemImage: "books.vertical")
            }
            Button {
                let proposals = SpeciesPhotoMatcher.proposals(
                    for: photosWithIPTCInScope, catalogue: catalogue)
                if proposals.isEmpty { showNoSpeciesInPhotos = true } else { speciesProposals = proposals }
            } label: {
                Label("Find Species in Photos", systemImage: "text.viewfinder")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.cyan)
        }
        .toolbarMenuIndicatorHiddenOnMac()
        .accessibilityLabel(Text("More"))
    }

    /// Opens the filter sheet; orange with the number of active filters, as in the Dives and
    /// Map tabs.
    private var filterButton: some View {
        Button(action: { showFilterSheet = true }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(activeFilterCount > 0 ? .orange : .cyan)

                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(3)
                        .background(Color.orange, in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .accessibilityLabel(activeFilterCount == 0
            ? Text("Filter species")
            : Text(verbatim: String(format: NSLocalizedString("%d active filters", bundle: .forAppLanguage(), comment: "Accessibility label for the filter button showing the number of active filters"), activeFilterCount))
        )
    }

    /// Category, group and "not linked" filters in use.
    private var activeFilterCount: Int {
        (categoryFilter.isEmpty ? 0 : 1) + (taxonFilter.isEmpty ? 0 : 1) + (notLinkedFilterActive ? 1 : 0)
    }

    private func resetFilters() {
        categoryFilter = ""
        taxonFilter = ""
        notLinkedFilter = false
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 12) {
            StatisticsHeroCard(
                value: Double(cachedTotalSpecies).localizedString(decimals: 0),
                label: "Species",
                icon: "fish.fill",
                color: .orange
            )
            StatisticsHeroCard(
                value: Double(cachedTotalSightings).localizedString(decimals: 0),
                label: "Sightings",
                icon: "eye.fill",
                color: .cyan
            )
            StatisticsHeroCard(
                value: Double(cachedDivesWithLife).localizedString(decimals: 0),
                label: "Dives",
                icon: "figure.open.water.swim",
                color: .green
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Species List

    /// The species card as List rows: its top part (title, search, banners or an empty state),
    /// then one row per species, the last one closing the card.
    @ViewBuilder
    private var speciesListRows: some View {
        let filteredSpecies = filteredSpecies
        let showsRows = !cachedSpecies.isEmpty && !filteredSpecies.isEmpty
        speciesListHeader(filteredSpecies: filteredSpecies)
            .padding(.top, 16)
            .padding(.bottom, showsRows ? 14 : 16)
            .speciesCardRow(closesTop: true, closesBottom: !showsRows)

        if showsRows {
            ForEach(Array(filteredSpecies.enumerated()), id: \.element.id) { index, species in
                speciesListRow(index: index, species: species, isLast: index == filteredSpecies.count - 1)
            }
        }
    }

    /// One species row. Its sheet is built only when the row is opened (a catalogue species,
    /// or sightings not in the catalogue). Only a catalogue species can be swiped
    /// to delete (sightings not in the catalogue have no catalogue entry to delete).
    @ViewBuilder
    private func speciesListRow(index: Int, species: SpeciesAggregate, isLast: Bool) -> some View {
        let row = Button {
            if let id = species.speciesID {
                shownSpecies = liveSpecies(id)
            } else {
                shownUnlinkedSpecies = species
            }
        } label: {
            speciesRow(index: index, species: species)
                .overlay(alignment: .bottom) {
                    if !isLast {
                        Divider()
                            .background(Color.primary.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(.bottom, isLast ? 16 : 0)
        .speciesCardRow(closesTop: false, closesBottom: isLast)

        if let id = species.speciesID {
            row.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    speciesToDelete = liveSpecies(id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        } else {
            row
        }
    }

    private func speciesListHeader(filteredSpecies: [SpeciesAggregate]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("All Species")
                    .font(.headline)
                Spacer()
                if !cachedSpecies.isEmpty {
                    Text(verbatim: "\(Double(filteredSpecies.count).localizedString(decimals: 0))/\(Double(cachedSpecies.count).localizedString(decimals: 0))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if cachedSpecies.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fish")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No marine life recorded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    TextField(
                        NSLocalizedString(
                            "Search marine life…",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Placeholder for marine life search field"
                        ),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            withAnimation { searchText = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .clearButtonTapTarget()
                                .accessibilityLabel(Text("Clear"))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.platformBackground)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))

                if let (rank, name) = taxonFilterParts {
                    taxonFilterBanner(rank: rank, name: name)
                }

                // Names of sightings not in the catalogue (imported, or recorded before it), in
                // every diver's dives, as "Add to Catalogue…" converts them.
                if cachedNotInCatalogueCount > 0 {
                    notInCatalogueBanner(count: cachedNotInCatalogueCount)
                }

                if filteredSpecies.isEmpty {
                    VStack(spacing: 12) {
                        Text("No matches")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if activeFilterCount > 0 {
                            Button {
                                withAnimation { resetFilters() }
                            } label: {
                                Label("Clear filters", systemImage: "xmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.cyan)
                            }
                            // Explicit on iOS too: in a List row, default-style buttons make the
                            // whole row one tap target that fires them.
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                }
            }
        }
    }

    /// Names recorded on dives but not in the catalogue, with the action that adds them all
    /// ("Build Catalogue from Sightings", which confirms with its own counts first).
    private func notInCatalogueBanner(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            // Plural in the app language; the number grouped for the OS region.
            Text(verbatim: String.localizedStringWithFormat(NSLocalizedString("%lld names are not in the catalogue.", bundle: .forAppLanguage(), value: "%lld names are not in the catalogue.", comment: "Marine Life banner: number of sighting names recorded on dives that are not catalogue species"), count))
                .font(.subheadline)
            Spacer()
            Button("Add to Catalogue…") {
                buildPlan = SpeciesCatalog.planBuild(in: modelContext, diverName: diverScope)
            }
            .font(.caption.weight(.semibold))
            // Explicit on iOS too: the banner sits in a List row (see "Clear filters").
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }

    /// The active taxonomy filter, with the action that filters the dive log to it.
    private func taxonFilterBanner(rank: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: String(format: NSLocalizedString("%@: %@", bundle: .forAppLanguage(), value: "%@: %@", comment: "A taxonomic rank and its name, e.g. Family: Nephropidae"), INaturalistUpdater.localizedRank(rank), Species.groupLabel(name: name, commonName: cachedGroupCommonNames[name])))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("View Dives") {
                viewDivesInTaxon()
            }
            .font(.caption.weight(.semibold))
            // Explicit on iOS too: the banner sits in a List row (see "Clear filters").
            .buttonStyle(.borderless)
            Button {
                taxonFilter = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Clear"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
    }

    /// Filters the dive list to dives where a species of the selected taxon was recorded (by
    /// the names its sightings were recorded with, including unlinked ones under its names)
    /// and shows the dive list.
    private func viewDivesInTaxon() {
        let names = SpeciesCatalog.diveFilterNames(for: speciesInTaxon, in: modelContext)
        guard !names.isEmpty else { return }
        store.filterMarineLifeMode = .any
        store.filterMarineLife = names
        showDiveList?()
    }

    /// The sheet for sightings not in the catalogue, as a catalogue species opens in a sheet.
    private func unlinkedSightingsSheet(for aggregate: SpeciesAggregate) -> some View {
        UnlinkedSightingsSheet(
            name: aggregate.name,
            // By identifier (no dive read), then only dives still in the store.
            dives: aggregate.diveIDs.compactMap { store.diveByID[$0] }
                .filter { !$0.isDeleted && $0.modelContext != nil },
            numberMap: cachedNumberMap,
            onLinked: { contentVersion += 1 }
        )
    }

    // Builds "3× Abundant · 1× Few" with locale-formatted numbers, highest range first.
    private func quantitySummary(for species: SpeciesAggregate) -> String {
        SightingQuantity.allCases.reversed()
            .compactMap { q -> String? in
                guard let n = species.quantityCounts[q], n > 0 else { return nil }
                return "\(Double(n).localizedString(decimals: 0))× \(q.label)"
            }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func speciesRow(index: Int, species: SpeciesAggregate) -> some View {
        HStack(spacing: 14) {
            if let id = species.speciesID, let catalogued = liveSpecies(id),
               catalogued.hasFeaturedImage {
                SpeciesImageView(species: catalogued, size: 32)
            } else {
                ZStack {
                    Circle()
                        .fill(
                            index == 0
                                ? LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "fish.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: species.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let scientific = species.scientificName, !scientific.isEmpty {
                    Text(verbatim: scientific)
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if species.speciesID == nil {
                    Text("Not in the catalogue")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(verbatim: species.diveCount == 1
                        ? NSLocalizedString("1 dive", bundle: .forAppLanguage(), value: "1 dive", comment: "Single dive count")
                        : String(format: NSLocalizedString("%@ dives", bundle: .forAppLanguage(), value: "%@ dives", comment: "Plural dive count goal label"), Double(species.diveCount).localizedString(decimals: 0)))
                    if let last = species.lastSeen {
                        Text(verbatim: "·")
                        Text(last, format: .dateTime.month(.abbreviated).year().locale(locale))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                let summary = quantitySummary(for: species)
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(verbatim: Double(species.diveCount).localizedString(decimals: 0))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.orange.opacity(0.15)))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Unlinked Sightings

/// Sightings of a name not yet in the catalogue: the dives they were recorded on, and the
/// action to add the name to the catalogue (which links these sightings without renaming them).
struct UnlinkedSightingsView: View {
    let name: String
    let dives: [Dive]
    let numberMap: [PersistentIdentifier: Int]
    /// The sheet the page is shown in, if any (its dives' pages get its close button).
    @Environment(\.sheetDismiss) private var sheetDismiss
    /// Called after the sightings were linked to a species (the list must refresh).
    var onLinked: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var prefs = UserPreferences.shared
    @State private var showLinkSheet = false

    /// Re-checked on every redraw: the page stays open in the Marine Life tab, and a dive
    /// deleted on another device must never be read (it would crash).
    private var sortedDives: [Dive] {
        dives.filter { !$0.isDeleted && $0.modelContext != nil }.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("These sightings are not in the species catalogue yet. Add the name to the catalogue to give it a profile, photos and statistics; the sightings keep the name they were recorded with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let species = SpeciesCatalog.findOrCreate(named: name, in: modelContext)
                    SpeciesCatalog.linkSightings(named: name, to: species, in: modelContext)
                    onLinked()
                    dismiss()
                } label: {
                    Label("Add to Catalogue", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    showLinkSheet = true
                } label: {
                    Label("Link to an Existing Species…", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ForEach(sortedDives) { dive in
                    NavigationLink {
                        DiveDetailView(dive: dive, sortedDives: sortedDives, initialTab: .marineLife, diveNumber: numberMap[dive.persistentModelID] ?? 0)
                            .closeSheetButtonOnMac(sheetDismiss)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
                                    .font(.subheadline.weight(.semibold))
                                if !dive.siteName.isEmpty {
                                    Text(verbatim: dive.siteName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(verbatim: "\(dive.displayMaxDepth.localizedString(decimals: 1, minDecimals: 1)) \(prefs.depthUnit.symbol)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.cyan)
                                Text(dive.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformSecondaryBackground.opacity(0.6)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLinkSheet) {
            LinkSightingsToSpeciesSheet(name: name) {
                onLinked()
                dismiss()
            }
            .standardSheetPresentation()
        }
    }
}

// MARK: - Marine Life Filter Sheet

/// The Marine Life tab's filters, laid out like the Dives tab's filter sheet (cards of
/// chips, a reset button at the top).
struct MarineLifeFilterSheet: View {
    /// Categories used in the catalogue.
    let categories: [String]
    /// Group names per rank ("class", "order", "family", "genus"), in display order.
    let taxonNames: [(rank: String, names: [String])]
    let groupCommonNames: [String: String]
    /// The "not linked" filter is offered only while iNaturalist lookups are on.
    let showsNotLinked: Bool
    let activeFilterCount: Int

    @Binding var categoryFilter: String
    @Binding var taxonFilter: String
    @Binding var notLinkedFilter: Bool
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The categories offered, plus the selected one if no species uses it any more, so a
    /// filter left on an unused value can still be seen and cleared.
    private var categoryChoices: [String] {
        categoryFilter.isEmpty || categories.contains(categoryFilter) ? categories : categories + [categoryFilter]
    }

    /// The groups offered per rank, plus the selected one if no species is in it any more.
    private var taxonChoices: [(rank: String, names: [String])] {
        let parts = taxonFilter.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return taxonNames.filter { !$0.names.isEmpty } }
        var choices = taxonNames
        if let index = choices.firstIndex(where: { $0.rank == parts[0] }) {
            if !choices[index].names.contains(parts[1]) { choices[index].names.append(parts[1]) }
        } else {
            choices.append((parts[0], [parts[1]]))
        }
        return choices.filter { !$0.names.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    resetSection
                    if showsNotLinked {
                        notLinkedSection
                    }
                    if !categoryChoices.isEmpty {
                        categorySection
                    }
                    if !taxonChoices.isEmpty {
                        groupSection
                    }
                    // Unlike the Dives sheet, no card is always shown: explain how to get some.
                    if !showsNotLinked && categoryChoices.isEmpty && taxonChoices.isEmpty {
                        ContentUnavailableView(
                            "No filters available",
                            systemImage: "line.3.horizontal.decrease",
                            description: Text("Give species a category, or link them to iNaturalist, to filter them here.")
                        )
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(NSLocalizedString("Filters", bundle: Bundle.forAppLanguage(), comment: "Title of the filter sheet without sort"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var notLinkedSection: some View {
        Toggle(isOn: $notLinkedFilter.animation()) {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Not Linked to iNaturalist")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 4)
        }
        .fullWidthSwitch()
        .filterCardStyle()
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Category", icon: "square.grid.2x2")

            chipRow {
                ModernFilterChip(
                    label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                    isSelected: categoryFilter.isEmpty,
                    color: .orange
                ) {
                    withAnimation { categoryFilter = "" }
                }

                ForEach(categoryChoices, id: \.self) { category in
                    ModernFilterChip(
                        label: SpeciesCategory.displayName(category) ?? category,
                        isSelected: categoryFilter == category,
                        color: .orange
                    ) {
                        withAnimation { categoryFilter = category }
                    }
                }
            }
        }
        .filterCardStyle()
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Group", icon: "leaf")

            chipRow {
                ModernFilterChip(
                    label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                    isSelected: taxonFilter.isEmpty,
                    color: .green
                ) {
                    withAnimation { taxonFilter = "" }
                }
            }

            ForEach(taxonChoices, id: \.rank) { rank, names in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: INaturalistUpdater.localizedRank(rank))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    chipRow {
                        ForEach(names, id: \.self) { name in
                            let tag = "\(rank)|\(name)"
                            ModernFilterChip(
                                label: Species.groupLabel(name: name, commonName: groupCommonNames[name]),
                                isSelected: taxonFilter == tag,
                                color: .green
                            ) {
                                withAnimation { taxonFilter = tag }
                            }
                        }
                    }
                }
            }
        }
        .filterCardStyle()
    }

    private var resetSection: some View {
        Group {
            if activeFilterCount > 0 {
                Button(role: .destructive) {
                    withAnimation { reset() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title3)
                        Text(verbatim: resetButtonLabel)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }

    private var resetButtonLabel: String {
        activeFilterCount == 1
            ? NSLocalizedString("Reset 1 filter", bundle: Bundle.forAppLanguage(), comment: "Reset button label when exactly one filter is active.")
            : String(format: NSLocalizedString("Reset %lld filters", bundle: Bundle.forAppLanguage(), comment: "Reset button label showing the number of active filters (plural)."), activeFilterCount)
    }

    /// A row of filter chips, as in the Dives filter sheet. iOS: one line that scrolls
    /// sideways, with an edge fade. macOS: the chips wrap onto as many lines as needed.
    @ViewBuilder
    private func chipRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        WrappingChipLayout(spacing: 12) {
            content()
        }
        .padding(.horizontal, 4)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 4)
        }
        .chipRowFade()
        #endif
    }
}

/// Sightings not in the catalogue in a sheet, as `SpeciesSheet` shows a catalogue species. The
/// page is the sheet's first page, so its own dismiss (after "Add to Catalogue" or a link)
/// closes the sheet.
struct UnlinkedSightingsSheet: View {
    let name: String
    let dives: [Dive]
    let numberMap: [PersistentIdentifier: Int]
    var onLinked: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UnlinkedSightingsView(name: name, dives: dives, numberMap: numberMap, onLinked: onLinked)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        closeToolbarButton { dismiss() }
                    }
                }
                #endif
                // macOS: the close button (and Escape), and `\.sheetDismiss`, so the dives
                // the page opens get the button too.
                .closeSheetButtonOnMac { dismiss() }
        }
    }
}

private extension View {
    /// iOS 26 / macOS 26: the soft (blurred) scroll edge under the toolbar, as on the other
    /// tabs. The system picks the hard (nearly opaque) edge for a plain-style List. No scroll
    /// edge effect exists before, so the view is returned unchanged.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// A List row that is one slice of the Marine Life species card: inset 16 pt from the
    /// edges like the statistics (content 16 pt further in), no list separator, and a
    /// background rounded only where the slice opens or closes the card. The slice is drawn
    /// by the row's content, not `listRowBackground`: on macOS the row background is wider
    /// than the content (the list adds its own content inset), so the card would not line
    /// up with the statistics.
    func speciesCardRow(closesTop: Bool, closesBottom: Bool) -> some View {
        let top: CGFloat = closesTop ? 20 : 0
        let bottom: CGFloat = closesBottom ? 20 : 0
        return self
            .padding(.horizontal, 16)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: top,
                    bottomLeadingRadius: bottom,
                    bottomTrailingRadius: bottom,
                    topTrailingRadius: top
                )
                .fill(Color.platformSecondaryBackground)
            )
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    MarineLifeView()
        .modelContainer(for: Dive.self, inMemory: true)
}
