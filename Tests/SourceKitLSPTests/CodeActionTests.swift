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

import LSPTestSupport
import LanguageServerProtocol
import SKTestSupport
import SourceKitLSP
import XCTest

final class CodeActionTests: XCTestCase {

  typealias CodeActionCapabilities = TextDocumentClientCapabilities.CodeAction
  typealias CodeActionLiteralSupport = CodeActionCapabilities.CodeActionLiteralSupport
  typealias CodeActionKindCapabilities = CodeActionLiteralSupport.CodeActionKind

  private func clientCapabilitiesWithCodeActionSupport() -> ClientCapabilities {
    var documentCapabilities = TextDocumentClientCapabilities()
    var codeActionCapabilities = CodeActionCapabilities()
    let codeActionKinds = CodeActionKindCapabilities(valueSet: [.refactor, .quickFix])
    let codeActionLiteralSupport = CodeActionLiteralSupport(codeActionKind: codeActionKinds)
    codeActionCapabilities.codeActionLiteralSupport = codeActionLiteralSupport
    documentCapabilities.codeAction = codeActionCapabilities
    documentCapabilities.completion = .init(completionItem: .init(snippetSupport: true))
    return ClientCapabilities(workspace: nil, textDocument: documentCapabilities)
  }

  func testCodeActionResponseLegacySupport() throws {
    let command = Command(title: "Title", command: "Command", arguments: [1, "text", 2.2, nil])
    let codeAction = CodeAction(title: "1")
    let codeAction2 = CodeAction(title: "2", command: command)

    var capabilities: TextDocumentClientCapabilities.CodeAction
    var capabilityJson: String
    var data: Data
    var response: CodeActionRequestResponse
    capabilityJson =
      """
       {
         "dynamicRegistration": true,
         "codeActionLiteralSupport" : {
           "codeActionKind": {
             "valueSet": []
           }
         }
       }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )
    response = .init(codeActions: [codeAction, codeAction2], clientCapabilities: capabilities)
    let actions = try JSONDecoder().decode([CodeAction].self, from: JSONEncoder().encode(response))
    XCTAssertEqual(actions, [codeAction, codeAction2])

    capabilityJson =
      """
      {
        "dynamicRegistration": true
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )
    response = .init(codeActions: [codeAction, codeAction2], clientCapabilities: capabilities)
    let commands = try JSONDecoder().decode([Command].self, from: JSONEncoder().encode(response))
    XCTAssertEqual(commands, [command])
  }

  func testCodeActionResponseIgnoresSupportedKinds() throws {
    // The client guarantees that unsupported kinds will be handled, and in
    // practice some clients use `"codeActionKind":{"valueSet":[]}`, since
    // they support all kinds anyway. So to avoid filtering all actions, we
    // ignore the supported kinds.

    let unspecifiedAction = CodeAction(title: "Unspecified")
    let refactorAction = CodeAction(title: "Refactor", kind: .refactor)
    let quickfixAction = CodeAction(title: "Quickfix", kind: .quickFix)
    let actions = [unspecifiedAction, refactorAction, quickfixAction]

    var capabilities: TextDocumentClientCapabilities.CodeAction
    var capabilityJson: String
    var data: Data
    var response: CodeActionRequestResponse
    capabilityJson =
      """
      {
        "dynamicRegistration": true,
        "codeActionLiteralSupport" : {
          "codeActionKind": {
            "valueSet": ["refactor"]
          }
        }
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )

    response = .init(codeActions: actions, clientCapabilities: capabilities)
    XCTAssertEqual(response, .codeActions([unspecifiedAction, refactorAction, quickfixAction]))

    capabilityJson =
      """
      {
        "dynamicRegistration": true,
        "codeActionLiteralSupport" : {
          "codeActionKind": {
            "valueSet": []
          }
        }
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )

    response = .init(codeActions: actions, clientCapabilities: capabilities)
    XCTAssertEqual(response, .codeActions([unspecifiedAction, refactorAction, quickfixAction]))
  }

  func testCodeActionResponseCommandMetadataInjection() throws {
    let url = URL(fileURLWithPath: "/a.swift")
    let textDocument = TextDocumentIdentifier(url)
    let expectedMetadata: LSPAny = try {
      let metadata = SourceKitLSPCommandMetadata(textDocument: textDocument)
      let data = try JSONEncoder().encode(metadata)
      return try JSONDecoder().decode(LSPAny.self, from: data)
    }()
    XCTAssertEqual(expectedMetadata, .dictionary(["sourcekitlsp_textDocument": ["uri": "file:///a.swift"]]))
    let command = Command(title: "Title", command: "Command", arguments: [1, "text", 2.2, nil])
    let codeAction = CodeAction(title: "1")
    let codeAction2 = CodeAction(title: "2", command: command)
    let request = CodeActionRequest(
      range: Position(line: 0, utf16index: 0)..<Position(line: 1, utf16index: 1),
      context: .init(diagnostics: [], only: nil),
      textDocument: textDocument
    )
    var response = request.injectMetadata(toResponse: .commands([command]))
    XCTAssertEqual(
      response,
      .commands([
        Command(
          title: command.title,
          command: command.command,
          arguments: command.arguments! + [expectedMetadata]
        )
      ])
    )
    response = request.injectMetadata(toResponse: .codeActions([codeAction, codeAction2]))
    XCTAssertEqual(
      response,
      .codeActions([
        codeAction,
        CodeAction(
          title: codeAction2.title,
          command: Command(
            title: command.title,
            command: command.command,
            arguments: command.arguments! + [expectedMetadata]
          )
        ),
      ])
    )
    response = request.injectMetadata(toResponse: nil)
    XCTAssertNil(response)
  }

  func testCommandEncoding() throws {
    let dictionary: LSPAny = ["1": [nil, 2], "2": "text", "3": ["4": [1, 2]]]
    let array: LSPAny = [1, [2, "string"], dictionary]
    let arguments: LSPAny = [1, 2.2, "text", nil, array, dictionary]
    let command = Command(title: "Command", command: "command.id", arguments: [arguments, arguments])
    let decoded = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(decoded, command)
  }

  func testEmptyCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func foo() -> String {
        var a = "hello"
      1️⃣  return a
      }

      """,
      uri: uri
    )

    let request = CodeActionRequest(
      range: positions["1️⃣"]..<positions["1️⃣"],
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)
    XCTAssertEqual(result, .codeActions([]))
  }

  func testSemanticRefactorLocalRenameResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func localRename() {
        var 1️⃣local = 1
        _ = local
      }
      """,
      uri: uri
    )

    let request = CodeActionRequest(
      range: positions["1️⃣"]..<positions["1️⃣"],
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)
    XCTAssertEqual(result, .codeActions([]))
  }

  func testSemanticRefactorLocationCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func foo() -> String {
        var a = "1️⃣"
        return a
      }
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    let expectedCommandArgs: LSPAny = [
      "actionString": "source.refactoring.kind.localize.string",
      "positionRange": [
        "start": [
          "character": .int(testPosition.utf16index),
          "line": .int(testPosition.line),
        ],
        "end": [
          "character": .int(testPosition.utf16index),
          "line": .int(testPosition.line),
        ],
      ],
      "title": "Localize String",
      "textDocument": ["uri": .string(uri.stringValue)],
    ]

    let metadataArguments: LSPAny = ["sourcekitlsp_textDocument": ["uri": .string(uri.stringValue)]]
    let expectedCommand = Command(
      title: "Localize String",
      command: "semantic.refactor.command",
      arguments: [expectedCommandArgs] + [metadataArguments]
    )
    let expectedCodeAction = CodeAction(
      title: "Localize String",
      kind: .refactor,
      command: expectedCommand
    )

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    XCTAssertTrue(codeActions.contains(expectedCodeAction))

    // Make sure we get one of the swift-syntax refactoring actions.
    XCTAssertTrue(
      codeActions.contains { action in
        return action.title == "Convert string literal to minimal number of \'#\'s"
      }
    )
  }

  func testSemanticRefactorRangeCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func foo() -> String {
        1️⃣var a = "hello"
        return a2️⃣
      }
      """,
      uri: uri
    )

    let startPosition = positions["1️⃣"]
    let endPosition = positions["2️⃣"]
    let request = CodeActionRequest(
      range: startPosition..<endPosition,
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    let expectedCommandArgs: LSPAny = [
      "actionString": "source.refactoring.kind.extract.function",
      "positionRange": [
        "start": [
          "character": .int(startPosition.utf16index),
          "line": .int(startPosition.line),
        ],
        "end": [
          "character": .int(endPosition.utf16index),
          "line": .int(endPosition.line),
        ],
      ],
      "title": "Extract Method",
      "textDocument": ["uri": .string(uri.stringValue)],
    ]
    let metadataArguments: LSPAny = ["sourcekitlsp_textDocument": ["uri": .string(uri.stringValue)]]
    let expectedCommand = Command(
      title: "Extract Method",
      command: "semantic.refactor.command",
      arguments: [expectedCommandArgs] + [metadataArguments]
    )
    let expectedCodeAction = CodeAction(
      title: "Extract Method",
      kind: .refactor,
      command: expectedCommand
    )

    guard case .codeActions(var resultActions) = result else {
      XCTFail("Result doesn't have code actions: \(String(describing: result))")
      return
    }

    // Filter out "Add documentation"; we test it elsewhere
    if let addDocIndex = resultActions.firstIndex(where: {
      $0.title == "Add documentation"
    }
    ) {
      resultActions.remove(at: addDocIndex)
    } else {
      XCTFail("Missing 'Add documentation'.")
      return
    }

    XCTAssertEqual(resultActions, [expectedCodeAction])
  }

  func testCodeActionsRemovePlaceholders() async throws {
    let testClient = try await TestSourceKitLSPClient(
      capabilities: clientCapabilitiesWithCodeActionSupport(),
      usePullDiagnostics: false
    )
    let uri = DocumentURI.for(.swift)

    let positions = testClient.openDocument(
      """
      protocol MyProto {
        func foo()
      }

      struct 1️⃣MyStruct: MyProto {

      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.uri, uri)
    XCTAssertEqual(diags.diagnostics.count, 1)

    let textDocument = TextDocumentIdentifier(uri)
    let actionsRequest = CodeActionRequest(
      range: positions["1️⃣"]..<positions["1️⃣"],
      context: .init(diagnostics: diags.diagnostics),
      textDocument: textDocument
    )
    let actionResult = try await testClient.send(actionsRequest)

    guard case .codeActions(let codeActions) = actionResult else {
      return XCTFail("Expected code actions, not commands as a response")
    }

    // Check that the Fix-It action contains snippets

    guard let quickFixAction = codeActions.filter({ $0.kind == .quickFix }).spm_only else {
      return XCTFail("Expected exactly one quick fix action")
    }
    guard let change = quickFixAction.edit?.changes?[uri]?.spm_only else {
      return XCTFail("Expected exactly one change")
    }
    XCTAssertEqual(
      change.newText.trimmingTrailingWhitespace(),
      """

          func foo() {

          }

      """
    )

    // Check that the refactor action contains snippets
    guard let refactorAction = codeActions.filter({ $0.kind == .refactor }).spm_only else {
      return XCTFail("Expected exactly one refactor action")
    }
    guard let command = refactorAction.command else {
      return XCTFail("Expected the refactor action to have a command")
    }

    let editReceived = self.expectation(description: "Received ApplyEdit request")

    testClient.handleNextRequest { (request: ApplyEditRequest) -> ApplyEditResponse in
      defer {
        editReceived.fulfill()
      }
      guard let change = request.edit.changes?[uri]?.spm_only else {
        XCTFail("Expected exactly one edit")
        return ApplyEditResponse(applied: false, failureReason: "Expected exactly one edit")
      }
      XCTAssertEqual(
        change.newText.trimmingTrailingWhitespace(),
        """

            func foo() {

            }

        """
      )
      return ApplyEditResponse(applied: true, failureReason: nil)
    }
    _ = try await testClient.send(ExecuteCommandRequest(command: command.command, arguments: command.arguments))

    try await fulfillmentOfOrThrow([editReceived])
  }

  func testAddDocumentationCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      2️⃣func refacto1️⃣r(syntax: DeclSyntax, in context: Void) -> DeclSyntax? { }3️⃣
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get an add-documentation action.
    let addDocAction = codeActions.first { action in
      return action.title == "Add documentation"
    }
    XCTAssertNotNil(addDocAction)
  }

  func testCodeActionForFixItsProducedBySwiftSyntax() async throws {
    let project = try await MultiFileTestProject(files: [
      "test.swift": "protocol 1️⃣Multi 2️⃣ident 3️⃣{}",
      "compile_commands.json": "[]",
    ])

    let (uri, positions) = try project.openDocument("test.swift")

    let report = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let fullReport) = report else {
      XCTFail("Expected full diagnostics report")
      return
    }

    XCTAssertEqual(fullReport.items.count, 1)
    let diagnostic = try XCTUnwrap(fullReport.items.first)
    let codeActions = try XCTUnwrap(diagnostic.codeActions)

    let expectedCodeActions = [
      CodeAction(
        title: "Join the identifiers together",
        kind: .quickFix,
        edit: WorkspaceEdit(
          changes: [
            uri: [
              TextEdit(range: positions["1️⃣"]..<positions["2️⃣"], newText: "Multiident "),
              TextEdit(range: positions["2️⃣"]..<positions["3️⃣"], newText: ""),
            ]
          ]
        )
      ),
      CodeAction(
        title: "Join the identifiers together with camel-case",
        kind: .quickFix,
        edit: WorkspaceEdit(
          changes: [
            uri: [
              TextEdit(range: positions["1️⃣"]..<positions["2️⃣"], newText: "MultiIdent "),
              TextEdit(range: positions["2️⃣"]..<positions["3️⃣"], newText: ""),
            ]
          ]
        )
      ),
    ]
    XCTAssertEqual(expectedCodeActions, codeActions)
  }

  func testPackageManifestEditingCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      // swift-tools-version: 5.5
      let package = Package(
          name: "packages",
          targets: [
              .tar1️⃣get(name: "MyLib"),
          ]
      )
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get the expected package manifest editing actions.
    let addTestAction = codeActions.first { action in
      return action.title == "Add test target"
    }
    XCTAssertNotNil(addTestAction)

    guard let addTestChanges = addTestAction?.edit?.documentChanges else {
      XCTFail("Didn't have changes in the 'Add test target' action")
      return
    }

    guard
      let addTestEdit = addTestChanges.lazy.compactMap({ change in
        switch change {
        case .textDocumentEdit(let edit): edit
        default: nil
        }
      }).first
    else {
      XCTFail("Didn't have edits")
      return
    }

    XCTAssertTrue(
      addTestEdit.edits.contains { edit in
        switch edit {
        case .textEdit(let edit): edit.newText.contains("testTarget")
        case .annotatedTextEdit(let edit): edit.newText.contains("testTarget")
        }
      }
    )

    XCTAssertTrue(
      codeActions.contains { action in
        return action.title == "Add product to export this target"
      }
    )
  }

  func testPackageManifestEditingCodeActionNoTestResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport())
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      // swift-tools-version: 5.5
      let package = Package(
          name: "packages",
          targets: [
              .testTar1️⃣get(name: "MyLib"),
          ]
      )
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get the expected package manifest editing actions.
    XCTAssertTrue(
      !codeActions.contains { action in
        return action.title == "Add test target"
      }
    )

    XCTAssertTrue(
      !codeActions.contains { action in
        return action.title == "Add product to export this target"
      }
    )
  }
}
