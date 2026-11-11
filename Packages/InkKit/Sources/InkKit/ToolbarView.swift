import SwiftUI

struct ToolbarView: View {
    @ObservedObject var controller: CanvasController
    @State private var showSettings = false
    @State private var confirmClear = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: controller.tool == tool) { controller.select(tool) }
            }

            divider

            if controller.tool == .lasso {
                Picker("Lasso", selection: $controller.lassoMode) {
                    Text("Freeform").tag(LassoMode.freeform)
                    Text("Square").tag(LassoMode.square)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                iconButton("trash", "Delete selection", enabled: controller.hasSelection) {
                    controller.deleteSelection()
                }
            } else if controller.tool == .eraser {
                Picker("Eraser", selection: $controller.eraserMode) {
                    Text("Stroke").tag(EraserMode.stroke)
                    Text("Pixel").tag(EraserMode.pixel)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            } else {
                SwatchRow(selected: colorBinding)
            }

            divider

            if controller.tool != .lasso {
                widthControl

                divider
            }

            iconButton("arrow.uturn.backward", "Undo", enabled: controller.canUndo) { controller.undo() }
            iconButton("arrow.uturn.forward", "Redo", enabled: controller.canRedo) { controller.redo() }
            iconButton("trash", "Clear canvas", enabled: controller.canUndo || controller.canRedo) { confirmClear = true }
                .confirmationDialog("Clear the canvas?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) { controller.clear() }
                } message: {
                    Text("You can undo this.")
                }

            divider

            iconButton("slider.horizontal.3", "Pressure & tilt settings") { showSettings.toggle() }
                .popover(isPresented: $showSettings) {
                    CanvasSettingsView(controller: controller)
                }
            iconButton(controller.hudVisible ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent",
                       "Toggle debug HUD", tint: controller.hudVisible ? .accentColor : .primary) {
                controller.hudVisible.toggle()
            }
            Button { controller.resetZoom() } label: {
                Text("\(Int((controller.zoom * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: 24)
    }

    private var colorBinding: Binding<Int> {
        Binding(get: { controller.current.colorIndex }, set: { controller.current.colorIndex = $0 })
    }

    private var widthControl: some View {
        let range = CanvasController.widthRange(for: controller.tool)
        return HStack(spacing: 8) {
            Slider(value: Binding(get: { controller.current.width }, set: { controller.current.width = $0 }),
                   in: range)
                .frame(width: 100)
            Circle()
                .fill(controller.tool == .eraser ? Color.secondary.opacity(0.4)
                      : Color(cgColor: RGBA.swatches[controller.current.colorIndex].cgColor()))
                .frame(width: max(4, min(controller.current.width, 28)), height: max(4, min(controller.current.width, 28)))
                .frame(width: 28, height: 28)
        }
        .accessibilityLabel("Width")
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool = true, tint: Color = .primary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 36, height: 36)
                .background(selected ? Color.accentColor : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        switch tool {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }
}

private struct SwatchRow: View {
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RGBA.swatches.indices, id: \.self) { i in
                Button { selected = i } label: {
                    Circle()
                        .fill(Color(cgColor: RGBA.swatches[i].cgColor()))
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected == i ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(i + 1)")
            }
        }
    }
}

/// Pressure response, tilt toggle and HUD toggle.
struct CanvasSettingsView: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pressure & tilt").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum width: \(Int(controller.minWidthRatio * 100))% of max")
                Slider(value: $controller.minWidthRatio, in: 0.02...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Response curve: γ = %.2f", controller.pressureGamma))
                Slider(value: $controller.pressureGamma, in: 0.25...3)
                CurvePreview(gamma: controller.pressureGamma, minRatio: controller.minWidthRatio)
                    .frame(height: 80)
                Text("γ < 1 boosts light pressure, γ > 1 needs a firmer press.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Tilt shading (wider + lighter when tilted)", isOn: $controller.tiltEnabled)
            Toggle("Debug HUD", isOn: $controller.hudVisible)

            #if targetEnvironment(simulator)
            VStack(alignment: .leading, spacing: 4) {
                Text("Simulated altitude: \(Int(controller.simulatedAltitudeDegrees))°")
                Slider(value: $controller.simulatedAltitudeDegrees, in: 5...90)
                Text("Simulator only. Lower it to try tilt shading without a Pencil.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Width (y) as a function of pressure (x).
private struct CurvePreview: View {
    let gamma: Double
    let minRatio: Double

    var body: some View {
        Canvas { ctx, size in
            var frame = Path()
            frame.addRect(CGRect(origin: .zero, size: size))
            ctx.stroke(frame, with: .color(.secondary.opacity(0.3)))
            var curve = Path()
            for i in 0...60 {
                let x = Double(i) / 60
                let y = minRatio + (1 - minRatio) * pow(x, gamma)
                let p = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
    }
}

/// Pencil Pro squeeze palette, shown at the hover location.
struct QuickPaletteView: View {
    @ObservedObject var controller: CanvasController
    let location: CGPoint

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)   // tap anywhere to dismiss
                .onTapGesture { controller.quickPaletteLocation = nil }
            HStack(spacing: 8) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, selected: controller.tool == tool) {
                        controller.select(tool)
                        controller.quickPaletteLocation = nil
                    }
                }
                Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: 24)
                SwatchRow(selected: Binding(get: { controller.current.colorIndex },
                                            set: { controller.current.colorIndex = $0
                                                   controller.quickPaletteLocation = nil }))
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
            .position(x: location.x, y: max(40, location.y - 60))
        }
    }
}
