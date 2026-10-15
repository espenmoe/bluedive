import Foundation

// MARK: - SpeciesXMLExporter

/// Generates a BlueDive XML document for the marine-life catalogue.
/// Follows the same pattern as GearXMLExporter; read back by `SpeciesXMLParser`.
///
/// Every value is written as stored: an optional field that is nil is omitted (so an empty
/// string and no value stay distinct), the category is written as its stored key or custom
/// name, and the iNaturalist JSON fields are written as their JSON text. Sightings and
/// photos are not exported (statistics are calculated from the dives).
enum SpeciesXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing `species`, wrapped in a single
    /// `<blueDiveSpeciesExport>` root element. With `includeImages`, each species' featured
    /// image (and its thumbnail and attribution) is embedded as base64.
    @MainActor
    static func generateXML(for species: [Species], includeImages: Bool) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveSpeciesExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",      appName,                          indent: 4))
        lines.append(xmlTag("version",       "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt",    formatDate(Date()),               indent: 4))
        lines.append(xmlTag("speciesCount",  String(species.count),            indent: 4))
        lines.append(xmlTag("includesImages", includeImages ? "true" : "false", indent: 4))
        lines.append("  </metadata>")

        // ── Species ──────────────────────────────────────────────────────────
        lines.append("  <speciesList>")
        for item in species {
            lines.append(contentsOf: speciesLines(for: item, includeImages: includeImages))
        }
        lines.append("  </speciesList>")

        lines.append("</blueDiveSpeciesExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Species Block

    @MainActor
    private static func speciesLines(for species: Species, includeImages: Bool) -> [String] {
        var lines: [String] = []
        lines.append("    <species>")
        lines.append(xmlTag("id",        species.id.uuidString,         indent: 6))
        lines.append(xmlTag("createdAt", formatDate(species.createdAt), indent: 6))
        lines.append(xmlTag("commonName", species.commonName,           indent: 6))
        appendOptional("scientificName",  species.scientificName,                    to: &lines)
        appendOptional("category",        species.category,                          to: &lines)
        appendOptional("averageSize",     species.averageSize.map { String($0) },    to: &lines)
        appendOptional("averageSizeUnit", species.averageSizeUnit,                   to: &lines)
        appendOptional("notes",           species.notes,                             to: &lines)
        if let altNames = species.altNames {
            lines.append("      <altNames>")
            for name in altNames {
                lines.append(xmlTag("altName", name, indent: 8))
            }
            lines.append("      </altNames>")
        }
        appendOptional("inatTaxonID",      species.inatTaxonID.map { String($0) },   to: &lines)
        appendOptional("inatCommonNames",  species.inatCommonNamesData.map(jsonText), to: &lines)
        appendOptional("taxonomy",         species.taxonomyData.map(jsonText),        to: &lines)
        appendOptional("wikipediaSummary", species.wikipediaSummary,                 to: &lines)
        appendOptional("wikipediaURL",     species.wikipediaURL,                     to: &lines)
        appendOptional("inatFetchedAt",    species.inatFetchedAt.map(formatDate),    to: &lines)

        if includeImages, let image = species.image, let imageData = image.imageData {
            lines.append("      <featuredImage>")
            lines.append(xmlTag("imageData", imageData.base64EncodedString(), indent: 8))
            if let thumbnail = image.thumbnailData {
                lines.append(xmlTag("thumbnailData", thumbnail.base64EncodedString(), indent: 8))
            }
            if let attribution = image.attribution {
                lines.append(xmlTag("attribution", attribution, indent: 8))
            }
            lines.append("      </featuredImage>")
        }

        lines.append("    </species>")
        return lines
    }

    // MARK: - XML Helpers

    private static func appendOptional(_ name: String, _ value: String?, to lines: inout [String]) {
        guard let value else { return }
        lines.append(xmlTag(name, value, indent: 6))
    }

    /// The stored JSON as text (JSON is UTF-8), read back byte for byte by the parser.
    private static func jsonText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func xmlTag(_ name: String, _ value: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return "\(pad)<\(name)>\(xmlEscape(value))</\(name)>"
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
            // A carriage return would be read back as a line feed (XML end-of-line handling).
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
