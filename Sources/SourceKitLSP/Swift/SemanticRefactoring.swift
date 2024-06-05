//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import LanguageServerProtocol
import SourceKitD

/// Detailed information about the result of a specific refactoring operation.
///
/// Wraps the information returned by sourcekitd's `semantic_refactoring` request, such as the necessary edits and placeholder locations.
struct SemanticRefactoring {

  /// The title of the refactoring action.
  var title: String

  /// The resulting `WorkspaceEdit` of a `semantic_refactoring` request.
  var edit: WorkspaceEdit

  init(_ title: String, _ edit: WorkspaceEdit) {
    self.title = title
    self.edit = edit
  }

  /// Create a `SemanticRefactoring` from a sourcekitd response dictionary, if possible.
  ///
  /// - Parameters:
  ///   - title: The title of the refactoring action.
  ///   - dict: Response dictionary to extract information from.
  ///   - snapshot: The snapshot that triggered the `semantic_refactoring` request.
  ///   - keys: The sourcekitd key set to use for looking up into `dict`.
  init?(_ title: String, _ dict: SKDResponseDictionary, _ snapshot: DocumentSnapshot, _ keys: sourcekitd_api_keys) {
    guard let categorizedEdits: SKDResponseArray = dict[keys.categorizedEdits] else {
      return nil
    }

    var textEdits = [TextEdit]()

    categorizedEdits.forEach { _, value in
      guard let edits: SKDResponseArray = value[keys.edits] else {
        return false
      }
      edits.forEach { _, value in
        // The LSP is zero based, but semantic_refactoring is one based.
        guard let startLine: Int = value[keys.line],
          let startColumn: Int = value[keys.column],
          let endLine: Int = value[keys.endLine],
          let endColumn: Int = value[keys.endColumn],
          let text: String = value[keys.text]
        else {
          return true  // continue
        }
        let startPosition = snapshot.positionOf(
          zeroBasedLine: startLine - 1,
          utf8Column: startColumn - 1
        )
        let endPosition = snapshot.positionOf(
          zeroBasedLine: endLine - 1,
          utf8Column: endColumn - 1
        )
        // Snippets are only supported in code completion.
        // Remove SourceKit placeholders in refactoring actions because they can't be represented in the editor properly.
        let textWithSnippets = rewriteSourceKitPlaceholders(in: text, clientSupportsSnippets: false)
        textEdits.append(TextEdit(range: startPosition..<endPosition, newText: textWithSnippets))
        return true
      }
      return true
    }

    guard textEdits.isEmpty == false else {
      return nil
    }

    self.title = title
    self.edit = WorkspaceEdit(changes: [snapshot.uri: textEdits])
  }
}

/// An error from a semantic refactoring request.
enum SemanticRefactoringError: Error {
  /// The underlying sourcekitd request failed with the given error.
  case responseError(ResponseError)

  /// The underlying sourcekitd reported no edits for this action.
  case noEditsNeeded(DocumentURI)
}

extension SemanticRefactoringError: CustomStringConvertible {
  var description: String {
    switch self {
    case .responseError(let error):
      return "\(error)"
    case .noEditsNeeded(let url):
      return "no edits reported for semantic refactoring action for url \(url)"
    }
  }
}

extension SwiftLanguageService {
  /// Provides detailed information about the result of a specific refactoring operation.
  ///
  /// Wraps the information returned by sourcekitd's `semantic_refactoring` request, such as the necessary edits and placeholder locations.
  ///
  /// - Parameters:
  ///   - refactorCommand: The semantic refactor `Command` that triggered this request.
  func semanticRefactoring(
    _ refactorCommand: SemanticRefactorCommand
  ) async throws -> SemanticRefactoring {
    let keys = self.keys

    let uri = refactorCommand.textDocument.uri
    let snapshot = try self.documentManager.latestSnapshot(uri)
    let line = refactorCommand.positionRange.lowerBound.line
    let utf16Column = refactorCommand.positionRange.lowerBound.utf16index
    let utf8Column = snapshot.lineTable.utf8ColumnAt(line: line, utf16Column: utf16Column)

    let skreq = sourcekitd.dictionary([
      keys.request: self.requests.semanticRefactoring,
      // Preferred name for e.g. an extracted variable.
      // Empty string means sourcekitd chooses a name automatically.
      keys.name: "",
      keys.sourceFile: uri.pseudoPath,
      // LSP is zero based, but this request is 1 based.
      keys.line: line + 1,
      keys.column: utf8Column + 1,
      keys.length: snapshot.utf8OffsetRange(of: refactorCommand.positionRange).count,
      keys.actionUID: self.sourcekitd.api.uid_get_from_cstr(refactorCommand.actionString)!,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    let dict = try await self.sourcekitd.send(skreq, fileContents: snapshot.text)
    guard let refactor = SemanticRefactoring(refactorCommand.title, dict, snapshot, self.keys) else {
      throw SemanticRefactoringError.noEditsNeeded(uri)
    }
    return refactor
  }
}
