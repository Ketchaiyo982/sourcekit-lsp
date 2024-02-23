//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import IndexStoreDB
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SourceKitD
import SwiftSyntax

// MARK: - Helper types

/// A parsed representation of a name that may be disambiguated by its argument labels.
///
/// ### Examples
///  - `foo(a:b:)`
///  - `foo(_:b:)`
///  - `foo` if no argument labels are specified, eg. for a variable.
fileprivate struct CompoundDeclName {
  /// The parameter of a compound decl name, which can either be the parameter's name or `_` to indicate that the
  /// parameter is unnamed.
  enum Parameter: Equatable {
    case named(String)
    case wildcard

    var stringOrWildcard: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return "_"
      }
    }

    var stringOrEmpty: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return ""
      }
    }
  }

  let baseName: String
  let parameters: [Parameter]

  /// Parse a compound decl name into its base names and parameters.
  init(_ compoundDeclName: String) {
    guard let openParen = compoundDeclName.firstIndex(of: "(") else {
      // We don't have a compound name. Everything is the base name
      self.baseName = compoundDeclName
      self.parameters = []
      return
    }
    self.baseName = String(compoundDeclName[..<openParen])
    let closeParen = compoundDeclName.firstIndex(of: ")") ?? compoundDeclName.endIndex
    let parametersText = compoundDeclName[compoundDeclName.index(after: openParen)..<closeParen]
    // Split by `:` to get the parameter names. Drop the last element so that we don't have a trailing empty element
    // after the last `:`.
    let parameterStrings = parametersText.split(separator: ":", omittingEmptySubsequences: false).dropLast()
    parameters = parameterStrings.map {
      switch $0 {
      case "", "_": return .wildcard
      default: return .named(String($0))
      }
    }
  }
}

/// The kind of range that a `SyntacticRenamePiece` can be.
fileprivate enum SyntacticRenamePieceKind {
  /// The base name of a function or the name of a variable, which can be renamed.
  ///
  /// ### Examples
  /// - `foo` in `func foo(a b: Int)`.
  /// - `foo` in `let foo = 1`
  case baseName

  /// The base name of a function-like declaration that cannot be renamed
  ///
  /// ### Examples
  /// - `init` in `init(a: Int)`
  /// - `subscript` in `subscript(a: Int) -> Int`
  case keywordBaseName

  /// The internal parameter name (aka. second name) inside a function declaration
  ///
  /// ### Examples
  /// - ` b` in `func foo(a b: Int)`
  case parameterName

  /// Same as `parameterName` but cannot be removed if it is the same as the parameter's first name. This only happens
  /// for subscripts where parameters are unnamed by default unless they have both a first and second name.
  ///
  /// ### Examples
  /// The second ` a` in `subscript(a a: Int)`
  case noncollapsibleParameterName

  /// The external argument label of a function parameter
  ///
  /// ### Examples
  /// - `a` in `func foo(a b: Int)`
  /// - `a` in `func foo(a: Int)`
  case declArgumentLabel

  /// The argument label inside a call.
  ///
  /// ### Examples
  /// - `a` in `foo(a: 1)`
  case callArgumentLabel

  /// The colon after an argument label inside a call. This is reported so it can be removed if the parameter becomes
  /// unnamed.
  ///
  /// ### Examples
  /// - `: ` in `foo(a: 1)`
  case callArgumentColon

  /// An empty range that point to the position before an unnamed argument. This is used to insert the argument label
  /// if an unnamed parameter becomes named.
  ///
  /// ### Examples
  /// - An empty range before `1` in `foo(1)`, which could expand to `foo(a: 1)`
  case callArgumentCombined

  /// The argument label in a compound decl name.
  ///
  /// ### Examples
  /// - `a` in `foo(a:)`
  case selectorArgumentLabel

  init?(_ uid: sourcekitd_uid_t, values: sourcekitd_values) {
    switch uid {
    case values.renameRangeBase: self = .baseName
    case values.renameRangeCallArgColon: self = .callArgumentColon
    case values.renameRangeCallArgCombined: self = .callArgumentCombined
    case values.renameRangeCallArgLabel: self = .callArgumentLabel
    case values.renameRangeDeclArgLabel: self = .declArgumentLabel
    case values.renameRangeKeywordBase: self = .keywordBaseName
    case values.renameRangeNoncollapsibleParam: self = .noncollapsibleParameterName
    case values.renameRangeParam: self = .parameterName
    case values.renameRangeSelectorArgLabel: self = .selectorArgumentLabel
    default: return nil
    }
  }
}

/// A single “piece” that is used for renaming a compound function name.
///
/// See `SyntacticRenamePieceKind` for the different rename pieces that exist.
///
/// ### Example
/// `foo(x: 1)` is represented by three pieces
/// - The base name `foo`
/// - The parameter name `x`
/// - The call argument colon `: `.
fileprivate struct SyntacticRenamePiece {
  /// The range that represents this piece of the name
  let range: Range<Position>

  /// The kind of the rename piece.
  let kind: SyntacticRenamePieceKind

  /// If this piece belongs to a parameter, the index of that parameter (zero-based) or `nil` if this is the base name
  /// piece.
  let parameterIndex: Int?

  /// Create a `SyntacticRenamePiece` from a `sourcekitd` response.
  init?(
    _ dict: SKDResponseDictionary,
    in snapshot: DocumentSnapshot,
    keys: sourcekitd_keys,
    values: sourcekitd_values
  ) {
    guard let line: Int = dict[keys.line],
      let column: Int = dict[keys.column],
      let endLine: Int = dict[keys.endLine],
      let endColumn: Int = dict[keys.endColumn],
      let kind: sourcekitd_uid_t = dict[keys.kind]
    else {
      return nil
    }
    guard
      let start = snapshot.positionOf(zeroBasedLine: line - 1, utf8Column: column - 1),
      let end = snapshot.positionOf(zeroBasedLine: endLine - 1, utf8Column: endColumn - 1)
    else {
      return nil
    }
    guard let kind = SyntacticRenamePieceKind(kind, values: values) else {
      return nil
    }

    self.range = start..<end
    self.kind = kind
    self.parameterIndex = dict[keys.argIndex] as Int?
  }
}

/// The context in which the location to be renamed occurred.
fileprivate enum SyntacticRenameNameContext {
  /// No syntactic rename ranges for the rename location could be found.
  case unmatched

  /// A name could be found at a requested rename location but the name did not match the specified old name.
  case mismatch

  /// The matched ranges are in active source code (ie. source code that is not an inactive `#if` range).
  case activeCode

  /// The matched ranges are in an inactive `#if` region of the source code.
  case inactiveCode

  /// The matched ranges occur inside a string literal.
  case string

  /// The matched ranges occur inside a `#selector` directive.
  case selector

  /// The matched ranges are within a comment.
  case comment

  init?(_ uid: sourcekitd_uid_t, values: sourcekitd_values) {
    switch uid {
    case values.editActive: self = .activeCode
    case values.editComment: self = .comment
    case values.editInactive: self = .inactiveCode
    case values.editMismatch: self = .mismatch
    case values.editSelector: self = .selector
    case values.editString: self = .string
    case values.editUnknown: self = .unmatched
    default: return nil
    }
  }
}

/// A set of ranges that, combined, represent which edits need to be made to rename a possibly compound name.
///
/// See `SyntacticRenamePiece` for more details.
fileprivate struct SyntacticRenameName {
  let pieces: [SyntacticRenamePiece]
  let category: SyntacticRenameNameContext

  init?(
    _ dict: SKDResponseDictionary,
    in snapshot: DocumentSnapshot,
    keys: sourcekitd_keys,
    values: sourcekitd_values
  ) {
    guard let ranges: SKDResponseArray = dict[keys.ranges] else {
      return nil
    }
    self.pieces = ranges.compactMap { SyntacticRenamePiece($0, in: snapshot, keys: keys, values: values) }
    guard let categoryUid: sourcekitd_uid_t = dict[keys.category],
      let category = SyntacticRenameNameContext(categoryUid, values: values)
    else {
      return nil
    }
    self.category = category
  }
}

private extension LineTable {
  subscript(range: Range<Position>) -> Substring? {
    guard let start = self.stringIndexOf(line: range.lowerBound.line, utf16Column: range.lowerBound.utf16index),
      let end = self.stringIndexOf(line: range.upperBound.line, utf16Column: range.upperBound.utf16index)
    else {
      return nil
    }
    return self.content[start..<end]
  }
}

private extension DocumentSnapshot {
  init?(_ uri: DocumentURI, language: Language) throws {
    guard let url = uri.fileURL else {
      return nil
    }
    let contents = try String(contentsOf: url)
    self.init(uri: DocumentURI(url), language: language, version: 0, lineTable: LineTable(contents))
  }

  func position(of renameLocation: RenameLocation) -> Position? {
    return positionOf(zeroBasedLine: renameLocation.line - 1, utf8Column: renameLocation.utf8Column - 1)
  }

  func position(of symbolLocation: SymbolLocation) -> Position? {
    return positionOf(zeroBasedLine: symbolLocation.line - 1, utf8Column: symbolLocation.utf8Column - 1)
  }
}

private extension RenameLocation.Usage {
  init(roles: SymbolRole) {
    if roles.contains(.definition) || roles.contains(.declaration) {
      self = .definition
    } else if roles.contains(.call) {
      self = .call
    } else {
      self = .reference
    }
  }
}

private extension IndexSymbolKind {
  var isMethod: Bool {
    switch self {
    case .instanceMethod, .classMethod, .staticMethod:
      return true
    default: return false
    }
  }
}

// MARK: - Name translation

extension SwiftLanguageServer {
  enum NameTranslationError: Error, CustomStringConvertible {
    case cannotComputeOffset(SymbolLocation)
    case malformedSwiftToClangTranslateNameResponse(SKDResponseDictionary)
    case malformedClangToSwiftTranslateNameResponse(SKDResponseDictionary)

    var description: String {
      switch self {
      case .cannotComputeOffset(let position):
        return "Failed to determine UTF-8 offset of \(position)"
      case .malformedSwiftToClangTranslateNameResponse(let response):
        return """
          Malformed response for Swift to Clang name translation

          \(response.description)
          """
      case .malformedClangToSwiftTranslateNameResponse(let response):
        return """
          Malformed response for Clang to Swift name translation

          \(response.description)
          """
      }
    }
  }

  /// Translate a Swift name to the corresponding C/C++/ObjectiveC name.
  ///
  /// This invokes the clang importer to perform the name translation, based on the `position` and `uri` at which the
  /// Swift symbol is defined.
  ///
  /// - Parameters:
  ///   - position: The position at which the Swift name is defined
  ///   - uri: The URI of the document in which the Swift name is defined
  ///   - name: The Swift name of the symbol
  fileprivate func translateSwiftNameToClang(
    at symbolLocation: SymbolLocation,
    in uri: DocumentURI,
    name: CompoundDeclName
  ) async throws -> String {
    guard let snapshot = documentManager.latestSnapshotOrDisk(uri, language: .swift) else {
      throw ResponseError.unknown("Failed to get contents of \(uri.forLogging) to translate Swift name to clang name")
    }

    guard
      let position = snapshot.position(of: symbolLocation),
      let offset = snapshot.utf8Offset(of: position)
    else {
      throw NameTranslationError.cannotComputeOffset(symbolLocation)
    }

    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
      keys.offset: offset,
      keys.nameKind: sourcekitd.values.nameSwift,
      keys.baseName: name.baseName,
      keys.argNames: sourcekitd.array(name.parameters.map { $0.stringOrWildcard }),
    ])

    let response = try await sourcekitd.send(req, fileContents: snapshot.text)

    guard let isZeroArgSelector: Int = response[keys.isZeroArgSelector],
      let selectorPieces: SKDResponseArray = response[keys.selectorPieces]
    else {
      throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
    }
    return
      try selectorPieces
      .map { (dict: SKDResponseDictionary) -> String in
        guard var name: String = dict[keys.name] else {
          throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
        }
        if isZeroArgSelector == 0 {
          // Selector pieces in multi-arg selectors end with ":"
          name.append(":")
        }
        return name
      }.joined()
  }

  /// Translates a C/C++/Objective-C symbol name to Swift.
  ///
  /// This requires the position at which the the symbol is referenced in Swift so sourcekitd can determine the
  /// clang declaration that is being renamed and check if that declaration has a `SWIFT_NAME`. If it does, this
  /// `SWIFT_NAME` is used as the name translation result instead of invoking the clang importer rename rules.
  ///
  /// - Parameters:
  ///   - position: A position at which this symbol is referenced from Swift.
  ///   - snapshot: The snapshot containing the `position` that points to a usage of the clang symbol.
  ///   - isObjectiveCSelector: Whether the name is an Objective-C selector. Cannot be inferred from the name because
  ///     a name without `:` can also be a zero-arg Objective-C selector. For such names sourcekitd needs to know
  ///     whether it is translating a selector to apply the correct renaming rule.
  ///   - name: The clang symbol name.
  /// - Returns:
  fileprivate func translateClangNameToSwift(
    at symbolLocation: SymbolLocation,
    in snapshot: DocumentSnapshot,
    isObjectiveCSelector: Bool,
    name: String
  ) async throws -> String {
    guard
      let position = snapshot.position(of: symbolLocation),
      let offset = snapshot.utf8Offset(of: position)
    else {
      throw NameTranslationError.cannotComputeOffset(symbolLocation)
    }
    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
      keys.offset: offset,
      keys.nameKind: sourcekitd.values.nameObjc,
    ])

    if isObjectiveCSelector {
      // Split the name into selector pieces, keeping the ':'.
      let selectorPieces = name.split(separator: ":").map { String($0 + ":") }
      req.set(keys.selectorPieces, to: sourcekitd.array(selectorPieces))
    } else {
      req.set(keys.baseName, to: name)
    }

    let response = try await sourcekitd.send(req, fileContents: snapshot.text)

    guard let baseName: String = response[keys.baseName] else {
      throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
    }
    let argNamesArray: SKDResponseArray? = response[keys.argNames]
    let argNames = try argNamesArray?.map { (dict: SKDResponseDictionary) -> String in
      guard var name: String = dict[keys.name] else {
        throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
      }
      if name.isEmpty {
        // Empty argument names are represented by `_` in Swift.
        name = "_"
      }
      return name + ":"
    }
    var result = baseName
    if let argNames, !argNames.isEmpty {
      result += "(" + argNames.joined() + ")"
    }
    return result
  }
}

/// A name that has a representation both in Swift and clang-based languages.
///
/// These names might differ. For example, an Objective-C method gets translated by the clang importer to form the Swift
/// name or it could have a `SWIFT_NAME` attribute that defines the method's name in Swift. Similarly, a Swift symbol
/// might specify the name by which it gets exposed to Objective-C using the `@objc` attribute.
public struct CrossLanguageName {
  /// The name of the symbol in clang languages or `nil` if the symbol is defined in Swift, doesn't have any references
  /// from clang languages and thus hasn't been translated.
  fileprivate let clangName: String?

  /// The name of the symbol in Swift or `nil` if the symbol is defined in clang, doesn't have any references from
  /// Swift and thus hasn't been translated.
  fileprivate let swiftName: String?

  fileprivate var compoundSwiftName: CompoundDeclName? {
    if let swiftName {
      return CompoundDeclName(swiftName)
    }
    return nil
  }

  /// the language that the symbol is defined in.
  fileprivate let definitionLanguage: Language

  /// The name of the symbol in the language that it is defined in.
  var definitionName: String? {
    switch definitionLanguage {
    case .c, .cpp, .objective_c, .objective_cpp:
      return clangName
    case .swift:
      return swiftName
    default:
      return nil
    }
  }
}

// MARK: - SourceKitServer

/// The kinds of symbol occurrence roles that should be renamed.
fileprivate let renameRoles: SymbolRole = [.declaration, .definition, .reference]

extension DocumentManager {
  /// Returns the latest open snapshot of `uri` or, if no document with that URI is open, reads the file contents of
  /// that file from disk.
  fileprivate func latestSnapshotOrDisk(_ uri: DocumentURI, language: Language) -> DocumentSnapshot? {
    return (try? self.latestSnapshot(uri)) ?? (try? DocumentSnapshot.init(uri, language: language))
  }
}

extension SourceKitServer {
  /// Returns a `DocumentSnapshot`, a position and the corresponding language service that references
  /// `usr` from a Swift file. If `usr` is not referenced from Swift, returns `nil`.
  private func getReferenceFromSwift(
    usr: String,
    index: IndexStoreDB,
    workspace: Workspace
  ) async -> (languageServer: SwiftLanguageServer, snapshot: DocumentSnapshot, location: SymbolLocation)? {
    var reference: SymbolOccurrence? = nil
    index.forEachSymbolOccurrence(byUSR: usr, roles: renameRoles) {
      if index.symbolProvider(for: $0.location.path) == .swift {
        reference = $0
        // We have found a reference from Swift. Stop iteration.
        return false
      }
      return true
    }

    guard let reference else {
      return nil
    }
    let uri = DocumentURI(URL(fileURLWithPath: reference.location.path))
    guard let snapshot = self.documentManager.latestSnapshotOrDisk(uri, language: .swift) else {
      return nil
    }
    let swiftLanguageServer = await self.languageService(for: uri, .swift, in: workspace) as? SwiftLanguageServer
    guard let swiftLanguageServer else {
      return nil
    }
    return (swiftLanguageServer, snapshot, reference.location)
  }

  /// Returns a `CrossLanguageName` for the symbol with the given USR.
  ///
  /// If the symbol is used across clang/Swift languages, the cross-language name will have both a `swiftName` and a
  /// `clangName` set. Otherwise it only has the name of the language it's defined in set.
  ///
  /// If `overrideName` is passed, the name of the symbol will be assumed to be `overrideName` in its native language.
  /// This is used to create a `CrossLanguageName` for the new name of a renamed symbol.
  private func getCrossLanguageName(
    forUsr usr: String,
    overrideName: String? = nil,
    workspace: Workspace,
    index: IndexStoreDB
  ) async throws -> CrossLanguageName? {
    let definitions = index.occurrences(ofUSR: usr, roles: [.definition])
    guard let definitionSymbol = definitions.only else {
      if definitions.isEmpty {
        logger.error("no definitions for \(usr) found")
      } else {
        logger.error("Multiple definitions for \(usr) found")
      }
      return nil
    }
    let definitionLanguage: Language =
      switch definitionSymbol.symbol.language {
      case .c: .c
      case .cxx: .cpp
      case .objc: .objective_c
      case .swift: .swift
      }
    let definitionDocumentUri = DocumentURI(URL(fileURLWithPath: definitionSymbol.location.path))

    guard
      let definitionLanguageService = await self.languageService(
        for: definitionDocumentUri,
        definitionLanguage,
        in: workspace
      )
    else {
      logger.fault("Failed to get language service for the document defining \(usr)")
      return nil
    }

    let definitionName = overrideName ?? definitionSymbol.symbol.name

    switch definitionLanguageService {
    case is ClangLanguageServerShim:
      let swiftName: String?
      if let swiftReference = await getReferenceFromSwift(usr: usr, index: index, workspace: workspace) {
        let isObjectiveCSelector = definitionLanguage == .objective_c && definitionSymbol.symbol.kind.isMethod
        swiftName = try await swiftReference.languageServer.translateClangNameToSwift(
          at: swiftReference.location,
          in: swiftReference.snapshot,
          isObjectiveCSelector: isObjectiveCSelector,
          name: definitionName
        )
      } else {
        logger.debug("Not translating \(usr) to Swift because it is not referenced from Swift")
        swiftName = nil
      }
      return CrossLanguageName(clangName: definitionName, swiftName: swiftName, definitionLanguage: definitionLanguage)
    case let swiftLanguageServer as SwiftLanguageServer:
      // Continue iteration if the symbol provider is not clang.
      // If we terminate early by returning `false` from the closure, `forEachSymbolOccurrence` returns `true`,
      // indicating that we have found a reference from clang.
      let hasReferenceFromClang = !index.forEachSymbolOccurrence(byUSR: usr, roles: renameRoles) {
        return index.symbolProvider(for: $0.location.path) != .clang
      }
      let clangName: String?
      if hasReferenceFromClang {
        clangName = try await swiftLanguageServer.translateSwiftNameToClang(
          at: definitionSymbol.location,
          in: definitionDocumentUri,
          name: CompoundDeclName(definitionName)
        )
      } else {
        clangName = nil
      }
      return CrossLanguageName(clangName: clangName, swiftName: definitionName, definitionLanguage: definitionLanguage)
    default:
      throw ResponseError.unknown("Cannot rename symbol because it is defined in an unknown language")
    }
  }

  func rename(_ request: RenameRequest) async throws -> WorkspaceEdit? {
    let uri = request.textDocument.uri
    let snapshot = try documentManager.latestSnapshot(uri)

    guard let workspace = await workspaceForDocument(uri: uri) else {
      throw ResponseError.workspaceNotOpen(uri)
    }
    guard let primaryFileLanguageService = workspace.documentService[uri] else {
      return nil
    }

    // Determine the local edits and the USR to rename
    let renameResult = try await primaryFileLanguageService.rename(request)

    guard let usr = renameResult.usr, let index = workspace.index else {
      // We don't have enough information to perform a cross-file rename.
      return renameResult.edits
    }

    let oldName = try await getCrossLanguageName(forUsr: usr, workspace: workspace, index: index)
    let newName = try await getCrossLanguageName(
      forUsr: usr,
      overrideName: request.newName,
      workspace: workspace,
      index: index
    )

    guard let oldName, let newName else {
      // We failed to get the translated name, so we can't to global rename.
      // Do local rename within the current file instead as fallback.
      return renameResult.edits
    }

    var changes: [DocumentURI: [TextEdit]] = [:]
    if oldName.definitionLanguage == snapshot.language {
      // If this is not a cross-language rename, we can use the local edits returned by
      // the language service's rename function.
      // If this is cross-language rename, that's not possible because the user would eg.
      // enter a new clang name, which needs to be translated to the Swift name before
      // changing the current file.
      changes = renameResult.edits.changes ?? [:]
    }

    // If we have a USR + old name, perform an index lookup to find workspace-wide symbols to rename.
    // First, group all occurrences of that USR by the files they occur in.
    var locationsByFile: [URL: [RenameLocation]] = [:]
    for occurrence in index.occurrences(ofUSR: usr, roles: renameRoles) {
      let url = URL(fileURLWithPath: occurrence.location.path)
      let renameLocation = RenameLocation(
        line: occurrence.location.line,
        utf8Column: occurrence.location.utf8Column,
        usage: RenameLocation.Usage(roles: occurrence.roles)
      )
      locationsByFile[url, default: []].append(renameLocation)
    }

    // Now, call `editsToRename(locations:in:oldName:newName:)` on the language service to convert these ranges into
    // edits.
    let urisAndEdits =
      await locationsByFile
      .filter { changes[DocumentURI($0.key)] == nil }
      .concurrentMap { (url: URL, renameLocations: [RenameLocation]) -> (DocumentURI, [TextEdit])? in
        let uri = DocumentURI(url)
        let language: Language
        switch index.symbolProvider(for: url.path) {
        case .clang:
          // Technically, we still don't know the language of the source file but defaulting to C is sufficient to
          // ensure we get the clang toolchain language server, which is all we care about.
          language = .c
        case .swift:
          language = .swift
        case nil:
          logger.error("Failed to determine symbol provider for \(uri.forLogging)")
          return nil
        }
        // Create a document snapshot to operate on. If the document is open, load it from the document manager,
        // otherwise conjure one from the file on disk. We need the file in memory to perform UTF-8 to UTF-16 column
        // conversions.
        guard let snapshot = self.documentManager.latestSnapshotOrDisk(uri, language: language) else {
          logger.error("Failed to get document snapshot for \(uri.forLogging)")
          return nil
        }
        do {
          guard let languageService = await self.languageService(for: uri, language, in: workspace) else {
            return nil
          }
          let edits = try await languageService.editsToRename(
            locations: renameLocations,
            in: snapshot,
            oldName: oldName,
            newName: newName
          )
          return (uri, edits)
        } catch {
          logger.error("Failed to get edits for \(uri.forLogging): \(error.forLogging)")
          return nil
        }
      }.compactMap { $0 }
    for (uri, editsForUri) in urisAndEdits {
      precondition(
        changes[uri] == nil,
        "We should have only computed edits for URIs that didn't have edits from the initial rename request"
      )
      if !editsForUri.isEmpty {
        changes[uri] = editsForUri
      }
    }
    var edits = renameResult.edits
    edits.changes = changes
    return edits
  }

  func prepareRename(
    _ request: PrepareRenameRequest,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) async throws -> PrepareRenameResponse? {
    guard let languageServicePrepareRename = try await languageService.prepareRename(request) else {
      return nil
    }
    var prepareRenameResult = languageServicePrepareRename.prepareRename

    guard
      let index = workspace.index,
      let usr = languageServicePrepareRename.usr,
      let oldName = try await self.getCrossLanguageName(forUsr: usr, workspace: workspace, index: index)
    else {
      return prepareRenameResult
    }

    // Get the name of the symbol's definition, if possible.
    // This is necessary for cross-language rename. Eg. when renaming an Objective-C method from Swift,
    // the user still needs to enter the new Objective-C name.
    prepareRenameResult.placeholder = oldName.definitionName
    return prepareRenameResult
  }

  func indexedRename(
    _ request: IndexedRenameRequest,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) async throws -> WorkspaceEdit? {
    return try await languageService.indexedRename(request)
  }
}

// MARK: - Swift

extension SwiftLanguageServer {
  /// From a list of rename locations compute the list of `SyntacticRenameName`s that define which ranges need to be
  /// edited to rename a compound decl name.
  ///
  /// - Parameters:
  ///   - renameLocations: The locations to rename
  ///   - oldName: The compound decl name that the declaration had before the rename. Used to verify that the rename
  ///     locations match that name. Eg. `myFunc(argLabel:otherLabel:)` or `myVar`
  ///   - snapshot: A `DocumentSnapshot` containing the contents of the file for which to compute the rename ranges.
  private func getSyntacticRenameRanges(
    renameLocations: [RenameLocation],
    oldName: String,
    in snapshot: DocumentSnapshot
  ) async throws -> [SyntacticRenameName] {
    let locations = sourcekitd.array(
      renameLocations.map { renameLocation in
        let location = sourcekitd.dictionary([
          keys.line: renameLocation.line,
          keys.column: renameLocation.utf8Column,
          keys.nameType: renameLocation.usage.uid(values: values),
        ])
        return sourcekitd.dictionary([
          keys.locations: [location],
          keys.name: oldName,
        ])
      }
    )

    let skreq = sourcekitd.dictionary([
      keys.request: requests.findRenameRanges,
      keys.sourceFile: snapshot.uri.pseudoPath,
      // find-syntactic-rename-ranges is a syntactic sourcekitd request that doesn't use the in-memory file snapshot.
      // We need to send the source text again.
      keys.sourceText: snapshot.text,
      keys.renameLocations: locations,
    ])

    let syntacticRenameRangesResponse = try await sourcekitd.send(skreq, fileContents: snapshot.text)
    guard let categorizedRanges: SKDResponseArray = syntacticRenameRangesResponse[keys.categorizedRanges] else {
      throw ResponseError.internalError("sourcekitd did not return categorized ranges")
    }

    return categorizedRanges.compactMap { SyntacticRenameName($0, in: snapshot, keys: keys, values: values) }
  }

  /// If `position` is on an argument label or a parameter name, find the position of the function's base name.
  private func findFunctionBaseNamePosition(of position: Position, in snapshot: DocumentSnapshot) async -> Position? {
    class TokenFinder: SyntaxAnyVisitor {
      /// The position at which the token should be found.
      let position: AbsolutePosition

      /// Once found, the token at the requested position.
      var foundToken: TokenSyntax?

      init(position: AbsolutePosition) {
        self.position = position
        super.init(viewMode: .sourceAccurate)
      }

      override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        guard (node.position..<node.endPosition).contains(position) else {
          // Node doesn't contain the position. No point visiting it.
          return .skipChildren
        }
        guard foundToken == nil else {
          // We have already found a token. No point visiting this one
          return .skipChildren
        }
        return .visitChildren
      }

      override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if (token.position..<token.endPosition).contains(position) {
          self.foundToken = token
        }
        return .skipChildren
      }

      /// Dedicated entry point for `TokenFinder`.
      static func findToken(at position: AbsolutePosition, in tree: some SyntaxProtocol) -> TokenSyntax? {
        let finder = TokenFinder(position: position)
        finder.walk(tree)
        return finder.foundToken
      }
    }

    let tree = await self.syntaxTreeManager.syntaxTree(for: snapshot)
    guard let absolutePosition = snapshot.position(of: position) else {
      return nil
    }
    guard let token = TokenFinder.findToken(at: absolutePosition, in: tree) else {
      return nil
    }

    // The node that contains the function's base name. This might be an expression like `self.doStuff`.
    // The start position of the last token in this node will be used as the base name position.
    var baseNode: Syntax? = nil

    switch token.keyPathInParent {
    case \LabeledExprSyntax.label:
      let callLike = token.parent(as: LabeledExprSyntax.self)?.parent(as: LabeledExprListSyntax.self)?.parent
      switch callLike?.as(SyntaxEnum.self) {
      case .attribute(let attribute):
        baseNode = Syntax(attribute.attributeName)
      case .functionCallExpr(let functionCall):
        baseNode = Syntax(functionCall.calledExpression)
      case .macroExpansionDecl(let macroExpansionDecl):
        baseNode = Syntax(macroExpansionDecl.macroName)
      case .macroExpansionExpr(let macroExpansionExpr):
        baseNode = Syntax(macroExpansionExpr.macroName)
      case .subscriptCallExpr(let subscriptCall):
        baseNode = Syntax(subscriptCall.leftSquare)
      default:
        break
      }
    case \FunctionParameterSyntax.firstName:
      let parameterClause =
        token
        .parent(as: FunctionParameterSyntax.self)?
        .parent(as: FunctionParameterListSyntax.self)?
        .parent(as: FunctionParameterClauseSyntax.self)
      if let functionSignature = parameterClause?.parent(as: FunctionSignatureSyntax.self) {
        switch functionSignature.parent?.as(SyntaxEnum.self) {
        case .functionDecl(let functionDecl):
          baseNode = Syntax(functionDecl.name)
        case .initializerDecl(let initializerDecl):
          baseNode = Syntax(initializerDecl.initKeyword)
        case .macroDecl(let macroDecl):
          baseNode = Syntax(macroDecl.name)
        default:
          break
        }
      } else if let subscriptDecl = parameterClause?.parent(as: SubscriptDeclSyntax.self) {
        baseNode = Syntax(subscriptDecl.subscriptKeyword)
      }
    case \DeclNameArgumentSyntax.name:
      let declReference =
        token
        .parent(as: DeclNameArgumentSyntax.self)?
        .parent(as: DeclNameArgumentListSyntax.self)?
        .parent(as: DeclNameArgumentsSyntax.self)?
        .parent(as: DeclReferenceExprSyntax.self)
      baseNode = Syntax(declReference?.baseName)
    default:
      break
    }

    if let lastToken = baseNode?.lastToken(viewMode: .sourceAccurate),
      let position = snapshot.position(of: lastToken.positionAfterSkippingLeadingTrivia)
    {
      return position
    }
    return nil
  }

  /// When the user requested a rename at `position` in `snapshot`, determine the position at which the rename should be
  /// performed internally and USR of the symbol to rename.
  ///
  /// This is necessary to adjust the rename position when renaming function parameters. For example when invoking
  /// rename on `x` in `foo(x:)`, we need to perform a rename of `foo` in sourcekitd so that we can rename the function
  /// parameter.
  ///
  /// The position might be `nil` if there is no local position in the file that refers to the base name to be renamed.
  /// This happens if renaming a function parameter of `MyStruct(x:)` where `MyStruct` is defined outside of the current
  /// file. In this case, there is no base name that refers to the initializer of `MyStruct`. When `position` is `nil`
  /// a pure index-based rename from the usr USR or `symbolDetails` needs to be performed and no `relatedIdentifiers`
  /// request can be used to rename symbols in the current file.
  func symbolToRename(
    at position: Position,
    in snapshot: DocumentSnapshot
  ) async -> (position: Position?, usr: String?) {
    let symbolInfo = try? await self.symbolInfo(
      SymbolInfoRequest(textDocument: TextDocumentIdentifier(snapshot.uri), position: position)
    )

    guard let baseNamePosition = await findFunctionBaseNamePosition(of: position, in: snapshot) else {
      return (position, symbolInfo?.only?.usr)
    }
    if let onlySymbol = symbolInfo?.only, onlySymbol.kind == .constructor {
      // We have a rename like `MyStruct(x: 1)`, invoked from `x`.
      if let bestLocalDeclaration = onlySymbol.bestLocalDeclaration, bestLocalDeclaration.uri == snapshot.uri {
        // If the initializer is declared within the same file, we can perform rename in the current file based on
        // the declaration's location.
        return (bestLocalDeclaration.range.lowerBound, onlySymbol.usr)
      }
      // Otherwise, we don't have a reference to the base name of the initializer and we can't use related
      // identifiers to perform the rename.
      // Return `nil` for the position to perform a pure index-based rename.
      return (nil, onlySymbol.usr)
    }
    // Adjust the symbol info to the symbol info of the base name.
    // This ensures that we get the symbol info of the function's base instead of the parameter.
    let baseNameSymbolInfo = try? await self.symbolInfo(
      SymbolInfoRequest(textDocument: TextDocumentIdentifier(snapshot.uri), position: baseNamePosition)
    )
    return (baseNamePosition, baseNameSymbolInfo?.only?.usr)
  }

  public func rename(_ request: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let (renamePosition, usr) = await symbolToRename(at: request.position, in: snapshot)
    guard let renamePosition else {
      return (edits: WorkspaceEdit(), usr: usr)
    }

    let relatedIdentifiersResponse = try await self.relatedIdentifiers(
      at: renamePosition,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard let oldName = relatedIdentifiersResponse.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }

    try Task.checkCancellation()

    let renameLocations = relatedIdentifiersResponse.relatedIdentifiers.compactMap {
      (relatedIdentifier) -> RenameLocation? in
      let position = relatedIdentifier.range.lowerBound
      guard let utf8Column = snapshot.lineTable.utf8ColumnAt(line: position.line, utf16Column: position.utf16index)
      else {
        logger.fault("Unable to find UTF-8 column for \(position.line):\(position.utf16index)")
        return nil
      }
      return RenameLocation(line: position.line + 1, utf8Column: utf8Column + 1, usage: relatedIdentifier.usage)
    }

    try Task.checkCancellation()

    let edits = try await editsToRename(
      locations: renameLocations,
      in: snapshot,
      oldName: CrossLanguageName(clangName: nil, swiftName: oldName, definitionLanguage: .swift),
      newName: CrossLanguageName(clangName: nil, swiftName: request.newName, definitionLanguage: .swift)
    )

    try Task.checkCancellation()

    return (edits: WorkspaceEdit(changes: [snapshot.uri: edits]), usr: usr)
  }

  /// Return the edit that needs to be performed for the given syntactic rename piece to rename it from
  /// `oldParameter` to `newParameter`.
  /// Returns `nil` if no edit needs to be performed.
  private func textEdit(
    for piece: SyntacticRenamePiece,
    in snapshot: DocumentSnapshot,
    oldParameter: CompoundDeclName.Parameter,
    newParameter: CompoundDeclName.Parameter
  ) -> TextEdit? {
    switch piece.kind {
    case .parameterName:
      if newParameter == .wildcard, piece.range.isEmpty, case .named(let oldParameterName) = oldParameter {
        // We are changing a named parameter to an unnamed one. If the parameter didn't have an internal parameter
        // name, we need to transfer the previously external parameter name to be the internal one.
        // E.g. `func foo(a: Int)` becomes `func foo(_ a: Int)`.
        return TextEdit(range: piece.range, newText: " " + oldParameterName)
      }
      if let original = snapshot.lineTable[piece.range],
        case .named(let newParameterLabel) = newParameter,
        newParameterLabel.trimmingCharacters(in: .whitespaces) == original.trimmingCharacters(in: .whitespaces)
      {
        // We are changing the external parameter name to be the same one as the internal parameter name. The
        // internal name is thus no longer needed. Drop it.
        // Eg. an old declaration `func foo(_ a: Int)` becomes `func foo(a: Int)` when renaming the parameter to `a`
        return TextEdit(range: piece.range, newText: "")
      }
      // In all other cases, don't touch the internal parameter name. It's not part of the public API.
      return nil
    case .noncollapsibleParameterName:
      // Noncollapsible parameter names should never be renamed because they are the same as `parameterName` but
      // never fall into one of the two categories above.
      return nil
    case .declArgumentLabel:
      if piece.range.isEmpty {
        // If we are inserting a new external argument label where there wasn't one before, add a space after it to
        // separate it from the internal name.
        // E.g. `subscript(a: Int)` becomes `subscript(a a: Int)`.
        return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard + " ")
      }
      // Otherwise, just update the name.
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .callArgumentLabel:
      // Argument labels of calls are just updated.
      return TextEdit(range: piece.range, newText: newParameter.stringOrEmpty)
    case .callArgumentColon:
      if case .wildcard = newParameter {
        // If the parameter becomes unnamed, remove the colon after the argument name.
        return TextEdit(range: piece.range, newText: "")
      }
      return nil
    case .callArgumentCombined:
      if case .named(let newParameterName) = newParameter {
        // If an unnamed parameter becomes named, insert the new name and a colon.
        return TextEdit(range: piece.range, newText: newParameterName + ": ")
      }
      return nil
    case .selectorArgumentLabel:
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .baseName, .keywordBaseName:
      preconditionFailure("Handled above")
    }
  }

  public func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldCrossLanguageName: CrossLanguageName,
    newName newCrossLanguageName: CrossLanguageName
  ) async throws -> [TextEdit] {
    guard
      let oldNameString = oldCrossLanguageName.swiftName,
      let oldName = oldCrossLanguageName.compoundSwiftName,
      let newName = newCrossLanguageName.compoundSwiftName
    else {
      throw ResponseError.unknown(
        "Failed to rename \(snapshot.uri.forLogging) because the Swift name for rename is unknown"
      )
    }

    let compoundRenameRanges = try await getSyntacticRenameRanges(
      renameLocations: renameLocations,
      oldName: oldNameString,
      in: snapshot
    )

    try Task.checkCancellation()

    return compoundRenameRanges.flatMap { (compoundRenameRange) -> [TextEdit] in
      switch compoundRenameRange.category {
      case .unmatched, .mismatch:
        // The location didn't match. Don't rename it
        return []
      case .activeCode, .inactiveCode, .selector:
        // Occurrences in active code and selectors should always be renamed.
        // Inactive code is currently never returned by sourcekitd.
        break
      case .string, .comment:
        // We currently never get any results in strings or comments because the related identifiers request doesn't
        // provide any locations inside strings or comments. We would need to have a textual index to find these
        // locations.
        return []
      }
      return compoundRenameRange.pieces.compactMap { (piece) -> TextEdit? in
        if piece.kind == .baseName {
          return TextEdit(range: piece.range, newText: newName.baseName)
        } else if piece.kind == .keywordBaseName {
          // Keyword base names can't be renamed
          return nil
        }

        guard let parameterIndex = piece.parameterIndex,
          parameterIndex < newName.parameters.count,
          parameterIndex < oldName.parameters.count
        else {
          // Be lenient and just keep the old parameter names if the new name doesn't specify them, eg. if we are
          // renaming `func foo(a: Int, b: Int)` and the user specified `bar(x:)` as the new name.
          return nil
        }

        return self.textEdit(
          for: piece,
          in: snapshot,
          oldParameter: oldName.parameters[parameterIndex],
          newParameter: newName.parameters[parameterIndex]
        )
      }
    }
  }

  public func prepareRename(
    _ request: PrepareRenameRequest
  ) async throws -> (prepareRename: PrepareRenameResponse, usr: String?)? {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let (renamePosition, usr) = await symbolToRename(at: request.position, in: snapshot)
    guard let renamePosition else {
      return nil
    }

    let response = try await self.relatedIdentifiers(
      at: renamePosition,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard let name = response.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }
    guard let range = response.relatedIdentifiers.first(where: { $0.range.contains(renamePosition) })?.range
    else {
      return nil
    }
    return (PrepareRenameResponse(range: range, placeholder: name), usr)
  }
}

// MARK: - Clang

extension ClangLanguageServerShim {
  func rename(_ renameRequest: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    async let edits = forwardRequestToClangd(renameRequest)
    let symbolInfoRequest = SymbolInfoRequest(
      textDocument: renameRequest.textDocument,
      position: renameRequest.position
    )
    let symbolDetail = try await forwardRequestToClangd(symbolInfoRequest).only
    return (try await edits ?? WorkspaceEdit(), symbolDetail?.usr)
  }

  func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldCrossLanguageName: CrossLanguageName,
    newName newCrossLanguageName: CrossLanguageName
  ) async throws -> [TextEdit] {
    let positions = [
      snapshot.uri: renameLocations.compactMap { snapshot.position(of: $0) }
    ]
    guard
      let oldName = oldCrossLanguageName.clangName,
      let newName = newCrossLanguageName.clangName
    else {
      throw ResponseError.unknown(
        "Failed to rename \(snapshot.uri.forLogging) because the clang name for rename is unknown"
      )
    }
    let request = IndexedRenameRequest(
      textDocument: TextDocumentIdentifier(snapshot.uri),
      oldName: oldName,
      newName: newName,
      positions: positions
    )
    do {
      let edits = try await forwardRequestToClangd(request)
      return edits?.changes?[snapshot.uri] ?? []
    } catch {
      logger.error("Failed to get indexed rename edits: \(error.forLogging)")
      return []
    }
  }

  public func prepareRename(
    _ request: PrepareRenameRequest
  ) async throws -> (prepareRename: PrepareRenameResponse, usr: String?)? {
    guard let prepareRename = try await forwardRequestToClangd(request) else {
      return nil
    }
    let symbolInfo = try await forwardRequestToClangd(
      SymbolInfoRequest(textDocument: request.textDocument, position: request.position)
    )
    return (prepareRename, symbolInfo.only?.usr)
  }
}

fileprivate extension SyntaxProtocol {
  /// Returns the parent node and casts it to the specified type.
  func parent<S: SyntaxProtocol>(as syntaxType: S.Type) -> S? {
    return parent?.as(S.self)
  }
}
