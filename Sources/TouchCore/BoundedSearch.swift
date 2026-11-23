// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// A control is unique only when every reachable node was inspected successfully.
public struct SearchSnapshot<Node> {
    public var matches: Bool
    public var children: [Node]
    public init(matches: Bool,children: [Node]) { self.matches=matches;self.children=children }
}
public struct SearchResult<Node> {
    public var matches: [Node]
    public var visited: Int
    public var complete: Bool
}
public func boundedSearch<Node: Hashable>(root: Node,limit: Int,inspect: (Node) throws -> SearchSnapshot<Node>) rethrows -> SearchResult<Node> {
    var queue=[root],seen: Set<Node>=[root],index=0,matches:[Node]=[]
    while index<queue.count,index<limit {
        let node=queue[index];index+=1
        let snapshot=try inspect(node)
        if snapshot.matches { matches.append(node) }
        for child in snapshot.children where seen.insert(child).inserted { queue.append(child) }
    }
    return SearchResult(matches:matches,visited:index,complete:index==queue.count)
}
