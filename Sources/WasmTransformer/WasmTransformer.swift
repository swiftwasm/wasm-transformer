typealias RawSection = (
    startOffset: Int, endOffset: Int
)


public class InMemoryOutputWriter: OutputWriter {
    private(set) var _bytes: [UInt8] = []
    
    public init(reservingCapacity capacity: Int = 0) {
        _bytes.reserveCapacity(capacity)
    }

    public func writeByte(_ byte: UInt8) throws {
        _bytes.append(byte)
    }
    
    public func writeBytes<S>(_ newBytes: S) throws where S : Sequence, S.Element == UInt8 {
        _bytes.append(contentsOf: newBytes)
    }

    public func bytes() -> [UInt8] { _bytes }
}

struct TypeSection {
    private(set) var signatures: [FuncSignature] = []

    func write<Writer: OutputWriter>(to writer: Writer) throws {
        try writeSection(.type, writer: writer) { buffer in
            try buffer.writeBytes(encodeULEB128(UInt32(signatures.count)))
            for signature in signatures {
                try buffer.writeByte(0x60)
                try writeResultTypes(signature.params, to: buffer)
                try writeResultTypes(signature.results, to: buffer)
            }
        }
    }
    
    mutating func append(signature: FuncSignature) {
        signatures.append(signature)
    }

    /// https://webassembly.github.io/spec/core/binary/types.html#result-types
    func writeResultTypes(_ types: [ValueType], to writer: OutputWriter) throws {
        try writer.writeBytes(encodeULEB128(UInt32(types.count)))
        for type in types {
            try writer.writeByte(type.rawValue)
        }
    }
}

typealias ImportFuncReplacement = (index: Int, toTypeIndex: Int)

struct ImportSection {
    var input: InputStream
    var replacements: [ImportFuncReplacement] = []

    mutating func write<Writer: OutputWriter>(to writer: Writer) throws {
        let sectionType = input.readUInt8()
        assert(SectionType(rawValue: sectionType) == .import)
        try writer.writeByte(sectionType)

        let oldContentSize = input.readVarUInt32()
        var contentBuffer: [UInt8] = []
        contentBuffer.reserveCapacity(Int(oldContentSize))

        let count = input.readVarUInt32()
        contentBuffer.append(contentsOf: encodeULEB128(count))
        for index in 0 ..< count {
            input.consumeString(consumer: { contentBuffer.append(contentsOf: $0) }) // module name
            input.consumeString(consumer: { contentBuffer.append(contentsOf: $0) }) // field name
            let rawKind = input.readUInt8()
            contentBuffer.append(rawKind)
            let kind = ExternalKind(rawValue: rawKind)

            switch kind {
            case .func:
                let oldSignatureIndex = input.readVarUInt32()
                let newSignatureIndex: UInt32
                if let replacement = replacements.first(where: { $0.index == index }) {
                    newSignatureIndex = UInt32(replacement.toTypeIndex)
                } else {
                    newSignatureIndex = oldSignatureIndex
                }
                contentBuffer.append(contentsOf: encodeULEB128(newSignatureIndex))
            case .table: input.consumeTable(consumer: { contentBuffer.append(contentsOf: $0) })
            case .memory: input.consumeMemory(consumer: { contentBuffer.append(contentsOf: $0) })
            case .global: input.consumeGlobalHeader(consumer: { contentBuffer.append(contentsOf: $0) })
            case .except:
                fatalError("not supported yet")
            case .none:
                fatalError()
            }
        }
        
        try writer.writeBytes(encodeULEB128(UInt32(contentBuffer.count)))
        try writer.writeBytes(contentBuffer)
    }
}

struct Trampoline {
    let fromSignature: FuncSignature
    let toSignature: FuncSignature
    let fromSignatureIndex: Int
    let originalFuncIndex: Int

    func write(to writer: OutputWriter) throws {
        var bodyBuffer: [UInt8] = []
        bodyBuffer.append(0x00) // local decl count

        for (index, param) in fromSignature.params.enumerated() {
            bodyBuffer.append(contentsOf: Opcode.localGet(UInt32(index)).bytes())
            if param == .i64 {
                bodyBuffer.append(contentsOf: Opcode.i32WrapI64.bytes())
            }
        }

        bodyBuffer.append(contentsOf: Opcode.call(UInt32(originalFuncIndex)).bytes())
        bodyBuffer.append(contentsOf: Opcode.end.bytes())

        try writer.writeBytes(encodeULEB128(UInt32(bodyBuffer.count)))
        try writer.writeBytes(bodyBuffer)
    }
}

struct Trampolines: Sequence {
    private var trampolineByBaseFuncIndex: [Int: (Trampoline, index: Int)] = [:]
    private var trampolines: [Trampoline] = []
    var count: Int { trampolineByBaseFuncIndex.count }

    mutating func add(importIndex: Int, from: FuncSignature, fromIndex: Int, to: FuncSignature) {
        let trampoline = Trampoline(fromSignature: from,
                                    toSignature: to, fromSignatureIndex: fromIndex,
                                    originalFuncIndex: importIndex)
        trampolineByBaseFuncIndex[importIndex] = (trampoline, trampolines.count)
        trampolines.append(trampoline)
    }

    func trampoline(byBaseFuncIndex index: Int) -> (Trampoline, Int)? {
        trampolineByBaseFuncIndex[index]
    }

    typealias Iterator = Array<Trampoline>.Iterator
    func makeIterator() -> Iterator {
        trampolines.makeIterator()
    }
}

struct FunctionSection {
    var input: InputStream
}

public protocol OutputWriter {
    func writeByte(_ byte: UInt8) throws
    func writeBytes<S: Sequence>(_ bytes: S) throws where S.Element == UInt8
}

public struct I64Transformer {
    enum Error: Swift.Error {
        case invalidExternalKind(UInt8)
        case expectTypeSection
        case expectFunctionSection
        case expectEnd
        case unexpectedSection(UInt8)
    }
    
    public init() {}

    public func transform<Writer: OutputWriter>(_ input: inout InputStream, writer: Writer) throws {
        let maybeMagic = input.read(4)
        assert(maybeMagic.elementsEqual(magic))
        try writer.writeBytes(magic)
        let maybeVersion = input.read(4)
        assert(maybeVersion.elementsEqual(version))
        try writer.writeBytes(version)

        var importedFunctionCount = 0
        var trampolines = Trampolines()
        do {
            // Phase 1. Scan Type and Import sections to determine import records
            //          which will be lowered.
            var rawSections: [RawSection] = []
            var typeSection = TypeSection()
            var importSection: ImportSection?
            Phase1: while !input.isEOF {
                let offset = input.offset
                let type = input.readUInt8()
                let size = Int(input.readVarUInt32())
                let contentStart = input.offset
                let sectionType = SectionType(rawValue: type)

                switch sectionType {
                case .type:
                    try scan(typeSection: &typeSection, from: &input)
                case .import:
                    let partialStart = input.bytes.startIndex + offset
                    let partialEnd = contentStart + size
                    let partialBytes = input.bytes[partialStart ..< partialEnd]
                    var section = ImportSection(input: InputStream(bytes: partialBytes))
                    importedFunctionCount = try scan(
                        importSection: &section, from: &input,
                        typeSection: &typeSection, trampolines: &trampolines
                    )
                    importSection = section
                    break Phase1
                case .custom:
                    rawSections.append((startOffset: offset, endOffset: contentStart + size))
                    input.read(size)
                default:
                    throw Error.unexpectedSection(type)
                }
                assert(input.offset == contentStart + size)
            }

            // Phase 2. Write out Type and Import section based on scanned results.
            try typeSection.write(to: writer)
            if var importSection = importSection {
                try importSection.write(to: writer)
            }

            for rawSection in rawSections {
                try writer.writeBytes(input.bytes[rawSection.startOffset ..< rawSection.endOffset])
            }
        }

        var originalFuncCount: Int?
        while !input.isEOF {
            let offset = input.offset
            let type = input.readUInt8()
            let size = Int(input.readVarUInt32())
            let contentStart = input.offset
            let sectionType = SectionType(rawValue: type)

            switch sectionType {
            case .type, .import:
                fatalError("unreachable")
            case .function:
                // Phase 3. Write out Func section and add trampoline signatures.
                originalFuncCount = try transformFunctionSection(input: &input, writer: writer, trampolines: trampolines) + importedFunctionCount
            case .elem:
                // Phase 4. Read Elem section and rewrite i64 functions with trampoline functions.
                guard let originalFuncCount = originalFuncCount else {
                    throw Error.expectFunctionSection
                }
                try transformElemSection(
                    input: &input, writer: writer,
                    trampolines: trampolines, originalFuncCount: originalFuncCount
                )
            case .code:
                // Phase 5. Read Code section and rewrite i64 function calls with trampoline function call.
                //          And add trampoline functions at the tail
                guard let originalFuncCount = originalFuncCount else {
                    throw Error.expectFunctionSection
                }
                try transformCodeSection(
                    input: &input, writer: writer,
                    trampolines: trampolines, originalFuncCount: originalFuncCount
                )
            case .custom, .table, .memory, .global, .export, .start, .data, .dataCount:
                // FIXME: Support re-export of imported i64 functions
                try writer.writeBytes(input.bytes[offset ..< contentStart + size])
                input.read(size)
            case .none:
                throw Error.unexpectedSection(type)
            }
            assert(input.offset == contentStart + size)
        }
    }

    /// Returns indices of types that contains i64 in its signature
    func scan(typeSection: inout TypeSection, from input: inout InputStream) throws {
        let count = input.readVarUInt32()
        for _ in 0 ..< count {
            assert(input.readUInt8() == 0x60)
            let (params, paramsHasI64) = try input.readResultTypes()
            let (results, resultsHasI64) = try input.readResultTypes()
            let hasI64 = paramsHasI64 || resultsHasI64
            typeSection.append(signature: FuncSignature(params: params, results: results, hasI64: hasI64))
        }
    }

    /// https://webassembly.github.io/spec/core/binary/modules.html#import-section
    /// Returns a count of imported functions
    func scan(importSection: inout ImportSection, from input: inout InputStream,
              typeSection: inout TypeSection, trampolines: inout Trampolines) throws -> Int
    {
        let count = input.readVarUInt32()
        var importFuncCount = 0
        for index in 0 ..< count {
            input.consumeString() // module name
            input.consumeString() // field name
            let rawKind = input.readUInt8()
            let kind = ExternalKind(rawValue: rawKind)

            switch kind {
            case .func:
                let signatureIndex = Int(input.readVarUInt32())
                let signature = typeSection.signatures[signatureIndex]
                defer { importFuncCount += 1 }
                guard signature.hasI64 else { continue }

                let toTypeIndex = typeSection.signatures.count
                let toSignature = signature.lowered()
                typeSection.append(signature: toSignature)
                importSection.replacements.append(
                    (index: Int(index), toTypeIndex: toTypeIndex)
                )
                trampolines.add(
                    importIndex: importFuncCount, from: signature,
                    fromIndex: signatureIndex, to: toSignature
                )
            case .table: input.consumeTable()
            case .memory: input.consumeMemory()
            case .global: input.consumeGlobalHeader()
            case .except:
                fatalError("not supported yet")
            case .none:
                throw Error.invalidExternalKind(rawKind)
            }
        }
        return importFuncCount
    }
}

func writeSection<T>(_ type: SectionType, writer: OutputWriter, bodyWriter: (OutputWriter) throws -> T) throws -> T {
    try writer.writeByte(type.rawValue)
    let buffer = InMemoryOutputWriter()
    let result = try bodyWriter(buffer)
    try writer.writeBytes(encodeULEB128(UInt32(buffer._bytes.count)))
    try writer.writeBytes(buffer._bytes)
    return result
}

func transformCodeSection(input: inout InputStream, writer: OutputWriter,
                          trampolines: Trampolines, originalFuncCount: Int) throws
{
    try writeSection(.code, writer: writer) { writer in
        let count = Int(input.readVarUInt32())
        let newCount = count + trampolines.count
        try writer.writeBytes(encodeULEB128(UInt32(newCount)))
        for _ in 0 ..< count {
            let oldSize = Int(input.readVarUInt32())
            let bodyEnd = input.offset + oldSize
            var bodyBuffer: [UInt8] = []
            bodyBuffer.reserveCapacity(oldSize)

            try input.consumeLocals(consumer: {
                bodyBuffer.append(contentsOf: $0)
            })

            while input.offset < bodyEnd {
                let opcode = try input.readOpcode()
                guard case let .call(funcIndex) = opcode,
                    let (_, trampolineIndex) = trampolines.trampoline(byBaseFuncIndex: Int(funcIndex))
                else {
                    bodyBuffer.append(contentsOf: opcode.bytes())
                    continue
                }
                let newTargetIndex = originalFuncCount + trampolineIndex
                let callInst = Opcode.call(UInt32(newTargetIndex))
                bodyBuffer.append(contentsOf: callInst.bytes())
            }
            let newSize = bodyBuffer.count
            try writer.writeBytes(encodeULEB128(UInt32(newSize)))
            try writer.writeBytes(bodyBuffer)
        }

        for trampoline in trampolines {
            try trampoline.write(to: writer)
        }
    }
}

/// Read Elem section and rewrite i64 functions with trampoline functions.
func transformElemSection(input: inout InputStream, writer: OutputWriter,
                          trampolines: Trampolines, originalFuncCount: Int) throws
{
    try writeSection(.elem, writer: writer) { writer in
        let count = input.readVarUInt32()
        try writer.writeBytes(encodeULEB128(UInt32(count)))
        for _ in 0 ..< count {
            let tableIndex = input.readVarUInt32()
            try writer.writeBytes(encodeULEB128(tableIndex))
            try input.consumeI32InitExpr(consumer: writer.writeBytes)
            let funcIndicesCount = input.readVarUInt32()
            try writer.writeBytes(encodeULEB128(funcIndicesCount))
            for _ in 0 ..< funcIndicesCount {
                let funcIndex = input.readVarUInt32()
                if let (_, index) = trampolines.trampoline(byBaseFuncIndex: Int(funcIndex)) {
                    try writer.writeBytes(encodeULEB128(UInt32(index + originalFuncCount)))
                } else {
                    try writer.writeBytes(encodeULEB128(funcIndex))
                }
            }
        }
    }
}

/// Write out Func section and add trampoline signatures.
func transformFunctionSection(input: inout InputStream, writer: OutputWriter, trampolines: Trampolines) throws -> Int {
    try writeSection(.function, writer: writer) { writer in
        let count = Int(input.readVarUInt32())
        let newCount = count + trampolines.count
        try writer.writeBytes(encodeULEB128(UInt32(newCount)))

        for _ in 0 ..< count {
            let typeIndex = input.readVarUInt32()
            try writer.writeBytes(encodeULEB128(typeIndex))
        }

        for trampoline in trampolines {
            let index = UInt32(trampoline.fromSignatureIndex)
            try writer.writeBytes(encodeULEB128(index))
        }
        return count
    }
}
