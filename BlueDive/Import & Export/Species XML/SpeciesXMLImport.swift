import Foundation
import SwiftData

// MARK: - SpeciesXMLImport

/// Adds the species of a parsed `SpeciesXMLParser` file to the catalogue. A species already in
/// the catalogue — same id, or one of its names (common, scientific, other or iNaturalist)
/// known to the catalogue, ignoring case — is skipped and never overwritten. Within the file,
/// every entry with an id is its own species, even when it shares a name with another (a
/// catalogue can hold such species, e.g. created on two devices before they synced): a later
/// entry is skipped only for the id of an earlier one, or, without an id, for one of its names.
@MainActor
enum SpeciesXMLImport {

    typealias ParsedSpecies = SpeciesXMLParser.ParsedSpecies

    struct Plan {
        var new: [ParsedSpecies] = []
        var duplicates: [ParsedSpecies] = []
    }

    /// Splits `parsed` into the species to add and the duplicates, against the catalogue as
    /// saved in `context` now.
    static func plan(_ parsed: [ParsedSpecies], in context: ModelContext) -> Plan {
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        let index = SpeciesNameIndex(catalogue: catalogue)
        var knownIDs = Set(catalogue.map(\.id))
        var fileKeys = Set<String>()
        var plan = Plan()
        for item in parsed {
            let keys = Set(item.names.map(SpeciesCatalog.key)).subtracting([""])
            let inCatalogue = item.names.contains { index.otherSpecies(named: $0, excluding: nil) != nil }
            let earlierInFile = item.id.map { knownIDs.contains($0) } ?? keys.contains { fileKeys.contains($0) }
            let isDuplicate = inCatalogue || earlierInFile
            if isDuplicate {
                plan.duplicates.append(item)
            } else {
                plan.new.append(item)
                if let id = item.id { knownIDs.insert(id) }
                fileKeys.formUnion(keys)
            }
        }
        return plan
    }

    /// Inserts the species of `parsed` that are not duplicates (decided again now: the
    /// catalogue may have changed since the preview, e.g. through iCloud), with their values as
    /// in the file, and links to each the sightings not yet in the catalogue recorded under one
    /// of its names (the sightings keep their names). Saved; when the save fails, every change
    /// is rolled back and the error is thrown.
    /// Returns the species created and the number of sightings linked.
    static func commit(_ parsed: [ParsedSpecies], in context: ModelContext) throws -> (created: [Species], linked: Int) {
        let created = plan(parsed, in: context).new.map { (species: makeSpecies(from: $0, in: context), names: $0.names) }
        let linked = linkUnlinkedSightings(to: created, in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return (created.map(\.species), linked)
    }

    /// A new species with the values of `item` as in the file (its id and creation date
    /// included), inserted in `context`. Not saved.
    static func makeSpecies(from item: ParsedSpecies, in context: ModelContext) -> Species {
        let species = Species(commonName: item.commonName)
        if let id = item.id { species.id = id }
        if let createdAt = item.createdAt { species.createdAt = createdAt }
        species.scientificName = item.scientificName
        species.category = item.category
        species.averageSize = item.averageSize
        species.averageSizeUnit = item.averageSizeUnit
        species.notes = item.notes
        species.altNames = item.altNames
        species.inatTaxonID = item.inatTaxonID
        species.inatCommonNamesData = item.inatCommonNamesData
        species.taxonomyData = item.taxonomyData
        species.wikipediaSummary = item.wikipediaSummary
        species.wikipediaURL = item.wikipediaURL
        species.inatFetchedAt = item.inatFetchedAt
        context.insert(species)
        if let imageData = item.imageData {
            species.setFeaturedImage(imageData, thumbnail: item.thumbnailData, attribution: item.imageAttribution)
        }
        return species
    }

    /// Links the sightings not in the catalogue to the species just created that have their
    /// name (ignoring case), in order: a name taken by an earlier species is not linked again,
    /// as `SpeciesCatalog.unlinkedSightings(of:)` would find it. The sightings are read once and
    /// grouped by name, rather than one query per name. The sightings keep their names. Not saved.
    /// Returns the number of sightings linked.
    static func linkUnlinkedSightings(to created: [(species: Species, names: [String])], in context: ModelContext) -> Int {
        guard !created.isEmpty else { return 0 }
        let unlinked = (try? context.fetch(FetchDescriptor<MarineSight>(predicate: #Predicate { $0.species == nil }))) ?? []
        var unlinkedByKey = Dictionary(grouping: unlinked) { SpeciesCatalog.key($0.name) }
        unlinkedByKey[""] = nil
        var linked = 0
        for (species, names) in created {
            for key in Set(names.map(SpeciesCatalog.key)) {
                guard let sights = unlinkedByKey.removeValue(forKey: key) else { continue }
                for sight in sights { sight.species = species }
                linked += sights.count
            }
        }
        return linked
    }
}

// MARK: - Species carried by a dive file

/// Resolves the species a BlueDive dive file carries for its sightings (`<speciesCatalogue>`)
/// during a dive import, with the catalogue import's rules: the species with the same id, else
/// the one known by one of its names (common, scientific, other or iNaturalist), else a new
/// species created once from the file's values (BlueDive's own complete records) — unless
/// creation is off (Import Species turned off), when the sighting stays out of the catalogue.
/// An existing species is never changed. Other formats carry no species: their sightings are
/// linked by name to existing species only (`existingSpecies(named:)`).
@MainActor
final class SpeciesImportResolver {
    private let context: ModelContext
    private let allowsCreation: Bool
    private let index: SpeciesNameIndex
    private var byID: [UUID: Species]
    /// Species created without an id in the file (hand-made files), by common name.
    private var createdByKey: [String: Species] = [:]
    /// The species created by this import, with their names in the file.
    private(set) var created: [(species: Species, names: [String])] = []

    /// Indexes the catalogue as saved in `context` now. With `allowsCreation` off, a species the
    /// catalogue does not have is not created.
    init(context: ModelContext, allowsCreation: Bool = true) {
        self.context = context
        self.allowsCreation = allowsCreation
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        index = SpeciesNameIndex(catalogue: catalogue)
        byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalogue species for a sighting carrying `item` (created when the catalogue has
    /// none and creation is on; nil otherwise). Not saved.
    func species(for item: SpeciesXMLImport.ParsedSpecies) -> Species? {
        if let id = item.id, let existing = byID[id], isAlive(existing) { return existing }
        for name in item.names {
            if let existing = index.otherSpecies(named: name, excluding: nil), isAlive(existing) { return existing }
        }
        guard allowsCreation else { return nil }
        let key = SpeciesCatalog.key(item.commonName)
        if item.id == nil, let existing = createdByKey[key] { return existing }
        let species = SpeciesXMLImport.makeSpecies(from: item, in: context)
        if let id = item.id { byID[id] = species } else { createdByKey[key] = species }
        created.append((species, item.names))
        return species
    }

    /// The existing species known by `name`, ignoring case (a sighting without species data).
    func existingSpecies(named name: String) -> Species? {
        index.species(named: name).flatMap { isAlive($0) ? $0 : nil }
    }

    /// Links the sightings not in the catalogue to the species this import created that have
    /// their name. Not saved. Returns the number of sightings linked.
    func linkUnlinkedSightings() -> Int {
        SpeciesXMLImport.linkUnlinkedSightings(to: created, in: context)
    }

    /// Not deleted, here or on another device, since the catalogue was indexed.
    private func isAlive(_ species: Species) -> Bool {
        !species.isDeleted && species.modelContext != nil
    }
}
