enum ModuleSection {
    case type(TypeSectionReader)
    case `import`(ImportSectionReader)
    case function(FunctionSectionReader)
    case element(ElementSectionReader)
    case rawSection(type: SectionType, content: ArraySlice<UInt8>)
}

struct ModuleReader {
    enum Error: Swift.Error {
        case invlaidMagic
    }
    var input: InputByteStream

    mutating func readHeader() throws -> ArraySlice<UInt8> {
        return try input.readHeader()
    }
    mutating func readSection() throws -> ModuleSection {
        let sectionInfo = try input.readSectionInfo()
        switch sectionInfo.type {
        case .type:
            return .type(TypeSectionReader(input: input))
        case .import:
            return .import(ImportSectionReader(input: input))
        case .function:
            return .function(FunctionSectionReader(input: input))
        case .elem:
            return .element(ElementSectionReader(input: input))
        default:
            return .rawSection(
                type: sectionInfo.type,
                content: input.bytes[sectionInfo.contentRange]
            )
        }
    }
}