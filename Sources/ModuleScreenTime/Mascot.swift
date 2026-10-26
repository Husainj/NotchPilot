import SwiftUI

/// "Pilot", the little character who checks on you. Drawn entirely in SwiftUI.
struct Mascot: View {
    /// Pilot's own colour, the same whatever theme is chosen.
    static let brand = Color(red: 0.56, green: 0.49, blue: 1.0)

    var mood: Mood
    var size: CGFloat = 96
    var color: Color = Mascot.brand
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || !animated {
            MascotFace(mood: mood, size: size, color: color, bob: 0, blink: false)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let speed = mood == .happy ? 5.0 : (mood == .sleepy ? 1.2 : 2.4)
                let amount = mood == .happy ? 0.07 : 0.03
                MascotFace(mood: mood, size: size, color: color,
                           bob: sin(t * speed) * size * amount,
                           blink: t.truncatingRemainder(dividingBy: 3.7) < 0.14)
            }
        }
    }
}

private struct MascotFace: View {
    let mood: Mood
    let size: CGFloat
    let color: Color
    let bob: CGFloat
    let blink: Bool

    var body: some View {
        let s = size
        ZStack {
            // Shadow on the "floor".
            Ellipse()
                .fill(.black.opacity(0.35))
                .frame(width: s * 0.55, height: s * 0.08)
                .offset(y: s * 0.46)
                .scaleEffect(1 - bob / s)

            ZStack {
                arms(s)
                // Body.
                RoundedRectangle(cornerRadius: s * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [bodyColor.opacity(0.95), bodyColor.opacity(0.7)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.7, height: s * 0.66)
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.3, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                    .offset(y: s * 0.08)
                goggles(s)
                eyes(s)
                brows(s)
                mouth(s)
                cheeks(s)
                if mood == .sassy { crossedArms(s) }
            }
            .offset(y: -bob)

            if mood == .sleepy {
                Text("z z")
                    .font(.system(size: s * 0.14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .offset(x: s * 0.42, y: -s * 0.36 - bob)
            }
            if mood == .happy {
                Image(systemName: "sparkles")
                    .font(.system(size: s * 0.18))
                    .foregroundStyle(.yellow)
                    .offset(x: s * 0.42, y: -s * 0.34 - bob * 1.5)
            }
            if mood == .serious {
                Image(systemName: "exclamationmark")
                    .font(.system(size: s * 0.2, weight: .black))
                    .foregroundStyle(.red)
                    .offset(x: s * 0.44, y: -s * 0.3)
            }
        }
        .frame(width: s, height: s)
    }

    private var bodyColor: Color {
        mood == .serious ? Color(red: 0.95, green: 0.35, blue: 0.4) : color
    }

    private func goggles(_ s: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color(white: 0.15)).frame(width: s * 0.72, height: s * 0.07)
            HStack(spacing: s * 0.06) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle()
                        .fill(LinearGradient(colors: [.cyan.opacity(0.9), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(Color(white: 0.2), lineWidth: s * 0.025))
                        .frame(width: s * 0.17, height: s * 0.17)
                }
            }
        }
        .offset(y: -s * 0.2)
    }

    private func eyes(_ s: CGFloat) -> some View {
        let closed = blink || mood == .sleepy
        return HStack(spacing: s * 0.14) {
            ForEach(0..<2, id: \.self) { _ in
                ZStack {
                    Ellipse().fill(.white)
                    Circle().fill(.black)
                        .frame(width: s * 0.065)
                        .offset(x: mood == .sassy ? s * 0.02 : 0, y: s * 0.008)
                }
                .frame(width: s * 0.12, height: closed ? s * 0.018 : s * 0.13)
            }
        }
        .offset(y: s * 0.02)
    }

    private func brows(_ s: CGFloat) -> some View {
        let (left, right): (Double, Double) = switch mood {
        case .happy: (-8, 8)
        case .concerned: (15, -15)
        case .sassy: (0, -18)
        case .serious: (-20, 20)
        case .sleepy: (0, 0)
        }
        return HStack(spacing: s * 0.12) {
            Capsule().frame(width: s * 0.13, height: s * 0.03).rotationEffect(.degrees(left))
                .offset(y: mood == .sassy ? s * 0.01 : 0)
            Capsule().frame(width: s * 0.13, height: s * 0.03).rotationEffect(.degrees(right))
                .offset(y: mood == .sassy ? -s * 0.03 : 0)
        }
        .foregroundStyle(Color(white: 0.12))
        .offset(y: -s * 0.07)
        .opacity(mood == .sleepy ? 0 : 1)
    }

    private func mouth(_ s: CGFloat) -> some View {
        MouthShape(mood: mood)
            .stroke(Color(white: 0.1), style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round))
            .frame(width: s * 0.2, height: s * 0.08)
            .offset(y: s * 0.17)
    }

    @ViewBuilder
    private func cheeks(_ s: CGFloat) -> some View {
        if mood == .happy || mood == .concerned {
            HStack(spacing: s * 0.34) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse().fill(.pink.opacity(0.45)).frame(width: s * 0.1, height: s * 0.05)
                }
            }
            .offset(y: s * 0.12)
        }
    }

    @ViewBuilder
    private func arms(_ s: CGFloat) -> some View {
        if mood != .sassy {
            let wave = mood == .happy ? -40.0 : 20.0
            HStack(spacing: s * 0.62) {
                Capsule().fill(bodyColor.opacity(0.85)).frame(width: s * 0.09, height: s * 0.26)
                    .rotationEffect(.degrees(wave), anchor: .top)
                Capsule().fill(bodyColor.opacity(0.85)).frame(width: s * 0.09, height: s * 0.26)
                    .rotationEffect(.degrees(-wave), anchor: .top)
            }
            .offset(y: s * 0.16)
        }
    }

    private func crossedArms(_ s: CGFloat) -> some View {
        ZStack {
            Capsule().fill(bodyColor.opacity(0.6)).frame(width: s * 0.42, height: s * 0.08).rotationEffect(.degrees(12))
            Capsule().fill(bodyColor.opacity(0.75)).frame(width: s * 0.42, height: s * 0.08).rotationEffect(.degrees(-12))
        }
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1).frame(width: s * 0.42, height: s * 0.08))
        .offset(y: s * 0.3)
    }
}

private struct MouthShape: Shape {
    let mood: Mood

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = CGPoint(x: rect.minX, y: rect.midY), r = CGPoint(x: rect.maxX, y: rect.midY)
        switch mood {
        case .happy:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.4))
        case .concerned:
            p.move(to: l)
            p.addCurve(to: r, control1: CGPoint(x: rect.width * 0.33, y: rect.minY),
                       control2: CGPoint(x: rect.width * 0.66, y: rect.maxY))
        case .sassy:
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.midY + 2))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.width * 0.7, y: rect.maxY))
        case .serious:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        case .sleepy:
            p.move(to: CGPoint(x: rect.width * 0.3, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width * 0.7, y: rect.midY))
        }
        return p
    }
}
