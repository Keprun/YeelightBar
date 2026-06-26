import SwiftUI
import AppKit
import YeelightKit

struct MenuPanelView: View {
    @ObservedObject var lamp: LampController
    @Environment(\.openWindow) private var openWindow

    static let ambientPresets: [Color] = [
        Color(rgb: 0xFF5A3C), Color(rgb: 0xFFB23E), Color(rgb: 0xF5E6C8),
        Color(rgb: 0x2EC28E), Color(rgb: 0x378ADD), Color(rgb: 0xE30DFF),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if lamp.connected { controlPanel } else { finder }
        }
        .frame(width: 340)
        .background(RazerBackground())
        .razerChrome()
    }

    // MARK: - Connected: control panel

    private var controlPanel: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 14) {
                frontSection
                Divider()
                ambientSection
                Divider()
                effectSection
                Divider()
                scenesSection
            }
            .padding(14)
            footer
        }
        .onAppear { lamp.refreshScreenPermission() }
    }

    // MARK: hero with a live lamp preview

    private var glowColor: Color { (lamp.screenSyncOn || lamp.musicSyncOn) ? lamp.syncColor : lamp.ambientColor }

    private func warmthColor(_ k: Double) -> Color {
        let f = max(0, min(1, (k - 2700) / 3800))
        return Color(red: 1.0 + (0.86 - 1.0) * f,
                     green: 0.85 + (0.92 - 0.85) * f,
                     blue: 0.62 + (1.0 - 0.62) * f)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroHeader
            HStack {
                Spacer()
                Capsule()
                    .fill(LinearGradient(colors: [warmthColor(lamp.colorTempK), glowColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 250, height: 9)
                    .overlay(Capsule().stroke(Color.razerGreen.opacity(0.45), lineWidth: 1))
                    .shadow(color: (lamp.power ? glowColor : .clear).opacity(0.85), radius: 14)
                    .razerPulse(lamp.power && (lamp.screenSyncOn || lamp.musicSyncOn), color: glowColor)
                    .opacity(lamp.power ? 1 : 0.35)
                Spacer()
            }
            .padding(.vertical, 18)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var heroHeader: some View {
        HStack(alignment: .top) {
            Menu {
                if !lamp.devices.isEmpty {
                    Section("Switch lamp") {
                        ForEach(lamp.devices, id: \.ip) { d in
                            Button { lamp.connect(to: d) } label: {
                                if d.ip == lamp.selected?.ip {
                                    Label(deviceLabel(d), systemImage: "checkmark")
                                } else { Text(deviceLabel(d)) }
                            }
                        }
                    }
                }
                Divider()
                Button { lamp.backToDevices(); lamp.autoSearch() } label: { Label("Rescan…", systemImage: "arrow.clockwise") }
                Button { lamp.backToDevices() } label: { Label("All devices…", systemImage: "list.bullet") }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(displayName).font(.system(size: 15, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Color.razerSecondary)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Color.razerGreen).frame(width: 6, height: 6).razerPulse(true)
                        Text("ONLINE · \(lamp.selected?.ip ?? "")").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color.razerSecondary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            Toggle("", isOn: Binding(get: { lamp.masterOn }, set: { _ in lamp.togglePower() }))
                .toggleStyle(.switch).labelsHidden().help("Вся лампа")
        }
    }

    // MARK: front (white) section

    private var frontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Front · white").font(.caption).foregroundStyle(Color.razerSecondary)
            HStack(spacing: 10) {
                Image(systemName: "sun.max").font(.system(size: 13)).foregroundStyle(Color.razerSecondary).frame(width: 18)
                Slider(value: $lamp.brightness, in: 1...100) { e in if !e { lamp.pushBrightness() } }
                Text("\(Int(lamp.brightness))%").razerHUD()
            }
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium").font(.system(size: 13)).foregroundStyle(Color.razerSecondary).frame(width: 18)
                GeometryReader { geo in
                    LinearGradient(colors: [Color(rgb: 0xFF9A3C), Color(rgb: 0xFFD9A0), Color(rgb: 0xFFF6EC), Color(rgb: 0xDFEAFF), Color(rgb: 0xBCD4FF)],
                                   startPoint: .leading, endPoint: .trailing)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in lamp.colorTempK = 2700 + max(0, min(1, v.location.x / geo.size.width)) * 3800 }
                            .onEnded { _ in lamp.pushColorTemp() })
                }
                .frame(height: 16).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(Int(lamp.colorTempK))K").razerHUD()
            }
        }
    }

    // MARK: ambient section (inline picker)

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Ambient").font(.caption).foregroundStyle(Color.razerSecondary)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(lamp.ambientColor)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Toggle("", isOn: Binding(get: { lamp.ambientOn }, set: { lamp.setAmbientPower($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            GeometryReader { geo in
                LinearGradient(gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                               startPoint: .leading, endPoint: .trailing)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let f = max(0, min(1, v.location.x / geo.size.width))
                        lamp.setAmbient(Color(hue: f, saturation: 0.9, brightness: 1))
                    })
            }
            .frame(height: 18).clipShape(RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 8) {
                ForEach(Self.ambientPresets, id: \.self) { c in
                    RoundedRectangle(cornerRadius: 5).fill(c)
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                        .onTapGesture { lamp.setAmbient(c) }
                }
                Spacer()
            }
        }
    }

    // MARK: screen-sync section

    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Эффект ambient").font(.caption).foregroundStyle(Color.razerSecondary)
            Picker("", selection: Binding(get: { lamp.syncMode }, set: { lamp.setSyncMode($0) })) {
                Text("Выкл").tag(SyncMode.off)
                Text("Экран").tag(SyncMode.screen)
                Text("Музыка").tag(SyncMode.music)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let groupDevices = lamp.devices.filter { lamp.groupIPs.contains($0.ip) }
            if !groupDevices.isEmpty {
                Text("Зона экрана (группа · \(groupDevices.count))").font(.caption2).foregroundStyle(Color.razerSecondary)
                ForEach(groupDevices, id: \.ip) { d in
                    HStack(spacing: 6) {
                        Text(friendlyName(d)).font(.caption).lineLimit(1)
                        Text(d.ip).font(.caption2).foregroundStyle(Color.razerSecondary)
                        Spacer()
                        Menu(regionLabel(lamp.displayRegion(d.ip))) {
                            Button("Верх") { lamp.setRegion(d.ip, .top) }
                            Button("Низ") { lamp.setRegion(d.ip, .bottom) }
                            Button("Лево") { lamp.setRegion(d.ip, .left) }
                            Button("Право") { lamp.setRegion(d.ip, .right) }
                            Button("Весь экран") { lamp.setRegion(d.ip, .full) }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }

            if let s = lamp.screenSyncStatus ?? lamp.musicSyncStatus {
                Text(s).font(.caption2)
                    .foregroundStyle(s.hasSuffix("…") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lamp.musicSyncOn {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5).fill(lamp.syncColor).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    Text("пульс под системный звук → ambient").font(.caption2).foregroundStyle(Color.razerSecondary)
                    Spacer()
                }
                Picker("", selection: Binding(get: { lamp.musicStyle }, set: { lamp.musicStyle = $0 })) {
                    Text("Бит").tag(MusicStyle.beat)
                    Text("Спектр").tag(MusicStyle.spectrum)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("Чувств.").font(.caption).foregroundStyle(Color.razerSecondary).frame(width: 72, alignment: .leading)
                    Slider(value: $lamp.musicSensitivity, in: 2...8)
                }
            }

            if !lamp.screenHasPermission && lamp.syncMode != .off {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Нужно разрешение «Запись экрана»").font(.caption2)
                    Spacer()
                    Button("Открыть") { lamp.openScreenSettings() }.font(.caption2).buttonStyle(.bordered).controlSize(.small)
                }
            }

            if lamp.screenSyncOn {
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4).fill(lamp.syncColor).frame(height: 56 * lamp.bandFraction)
                    }
                    .frame(width: 100, height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Источник цвета").font(.caption).foregroundStyle(Color.razerSecondary)
                        Text("верх \(Int(lamp.bandFraction * 100))% экрана").font(.caption2)
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(lamp.syncColor).frame(width: 18, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Color.razerSecondary)
                            Image(systemName: "lightbulb.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("Область").font(.caption).foregroundStyle(Color.razerSecondary).frame(width: 72, alignment: .leading)
                    Slider(value: $lamp.bandFraction, in: 0.1...0.6)
                    Text("\(Int(lamp.bandFraction * 100))%").font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing).foregroundStyle(Color.razerSecondary)
                }
                Toggle(isOn: $lamp.brightnessFollow) { Text("Яркость по сцене").font(.caption) }.toggleStyle(.switch).controlSize(.mini)
                HStack(spacing: 10) {
                    Text("Плавность").font(.caption).foregroundStyle(Color.razerSecondary).frame(width: 72, alignment: .leading)
                    Slider(value: $lamp.syncSmoothing, in: 0.1...0.8)
                }
                HStack(spacing: 10) {
                    Text("Насыщ.").font(.caption).foregroundStyle(Color.razerSecondary).frame(width: 72, alignment: .leading)
                    Slider(value: $lamp.syncSaturation, in: 1.0...2.0)
                }
            }
        }
    }

    // MARK: scenes

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scenes").font(.caption).foregroundStyle(Color.razerSecondary)
            HStack(spacing: 8) {
                sceneChip("Reading", "book", ct: 4000, b: 100)
                sceneChip("Relax", "cup.and.saucer", ct: 2700, b: 40)
                sceneChip("Focus", "target", ct: 5000, b: 100)
                sceneChip("Movie", "film", ct: 2700, b: 15)
            }
        }
    }

    private func sceneChip(_ title: String, _ icon: String, ct: Int, b: Int) -> some View {
        Button { lamp.applyScene(ct: ct, bright: b) } label: {
            HStack(spacing: 5) { Image(systemName: icon); Text(title) }.font(.caption)
        }.buttonStyle(.bordered).controlSize(.small)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { lamp.backToDevices() } label: { Label("Devices", systemImage: "rectangle.stack") }.buttonStyle(.borderless)
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: { Label("Окно", systemImage: "macwindow") }.buttonStyle(.borderless)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless)
        }
        .font(.caption).foregroundStyle(Color.razerSecondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: helpers

    private var displayName: String { lamp.selected.map(friendlyName) ?? "Yeelight" }
    private func friendlyName(_ d: DiscoveredDevice) -> String {
        d.model == "lamp15" ? "Screen Light Bar Pro" : (d.model.isEmpty ? "Yeelight" : d.model)
    }
    private func deviceLabel(_ d: DiscoveredDevice) -> String { "\(friendlyName(d)) · \(d.ip)" }

    private func regionLabel(_ r: SyncRegion?) -> String {
        switch r {
        case .top: return "Верх"
        case .bottom: return "Низ"
        case .left: return "Лево"
        case .right: return "Право"
        case .full: return "Весь"
        case nil: return "Выкл"
        }
    }

    // MARK: - Not connected: finder

    private var finder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your lamp").font(.headline)

            Button { lamp.autoSearch() } label: {
                HStack {
                    if lamp.isSearching { ProgressView().controlSize(.small) }
                    else { Image(systemName: "antenna.radiowaves.left.and.right") }
                    Text(lamp.isSearching ? "Searching…" : "Auto-search")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(lamp.isSearching)

            if lamp.connecting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…").font(.caption).foregroundStyle(Color.razerSecondary) }
            }
            if let err = lamp.connectError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            if !lamp.devices.isEmpty {
                Text("Found \(lamp.devices.count) — tap to connect, ⚡ to blink & identify")
                    .font(.caption).foregroundStyle(Color.razerSecondary)
                ForEach(lamp.devices, id: \.ip) { d in
                    HStack(spacing: 8) {
                        Button { lamp.connect(to: d) } label: {
                            HStack {
                                Image(systemName: "lightbulb")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(friendlyName(d))
                                    Text(d.ip).font(.caption).foregroundStyle(Color.razerSecondary)
                                }
                                Spacer()
                                if d.ip == lamp.selected?.ip {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                        Button { lamp.identify(d) } label: { Image(systemName: "wand.and.rays") }
                            .buttonStyle(.bordered).help("Blink this lamp to identify it")
                    }
                }
            }

            Divider()
            Text("Or enter IP manually").font(.caption).foregroundStyle(Color.razerSecondary)
            HStack {
                TextField("192.168.1.x", text: $lamp.manualIP).textFieldStyle(.roundedBorder).onSubmit { lamp.addManualIP() }
                Button("Add") { lamp.addManualIP() }.disabled(lamp.manualIP.isEmpty)
            }
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("Открыть полное окно", systemImage: "macwindow")
            }.buttonStyle(.bordered).frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}
