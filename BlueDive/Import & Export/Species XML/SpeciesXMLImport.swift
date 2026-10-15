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
        var created: [Species] = []
        var linked = 0
        // The sightings not in the catalogue, read once and grouped by name (ignoring case),
        // rather than one query per name of every new species. A group is taken by the first
        // species that has its name, as `SpeciesCatalog.unlinkedSightings(of:)` would find it.
        let unlinked = (try? context.fetch(FetchDescriptor<MarineSight>(predicate: #Predicate { $0.species == nil }))) ?? []
        var unlinkedByKey = Dictionary(grouping: unlinked) { SpeciesCatalog.key($0.name) }
        unlinkedByKey[""] = nil
        for item in plan(parsed, in: context).new {
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
            for key in Set(item.names.map(SpeciesCatalog.key)) {
                guard let sights = unlinkedByKey.removeValue(forKey: key) else { continue }
                for sight in sights { sight.species = species }
                linked += sights.count
            }
            created.append(species)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return (created, linked)
    }
}
