// Renders the Pulse app icon (1024×1024 PNG). Usage: MakeIcon <out.png>
import SwiftUI
import AppKit

struct PulseIcon: View {
    // macOS 26 icon grid: 824 pt squircle centred on a 1024 canvas.
    private let side: CGFloat = 824

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.36),
                                              Color(red: 0.05, green: 0.27, blue: 0.55),
                                              Color(red: 0.02, green: 0.55, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 14)

            // Faint chart grid
            Canvas { ctx, size in
                for i in 1..<4 {
                    let y = size.height * CGFloat(i) / 4
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 4, dash: [14, 16]))
                }
            }
            .frame(width: side - 140, height: side - 260)

            // Usage bars behind the pulse
            HStack(alignment: .bottom, spacing: 26) {
                ForEach(Array([0.32, 0.5, 0.38, 0.62, 0.45, 0.28].enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 70, height: 520 * v)
                }
            }
            .frame(width: side - 140, height: 520, alignment: .bottom)
            .offset(y: 95)

            // Heartbeat line with glow
            PulseLine()
                .stroke(LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 1.0),
                                                Color(red: 0.45, green: 1.0, blue: 0.6),
                                                Color(red: 1.0, green: 0.75, blue: 0.3)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 46, lineCap: .round, lineJoin: .round))
                .frame(width: side - 150, height: 420)
                .shadow(color: Color(red: 0.4, green: 1.0, blue: 0.8).opacity(0.75), radius: 30)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 6)

            // Glass sheen + rim
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.0)],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 5)
        }
        .frame(width: side, height: side)
        .frame(width: 1024, height: 1024)
    }
}

struct PulseLine: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.62), (0.26, 0.62), (0.34, 0.45), (0.42, 0.95),
                                         (0.53, 0.05), (0.62, 0.72), (0.68, 0.55), (0.74, 0.62), (1, 0.62)]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let c = CGPoint(x: r.minX + r.width * pt.0, y: r.minY + r.height * pt.1)
            i == 0 ? p.move(to: c) : p.addLine(to: c)
        }
        return p
    }
}

@main
struct MakeIcon {
    @MainActor static func main() {
        let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
        let renderer = ImageRenderer(content: PulseIcon())
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("render failed") }
        let rep = NSBitmapImageRep(cgImage: cg)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) \(cg.width)x\(cg.height)")
    }
}
