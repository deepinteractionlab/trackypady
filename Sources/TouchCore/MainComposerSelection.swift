// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// Structural evidence only: never infer the chat target from editor focus or screen position.
public enum MainComposerSelection {
    /// Inspect the focused rich editor's ancestors in nearest-first order.
    /// A home or thread container qualifies only after the composer body was seen.
    public struct FocusedEditorContext {
        private var insideBody = false

        public init?(editorClasses: [String]) {
            guard editorClasses.contains("ProseMirror") else { return nil }
        }

        public mutating func inspect(ancestorClasses: [String]) -> Bool? {
            if ancestorClasses.contains(where: { $0.hasPrefix("ComposerLayoutBody-") }) {
                insideBody = true
            }
            if ancestorClasses.contains("group/home-composer-layout") ||
                ancestorClasses.contains(where: { $0.hasPrefix("footer-") }) {
                return insideBody
            }
            return nil
        }
    }

    public struct Node {
        public let children: [Int]
        public let editor: Bool
        public let richText: Bool
        public let recorderControl: Bool
        public let attachmentControl: Bool
        public let broadContainer: Bool
        public init(children:[Int]=[],editor:Bool=false,richText:Bool=false,recorderControl:Bool=false,attachmentControl:Bool=false,broadContainer:Bool=false) {
            self.children=children;self.editor=editor;self.richText=richText;self.recorderControl=recorderControl;self.attachmentControl=attachmentControl;self.broadContainer=broadContainer
        }
    }
    public struct Target: Equatable { public let field:Int;public let scope:Int }
    public static func resolve(_ nodes:[Node],complete:Bool) -> Target? {
        guard complete,!nodes.isEmpty else { return nil }
        func descendants(_ root:Int) -> Set<Int> {
            var stack=[root],seen=Set<Int>()
            while let id=stack.popLast() {
                guard nodes.indices.contains(id),seen.insert(id).inserted else { continue }
                stack.append(contentsOf:nodes[id].children)
            }
            return seen
        }
        let sets=nodes.indices.map(descendants)
        let scopes=nodes.indices.filter { id in
            !nodes[id].broadContainer && sets[id].contains(where:{ nodes[$0].editor }) &&
            sets[id].contains(where:{ nodes[$0].recorderControl }) && sets[id].contains(where:{ nodes[$0].attachmentControl })
        }
        // Only the smallest enclosing composer scopes count; outer chat/layout
        // containers must not swallow question replies or neighboring panels.
        let minimal=scopes.filter { id in !scopes.contains { other in other != id && sets[id].contains(other) && sets[other] != sets[id] } }
        var matches:[Target]=[]
        for scope in minimal {
            let editors=sets[scope].filter { nodes[$0].editor }
            let rich=editors.filter { nodes[$0].richText }
            if rich.count == 1,let field=rich.first { matches.append(Target(field:field,scope:scope)) }
            else if editors.count == 1,let field=editors.first { matches.append(Target(field:field,scope:scope)) }
            else { return nil }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
