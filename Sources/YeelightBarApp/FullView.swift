import SwiftUI
import AppKit
import YeelightKit

/// Full resizable window — the spacious, clearly-labelled control surface.
struct FullView: View {
    @ObservedObject var lamp: LampController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if lamp.connected {
                    whiteCard
                    ambientCard
                    effectCard
                    scenesCard
                } else {
                    finderCard
                }
            }
            .padding(20)
            .frame(width: 480, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 560, idealHeight: 760)
        .onAppear { lamp.refreshScreenPermission() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lightbulb.fill").font(.title).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("YeelightBar").font(.title2).bold()
                Text(lamp.connected ? "\(name(lamp.selected)) · \(lamp.selected?.ip ?? "")" : "не подключено")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if lamp.connected {
                Menu {
                    ForEach(lamp.devices, id: \.ip) { d in
                        Button { lamp.connect(to: d) } label: {
                            d.ip == lamp.selected?.ip ? Label("\(name(d)) · \(d.ip)", systemImage: "checkmark")
                                                      : Label("\(name(d)) · \(d.ip)", systemImage: "lightbulb")
                        }
                    }
                    Divider()
                    Button("Найти заново…") { lamp.backToDevices(); lamp.autoSearch() }
                } label: { Image(systemName: "rectangle.2.swap") }
                .menuStyle(.borderlessButton).fixedSize()

                Toggle("", isOn: Binding(get: { lamp.power }, set: { _ in lamp.togglePower() }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    // MARK: white

    private var whiteCard: some View {
        GroupBox("Белый свет (передняя панель)") {
            VStack(alignment: .leading, spacing: 14) {
                slider("Яркость", $lamp.brightness, 1...100, { "\(Int($0))%" }) { lamp.pushBrightness() }
                slider("Тёплость", $lamp.colorTempK, 2700...6500, { "\(Int($0)) K" }) { lamp.pushColorTemp() }
            }.padding(8)
        }
    }

    // MARK: ambient

    private var ambientCard: some View {
        GroupBox("Подсветка (ambient)") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Подсветка включена").font(.callout)
                    Spacer()
                    RoundedRectangle(cornerRadius: 5).fill(lamp.ambientColor).frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                    Toggle("", isOn: Binding(get: { lamp.ambientOn }, set: { lamp.setAmbientPower($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Text("Цвет — кликни/веди по полосе или выбери пресет").font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    LinearGradient(gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                                   startPoint: .leading, endPoint: .trailing)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            lamp.setAmbient(Color(hue: max(0, min(1, v.location.x / geo.size.width)), saturation: 0.9, brightness: 1))
                        })
                }
                .frame(height: 24).clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    ForEach(presets, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 7).fill(c).frame(width: 34, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.25)))
                            .onTapGesture { lamp.setAmbient(c) }
                    }
                    Spacer()
                }
            }.padding(8)
        }
    }

    // MARK: effect

    private var effectCard: some View {
        GroupBox("Эффект подсветки") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: Binding(get: { lamp.syncMode }, set: { lamp.setSyncMode($0) })) {
                    Text("Выкл").tag(SyncMode.off)
                    Text("Экран").tag(SyncMode.screen)
                    Text("Музыка").tag(SyncMode.music)
                }.pickerStyle(.segmented).labelsHidden()

                if !lamp.screenHasPermission && lamp.syncMode != .off {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Нужно разрешение «Запись экрана»").font(.callout)
                        Spacer()
                        Button("Открыть настройки") { lamp.openScreenSettings() }
                    }
                }
                if let s = lamp.screenSyncStatus ?? lamp.musicSyncStatus {
                    Text(s).font(.callout)
                        .foregroundStyle(s.hasSuffix("…") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }

                if lamp.syncMode == .screen {
                    Divider()
                    Text("Зона экрана для каждой лампы").font(.callout).bold()
                    ForEach(lamp.devices, id: \.ip) { d in
                        HStack {
                            Image(systemName: d.model == "strip8" ? "alternatingcurrent" : "lightbulb")
                            Text(name(d)).font(.callout)
                            Text(d.ip).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu(zoneLabel(lamp.syncRegions[d.ip])) {
                                Button("Выкл") { lamp.setRegion(d.ip, nil) }
                                Button("Верх") { lamp.setRegion(d.ip, .top) }
                                Button("Низ") { lamp.setRegion(d.ip, .bottom) }
                                Button("Лево") { lamp.setRegion(d.ip, .left) }
                                Button("Право") { lamp.setRegion(d.ip, .right) }
                                Button("Весь экран") { lamp.setRegion(d.ip, .full) }
                            }.fixedSize()
                        }
                    }
                    Divider()
                    slider("Размер зоны", $lamp.bandFraction, 0.1...0.6, { "\(Int($0 * 100))%" })
                    Toggle("Яркость следует за яркостью сцены", isOn: $lamp.brightnessFollow)
                    slider("Плавность", $lamp.syncSmoothing, 0.1...0.8, { "\(Int($0 * 100))%" })
                    slider("Насыщенность", $lamp.syncSaturation, 1.0...2.0, { String(format: "%.1f×", $0) })
                }
                if lamp.syncMode == .music {
                    Divider()
                    Picker("Стиль", selection: Binding(get: { lamp.musicStyle }, set: { lamp.musicStyle = $0 })) {
                        Text("Бит (бас)").tag(MusicStyle.beat)
                        Text("Спектр").tag(MusicStyle.spectrum)
                    }.pickerStyle(.segmented)
                    Text("Бит — пульс под бас/кик. Спектр — бас=красный, мид=зелёный, верха=синий.")
                        .font(.caption).foregroundStyle(.secondary)
                    slider("Чувствительность", $lamp.musicSensitivity, 2...8, { String(format: "%.1f", $0) })
                }
            }.padding(8)
        }
    }

    // MARK: scenes

    private var scenesCard: some View {
        GroupBox("Сцены") {
            HStack(spacing: 10) {
                sceneBtn("Reading", "book", 4000, 100)
                sceneBtn("Relax", "cup.and.saucer", 2700, 40)
                sceneBtn("Focus", "target", 5000, 100)
                sceneBtn("Movie", "film", 2700, 15)
                Spacer()
            }.padding(8)
        }
    }

    // MARK: finder

    private var finderCard: some View {
        GroupBox("Найти лампу") {
            VStack(alignment: .leading, spacing: 12) {
                Button { lamp.autoSearch() } label: {
                    HStack {
                        if lamp.isSearching { ProgressView().controlSize(.small) } else { Image(systemName: "antenna.radiowaves.left.and.right") }
                        Text(lamp.isSearching ? "Идёт поиск…" : "Автопоиск ламп в сети")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(lamp.isSearching)

                if let err = lamp.connectError {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
                ForEach(lamp.devices, id: \.ip) { d in
                    HStack {
                        Button { lamp.connect(to: d) } label: {
                            HStack {
                                Image(systemName: "lightbulb")
                                VStack(alignment: .leading) { Text(name(d)); Text(d.ip).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                        Button { lamp.identify(d) } label: { Image(systemName: "wand.and.rays") }.buttonStyle(.bordered).help("Мигнуть для опознания")
                    }
                }
                Divider()
                HStack {
                    TextField("IP вручную (192.168.1.x)", text: $lamp.manualIP).textFieldStyle(.roundedBorder).onSubmit { lamp.addManualIP() }
                    Button("Добавить") { lamp.addManualIP() }.disabled(lamp.manualIP.isEmpty)
                }
            }.padding(8)
        }
    }

    // MARK: helpers

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ display: @escaping (Double) -> String, _ commit: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(display(value.wrappedValue)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in if !editing { commit() } }
        }
    }

    private func sceneBtn(_ title: String, _ icon: String, _ ct: Int, _ b: Int) -> some View {
        Button { lamp.applyScene(ct: ct, bright: b) } label: {
            HStack(spacing: 5) { Image(systemName: icon); Text(title) }
        }.buttonStyle(.bordered)
    }

    private func name(_ d: DiscoveredDevice?) -> String {
        guard let d else { return "Yeelight" }
        return d.model == "lamp15" ? "Screen Light Bar Pro" : (d.model.isEmpty ? "Yeelight" : d.model)
    }
    private func zoneLabel(_ r: SyncRegion?) -> String {
        switch r {
        case .top: return "Верх"; case .bottom: return "Низ"; case .left: return "Лево"
        case .right: return "Право"; case .full: return "Весь"; case nil: return "Выкл"
        }
    }
    private let presets: [Color] = [
        Color(rgb: 0xFF5A3C), Color(rgb: 0xFFB23E), Color(rgb: 0xF5E6C8),
        Color(rgb: 0x2EC28E), Color(rgb: 0x378ADD), Color(rgb: 0xE30DFF),
    ]
}
