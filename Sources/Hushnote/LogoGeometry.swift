import CoreGraphics

/// The Hushnote mark, generated from design/Hushnote_Logo.svg (viewBox 709 x 699, SVG coordinates, y down).
/// The H carries the wordmark; the pill in its pinched crossbar is the voice, drawn in the signal colour.
/// Regenerate with scripts/make-logo-geometry.py rather than editing by hand.
enum LogoGeometry {
    static let size = CGSize(width: 709, height: 699)
    static let pill = CGRect(x: 318, y: 233, width: 73, height: 220)
    static let mark: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 136, y: 0))
        p.addCurve(to: CGPoint(x: 184, y: 48), control1: CGPoint(x: 162.51, y: 0), control2: CGPoint(x: 184, y: 21.4903))
        p.addLine(to: CGPoint(x: 184, y: 262.02))
        p.addCurve(to: CGPoint(x: 222.98, y: 301), control1: CGPoint(x: 184, y: 283.548), control2: CGPoint(x: 201.452, y: 301))
        p.addCurve(to: CGPoint(x: 260.236, y: 273.483), control1: CGPoint(x: 240.092, y: 301), control2: CGPoint(x: 255.204, y: 289.839))
        p.addLine(to: CGPoint(x: 270.385, y: 240.5))
        p.addCurve(to: CGPoint(x: 352.299, y: 180), control1: CGPoint(x: 281.45, y: 204.539), control2: CGPoint(x: 314.674, y: 180))
        p.addLine(to: CGPoint(x: 356.701, y: 180))
        p.addCurve(to: CGPoint(x: 438.615, y: 240.5), control1: CGPoint(x: 394.326, y: 180), control2: CGPoint(x: 427.55, y: 204.539))
        p.addLine(to: CGPoint(x: 448.764, y: 273.483))
        p.addCurve(to: CGPoint(x: 486.02, y: 301), control1: CGPoint(x: 453.796, y: 289.839), control2: CGPoint(x: 468.908, y: 301))
        p.addCurve(to: CGPoint(x: 525, y: 262.02), control1: CGPoint(x: 507.548, y: 301), control2: CGPoint(x: 525, y: 283.548))
        p.addLine(to: CGPoint(x: 525, y: 48))
        p.addCurve(to: CGPoint(x: 573, y: 0), control1: CGPoint(x: 525, y: 21.4903), control2: CGPoint(x: 546.49, y: 0))
        p.addLine(to: CGPoint(x: 661, y: 0))
        p.addCurve(to: CGPoint(x: 709, y: 48), control1: CGPoint(x: 687.51, y: 0), control2: CGPoint(x: 709, y: 21.4903))
        p.addLine(to: CGPoint(x: 709, y: 651))
        p.addCurve(to: CGPoint(x: 661, y: 699), control1: CGPoint(x: 709, y: 677.51), control2: CGPoint(x: 687.51, y: 699))
        p.addLine(to: CGPoint(x: 573, y: 699))
        p.addCurve(to: CGPoint(x: 525, y: 651), control1: CGPoint(x: 546.49, y: 699), control2: CGPoint(x: 525, y: 677.51))
        p.addLine(to: CGPoint(x: 525, y: 422.98))
        p.addCurve(to: CGPoint(x: 486.02, y: 384), control1: CGPoint(x: 525, y: 401.452), control2: CGPoint(x: 507.548, y: 384))
        p.addCurve(to: CGPoint(x: 448.764, y: 411.517), control1: CGPoint(x: 468.908, y: 384), control2: CGPoint(x: 453.796, y: 395.161))
        p.addLine(to: CGPoint(x: 438.615, y: 444.5))
        p.addCurve(to: CGPoint(x: 356.701, y: 505), control1: CGPoint(x: 427.55, y: 480.461), control2: CGPoint(x: 394.326, y: 505))
        p.addLine(to: CGPoint(x: 352.299, y: 505))
        p.addCurve(to: CGPoint(x: 270.385, y: 444.5), control1: CGPoint(x: 314.674, y: 505), control2: CGPoint(x: 281.45, y: 480.461))
        p.addLine(to: CGPoint(x: 260.236, y: 411.517))
        p.addCurve(to: CGPoint(x: 222.98, y: 384), control1: CGPoint(x: 255.204, y: 395.161), control2: CGPoint(x: 240.092, y: 384))
        p.addCurve(to: CGPoint(x: 184, y: 422.98), control1: CGPoint(x: 201.452, y: 384), control2: CGPoint(x: 184, y: 401.452))
        p.addLine(to: CGPoint(x: 184, y: 651))
        p.addCurve(to: CGPoint(x: 136, y: 699), control1: CGPoint(x: 184, y: 677.51), control2: CGPoint(x: 162.51, y: 699))
        p.addLine(to: CGPoint(x: 48, y: 699))
        p.addCurve(to: CGPoint(x: 0, y: 651), control1: CGPoint(x: 21.4903, y: 699), control2: CGPoint(x: 0, y: 677.51))
        p.addLine(to: CGPoint(x: 0, y: 48))
        p.addCurve(to: CGPoint(x: 48, y: 0), control1: CGPoint(x: 0, y: 21.4903), control2: CGPoint(x: 21.4903, y: 0))
        p.addLine(to: CGPoint(x: 136, y: 0))
        p.closeSubpath()
        return p
    }()
    static let pillPath = CGPath(roundedRect: pill, cornerWidth: 36.5, cornerHeight: 36.5, transform: nil)

    /// Aspect-fits the artwork into a y-down `rect`.
    static func transform(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / size.width, rect.height / size.height)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: rect.midX - size.width * scale / 2, ty: rect.midY - size.height * scale / 2)
    }
}
