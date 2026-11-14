import Foundation

/// One page's objects (shapes, text, images, tape: see `PageObject`) as a JSON file, `pages/<page id>.json`,
/// beside the page's `.ink` file. A page without objects has no file, so every note written before objects
/// existed opens unchanged.
///
/// ```json
/// { "formatVersion": 1, "pageID": "…", "objects": [ { "kind": "placeholder", "id": "…", … } ] }
/// ```
///
/// - **Versions.** `formatVersion` is 1. A reader refuses a file with a higher version
///   (`PageObjectsFileError.unsupportedVersion`), so an older app never half-reads a format it doesn't know;
///   new kinds of object don't need a new version, since unknown kinds are kept.
/// - **Unknown kinds** (from a newer app) are kept as they were read, in their place in the stacking order,
///   and written back unchanged. They aren't drawn or selectable.
/// - **Damaged objects.** An object whose shared keys are missing or out of range is `corrupt`, and so is
///   the file: like a damaged `.ink` file, it's set aside by the app rather than overwritten.
/// - Objects are written in stacking order (`zIndex`, then file order) with sorted keys, so the same page
///   always writes the same bytes.
public struct PageObjectsFile: Sendable {
    /// The version this build writes, and the highest it reads.
    public static let currentFormatVersion = 1
    public static let fileExtension = "json"

    /// The id of the page the objects are on (`CanvasDocument.id`).
    public var pageID: UUID
    /// The version the file was written with (`currentFormatVersion` for one built in memory).
    public private(set) var formatVersion: Int
    /// The page's objects, lowest `zIndex` first.
    public var objects: [any PageObject]

    public init(pageID: UUID, objects: [any PageObject] = []) {
        self.pageID = pageID
        self.objects = Self.stacked(objects)
        formatVersion = Self.currentFormatVersion
    }

    public var isEmpty: Bool {
        objects.isEmpty
    }

    /// Reads a page's objects file. Throws a `PageObjectsFileError` for anything that isn't a well-formed
    /// file this version can read.
    public init(data: Data) throws {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw PageObjectsFileError.notAnObjectsFile
        }
        guard header.formatVersion >= 1 else { throw PageObjectsFileError.notAnObjectsFile }
        guard header.formatVersion <= Self.currentFormatVersion else {
            throw PageObjectsFileError.unsupportedVersion(header.formatVersion)
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw PageObjectsFileError.corrupt(String(describing: error))
        }
        var seen = Set<UUID>()
        for object in body.objects.objects where !seen.insert(object.id).inserted {
            throw PageObjectsFileError.corrupt("object \(object.id) appears twice")
        }
        pageID = body.pageID
        formatVersion = header.formatVersion
        objects = Self.stacked(body.objects.objects)
    }

    /// The file as JSON at `currentFormatVersion`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(pageID: pageID, objects: AnyObjects(objects: objects)))
    }

    /// Objects in stacking order; equal `zIndex`es keep their order.
    static func stacked(_ objects: [any PageObject]) -> [any PageObject] {
        objects.enumerated().sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }.map(\.element)
    }

    /// Copies of `objects` with new ids and everything else the same, for pasting and duplicating. They go
    /// through the file format, so every kind of object is copied the same way without having to know how.
    static func copies(of objects: [any PageObject]) throws -> [any PageObject] {
        guard !objects.isEmpty else { return [] }
        let data = try PageObjectsFile(pageID: UUID(), objects: objects).encoded()
        guard case var .object(body) = try JSONDecoder().decode(JSONValue.self, from: data),
              case let .array(items)? = body["objects"] else { throw PageObjectsFileError.notAnObjectsFile }
        body["objects"] = .array(items.map { item in
            guard case var .object(fields) = item else { return item }
            fields[PageObjectPlacement.CodingKeys.id.rawValue] = .string(UUID().uuidString)
            return .object(fields)
        })
        return try PageObjectsFile(data: JSONEncoder().encode(JSONValue.object(body))).objects
    }

    // MARK: Coding

    private struct Header: Decodable {
        var formatVersion: Int
    }

    private struct Body: Codable {
        var formatVersion = PageObjectsFile.currentFormatVersion
        var pageID: UUID
        var objects: AnyObjects
    }

    /// The `objects` array: each element is decoded as the type its `kind` names.
    private struct AnyObjects: Codable {
        var objects: [any PageObject]

        init(objects: [any PageObject]) {
            self.objects = objects
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var objects: [any PageObject] = []
            while !c.isAtEnd {
                try objects.append(c.decode(PageObjectElement.self).object)
            }
            self.objects = objects
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            for object in objects {
                let element = c.superEncoder()
                if !(object is UnknownPageObject) {
                    var keyed = element.container(keyedBy: PageObjectKindKey.self)
                    try keyed.encode(object.kind, forKey: .kind)
                }
                try object.encode(to: element)
            }
        }
    }
}

private enum PageObjectKindKey: String, CodingKey {
    case kind
}

/// One element of a file's `objects` array, decoded as the type its `kind` names.
private struct PageObjectElement: Decodable {
    let object: any PageObject

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: PageObjectKindKey.self).decode(String.self, forKey: .kind)
        let type = PageObjectKinds.known[kind] ?? UnknownPageObject.self
        object = try type.init(from: decoder)
    }
}

public enum PageObjectsFileError: Error, Equatable, Sendable {
    /// Not JSON, or no `formatVersion`.
    case notAnObjectsFile
    /// Written with a newer format version than this app reads.
    case unsupportedVersion(Int)
    /// Valid JSON that isn't a page's objects: a missing key, a value out of range, a repeated id.
    case corrupt(String)
}
