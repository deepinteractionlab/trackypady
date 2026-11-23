// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class MainComposerSelectionTests: XCTestCase {
    typealias Node=MainComposerSelection.Node
    func testFocusedThreadAndNewChatEditorsRequireComposerBodyInsideRecognizedContainer() throws {
        for container in ["footer-A8ZvKV", "group/home-composer-layout"] {
            var main = try XCTUnwrap(MainComposerSelection.FocusedEditorContext(editorClasses: ["ProseMirror", "ProseMirror-focused"]))
            XCTAssertNil(main.inspect(ancestorClasses: ["ComposerLayoutBody-uBBf1A"]))
            XCTAssertEqual(main.inspect(ancestorClasses: [container]), true)

            var side = try XCTUnwrap(MainComposerSelection.FocusedEditorContext(editorClasses: ["ProseMirror"]))
            XCTAssertEqual(side.inspect(ancestorClasses: [container]), false)
        }
        var unrelated = try XCTUnwrap(MainComposerSelection.FocusedEditorContext(editorClasses: ["ProseMirror"]))
        XCTAssertNil(unrelated.inspect(ancestorClasses: ["ComposerLayoutBody-uBBf1A"]))
        XCTAssertNil(unrelated.inspect(ancestorClasses: ["@container/left-panel", "some-home-composer-layout"]))
        XCTAssertNil(MainComposerSelection.FocusedEditorContext(editorClasses: ["search-input"]))
    }

    func testMainComposerIsIndependentOfSidePanelEditors() {
        // Window: main chat, MD editor and search field. Only chat owns both controls.
        let nodes:[Node]=[.init(children:[1,5,6],broadContainer:true),.init(children:[2,3,4]),
            .init(editor:true,richText:true),.init(recorderControl:true),.init(attachmentControl:true),
            .init(editor:true),.init(editor:true)]
        let target=MainComposerSelection.resolve(nodes,complete:true)
        XCTAssertEqual(target?.field,2);XCTAssertEqual(target?.scope,1)
    }
    func testQuestionReplyInsideChatLayoutCannotOverrideMainRichTextInput() {
        let nodes:[Node]=[.init(children:[1],broadContainer:true),.init(children:[2,3,4,5]),
            .init(editor:true,richText:true),.init(recorderControl:true),.init(attachmentControl:true),.init(editor:true)]
        XCTAssertEqual(MainComposerSelection.resolve(nodes,complete:true)?.field,2)
    }
    func testNearestScopeExcludesRichTextSidePanelAndQuestionReply() {
        let nodes:[Node]=[.init(children:[1,6],broadContainer:true),.init(children:[2,5]),.init(children:[3,4,7]),
            .init(editor:true),.init(recorderControl:true),.init(editor:true),.init(editor:true,richText:true),.init(attachmentControl:true)]
        let target=MainComposerSelection.resolve(nodes,complete:true)
        XCTAssertEqual(target?.field,3);XCTAssertEqual(target?.scope,2)
    }
    func testMultipleMainComposersAndAmbiguousEditorsFailClosed() {
        let duplicate:[Node]=[.init(children:[1,5],broadContainer:true),.init(children:[2,3,4]),.init(editor:true),.init(recorderControl:true),.init(attachmentControl:true),
            .init(children:[6,7,8]),.init(editor:true),.init(recorderControl:true),.init(attachmentControl:true)]
        XCTAssertNil(MainComposerSelection.resolve(duplicate,complete:true))
        let editors:[Node]=[.init(children:[1,2,3,4]),.init(editor:true,richText:true),.init(editor:true,richText:true),.init(recorderControl:true),.init(attachmentControl:true)]
        XCTAssertNil(MainComposerSelection.resolve(editors,complete:true))
    }
    func testIncompleteOrWindowWideEvidenceDoesNotAuthorizeFocus() {
        let nodes:[Node]=[.init(children:[1,2,3],broadContainer:true),.init(editor:true),.init(recorderControl:true),.init(attachmentControl:true)]
        XCTAssertNil(MainComposerSelection.resolve(nodes,complete:true))
        let scoped:[Node]=[.init(children:[1,2,3]),.init(editor:true),.init(recorderControl:true),.init(attachmentControl:true)]
        XCTAssertNil(MainComposerSelection.resolve(scoped,complete:false))
        XCTAssertNotNil(MainComposerSelection.resolve(scoped,complete:true))
    }
    func testAnUnrelatedFocusedEditorWithoutChatControlsIsNotEnough() {
        let nodes:[Node]=[.init(children:[1]),.init(editor:true,richText:true)]
        XCTAssertNil(MainComposerSelection.resolve(nodes,complete:true))
    }
}
