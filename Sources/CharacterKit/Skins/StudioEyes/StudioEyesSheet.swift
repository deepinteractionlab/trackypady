// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

enum EyeAnimation: String, CaseIterable {
    case idle, dictation, recordingError, steer, queue, stopLeft, stopRight, select, discard
}

struct StudioEyesSheet: Decodable {
    struct RGB: Decodable {
        let red, green, blue: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
    }
    struct Presets: Decodable { let idle, dictation, sleep: String }
    struct Animation: Decodable { let position: String? }

    struct Position: Decodable, Equatable {
        let x, y, heightFraction, horizontalPadding, verticalPadding: CGFloat

        var isValid: Bool {
            (0...1).contains(x) && (0...1).contains(y) && heightFraction > 0 && heightFraction <= 1
                && horizontalPadding >= 0 && verticalPadding >= 0
        }

        func layout(in screen: CGSize, drawing: CGSize, headroom: CGFloat) -> (scale: CGFloat, center: CGPoint) {
            let band = screen.height * heightFraction
            let width = max(0, screen.width - 2 * horizontalPadding)
            let height = max(0, band - 2 * verticalPadding)
            let scale = min(1, width / drawing.width, height / (drawing.height + headroom))
            let halfWidth = drawing.width * scale / 2
            let halfHeight = drawing.height * scale / 2
            let marginX = min(screen.width / 2, horizontalPadding + halfWidth)
            let centerX = min(max(screen.width * x, marginX), screen.width - marginX)
            let bandCenter = min(max(screen.height * y, band / 2), screen.height - band / 2)
            let flightClearance = max(0, halfHeight + headroom * scale - height / 2)
            return (scale, CGPoint(x: centerX, y: bandCenter + flightClearance))
        }
    }

    let presets: Presets
    let background, ink: RGB
    let positions: [String: Position]
    let defaultPosition: String
    let animations: [String: Animation]

    func position(for animation: EyeAnimation) -> Position {
        // All references are validated when the sheet loads.
        positions[animations[animation.rawValue]?.position ?? defaultPosition]!
    }

    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard positions[defaultPosition] != nil, positions.values.allSatisfy(\.isValid),
              Set(animations.keys) == Set(EyeAnimation.allCases.map(\.rawValue)),
              animations.values.allSatisfy({ positions[$0.position ?? defaultPosition] != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid animation or position in \(url.lastPathComponent)"))
        }
    }
}
