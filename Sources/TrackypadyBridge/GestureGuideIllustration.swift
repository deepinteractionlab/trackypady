// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The guide uses the same hand and fingertip positions in every illustration.
enum GestureGuideDrawing {
    case wake, dictate, steer, queueSwipe, queueHold, discard, stop, forgetMac
}

struct GestureGuideIllustration: View {
    let drawing: GestureGuideDrawing
    @Environment(\.colorScheme) private var colorScheme

    private var cue: Color {
        colorScheme == .dark ? Color(red: 0.44, green: 0.83, blue: 0.94) : Color(red: 0.03, green: 0.50, blue: 0.64)
    }

    private var viewport: CGRect {
        switch drawing {
        case .steer: CGRect(x: 0, y: 0, width: 240, height: 224)
        case .queueSwipe, .queueHold: CGRect(x: 24, y: 5, width: 184, height: 198)
        case .stop: CGRect(x: 22, y: 18, width: 206, height: 206)
        default: CGRect(x: 22, y: 28, width: 206, height: 196)
        }
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / viewport.width, size.height / viewport.height)
            context.translateBy(x: (size.width - viewport.width * scale) / 2,
                                y: (size.height - viewport.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -viewport.minX, y: -viewport.minY)
            context.clip(to: Path(viewport))
            if drawing == .queueHold { context.translateBy(x: 0, y: -57) }

            let palm = Self.palm(raised: drawing == .queueHold)
            var markers = context
            markers.clip(to: palm, options: .inverse)
            drawCues(in: markers)
            let outline = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            context.stroke(palm, with: .color(.primary), style: outline)
            context.stroke(Self.fingerSeparations, with: .color(.primary), style: outline)
        }
        .aspectRatio(viewport.width / viewport.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func drawCues(in context: GraphicsContext) {
        let fingertips = [CGPoint(x: 96, y: 91), CGPoint(x: 111, y: 75), CGPoint(x: 131, y: 76)]
        switch drawing {
        case .forgetMac:
            let ring = Path(ellipseIn: CGRect(x: 80, y: 90, width: 32, height: 32))
            context.stroke(ring, with: .color(cue), lineWidth: 3)
            drawRepeat(in: context, at: CGPoint(x: 52, y: 80), count: 6)
        case .wake, .dictate, .queueHold:
            let tap = drawing == .wake
            let ring = Self.contactRing(radius: tap ? 16 : 19)
            let stroke = StrokeStyle(lineWidth: tap ? 3 : 6, lineCap: .round, lineJoin: .round)
            if tap {
                context.stroke(ring, with: .color(cue), style: stroke)
                drawRepeat(in: context, at: CGPoint(x: 154, y: 77))
            } else {
                context.stroke(ring, with: .color(cue.opacity(0.2)), style: stroke)
                context.stroke(ring.trimmedPath(from: 0, to: 0.72), with: .color(cue), style: stroke)
            }
        case .steer, .queueSwipe, .discard:
            for tip in fingertips {
                let top = CGPoint(x: tip.x, y: tip.y - 40)
                let down = drawing == .discard
                arrow(in: context, from: down ? top : tip, to: down ? tip : top)
            }
            if drawing == .discard { drawRepeat(in: context, at: CGPoint(x: 145, y: 55)) }
        case .stop:
            for (index, y) in [35.0, 49.0, 63.0].enumerated() {
                let rightward = index == 1
                arrow(in: context, from: CGPoint(x: rightward ? 88 : 141, y: y),
                      to: CGPoint(x: rightward ? 141 : 88, y: y))
            }
        }
    }

    private func drawRepeat(in context: GraphicsContext, at point: CGPoint, count: Int = 2) {
        context.draw(Text("×\(count)").font(.system(size: 21, weight: .semibold)).foregroundColor(cue),
                     at: point, anchor: .leading)
    }

    private func arrow(in context: GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let dx = (end.x - start.x) / length, dy = (end.y - start.y) / length
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: end.x - 4 * dx - 3.5 * dy, y: end.y - 4 * dy + 3.5 * dx))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - 4 * dx + 3.5 * dy, y: end.y - 4 * dy - 3.5 * dx))
        context.stroke(path, with: .color(cue), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
    }

    /// Join the upper arcs of three overlapping contact circles into one scalloped rim.
    private static func contactRing(radius: CGFloat) -> Path {
        let tips = [CGPoint(x: 96, y: 106), CGPoint(x: 111, y: 90), CGPoint(x: 131, y: 90)]
        var ends = [CGPoint(x: tips[0].x, y: tips[0].y + radius)]
        for (a, b) in zip(tips, tips.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let distance = hypot(dx, dy)
            let offset = sqrt(radius * radius - distance * distance / 4) / distance
            ends.append(CGPoint(x: (a.x + b.x) / 2 + dy * offset, y: (a.y + b.y) / 2 - dx * offset))
        }
        ends.append(CGPoint(x: tips[2].x, y: tips[2].y + radius))
        var path = Path()
        for (index, tip) in tips.enumerated() {
            let start = ends[index], end = ends[index + 1]
            path.addArc(center: tip, radius: radius,
                        startAngle: .radians(atan2(start.y - tip.y, start.x - tip.x)),
                        endAngle: .radians(atan2(end.y - tip.y, end.x - tip.x)), clockwise: false)
        }
        return path
    }

    private static let fingerSeparations = Path { path in
        path.move(to: CGPoint(x: 103, y: 98))
        path.addCurve(to: CGPoint(x: 114, y: 135), control1: CGPoint(x: 107, y: 106), control2: CGPoint(x: 110, y: 121))
        path.addCurve(to: CGPoint(x: 127, y: 179), control1: CGPoint(x: 118, y: 150), control2: CGPoint(x: 124, y: 170))
        path.move(to: CGPoint(x: 122, y: 89))
        path.addCurve(to: CGPoint(x: 134, y: 123), control1: CGPoint(x: 126, y: 98), control2: CGPoint(x: 130, y: 111))
        path.addCurve(to: CGPoint(x: 148, y: 163), control1: CGPoint(x: 139, y: 136), control2: CGPoint(x: 144, y: 151))
    }

    private static func palm(raised: Bool) -> Path {
        var path = Path()
        func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        }

        // The raised pose exposes a tapered lower palm. Both poses share the fingers and thumb.
        if raised {
            path.move(to: CGPoint(x: 89, y: 210))
            curve(90, 193, 87, 184, 79, 176)
            curve(67, 165, 58, 158, 53, 148)
            curve(48, 139, 46, 131, 41, 123)
        } else {
            path.move(to: CGPoint(x: 69, y: 220))
            curve(68, 196, 64, 177, 58, 164)
            curve(52, 149, 49, 135, 41, 123)
        }
        curve(37, 117, 33, 114, 30, 111)
        curve(27, 108, 29, 104, 32, 102)
        curve(37, 99, 43, 102, 49, 106)
        curve(58, 112, 67, 122, 74, 133)
        curve(79, 140, 82, 145, 85, 146)
        curve(85, 133, 84, 119, 82, 106)
        curve(79, 87, 75, 64, 73, 47)
        curve(72, 37, 70, 30, 73, 25)
        curve(76, 19, 82, 18, 87, 22)
        curve(84, 14, 85, 8, 90, 5)
        curve(96, 1, 103, 5, 106, 13)
        curve(106, 7, 110, 4, 115, 4)
        curve(122, 4, 125, 10, 129, 18)
        curve(138, 38, 148, 63, 154, 85)
        curve(155, 89, 156, 90, 156, 85)
        curve(156, 70, 154, 49, 154, 38)
        curve(154, 29, 156, 24, 161, 24)
        curve(167, 23, 170, 29, 171, 38)
        curve(174, 57, 176, 76, 178, 94)
        if raised {
            curve(179, 108, 180, 124, 179, 140)
            curve(178, 158, 176, 175, 174, 191)
            curve(173, 198, 172, 204, 171, 210)
        } else {
            curve(179, 111, 182, 129, 184, 145)
            curve(188, 167, 187, 192, 190, 220)
        }
        return path.applying(CGAffineTransform(translationX: 16, y: 76))
    }
}
