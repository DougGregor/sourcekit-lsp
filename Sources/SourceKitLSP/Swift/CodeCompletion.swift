//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import LanguageServerProtocol
import SourceKitD
import SwiftBasicFormat

extension SwiftLanguageService {
  public func completion(_ req: CompletionRequest) async throws -> CompletionList {
    let snapshot = try documentManager.latestSnapshot(req.textDocument.uri)

    let completionPos = await adjustPositionToStartOfIdentifier(req.position, in: snapshot)

    guard let offset = snapshot.utf8Offset(of: completionPos) else {
      return CompletionList(isIncomplete: true, items: [])
    }

    let options = req.sourcekitlspOptions ?? serverOptions.completionOptions

    guard let start = snapshot.indexOf(utf8Offset: offset),
      let end = snapshot.index(of: req.position)
    else {
      return CompletionList(isIncomplete: true, items: [])
    }

    let filterText = String(snapshot.text[start..<end])

    let clientSupportsSnippets =
      capabilityRegistry.clientCapabilities.textDocument?.completion?.completionItem?.snippetSupport ?? false
    let buildSettings = await buildSettings(for: snapshot.uri)

    let inferredIndentationWidth = BasicFormat.inferIndentation(of: await syntaxTreeManager.syntaxTree(for: snapshot))

    return try await CodeCompletionSession.completionList(
      sourcekitd: sourcekitd,
      snapshot: snapshot,
      indentationWidth: inferredIndentationWidth,
      completionPosition: completionPos,
      completionUtf8Offset: offset,
      cursorPosition: req.position,
      compileCommand: buildSettings,
      options: options,
      clientSupportsSnippets: clientSupportsSnippets,
      filterText: filterText
    )
  }
}
