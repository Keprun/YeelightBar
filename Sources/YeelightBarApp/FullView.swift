import SwiftUI
import AppKit
import YeelightKit

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case control, effects, scenes, devices
    var id: String { rawValue }
    var title: String {
        switch self {
        case .control: return "Свет"
        case .effects: return "Эффекты"
        case .scenes: return "Сцены"
        case .devices: return "Устройства"
        }
    }
    var icon: String {
        switch self {
        case .control: return "sun.max.fill"
        case .effects: return "sparkles.tv.fill"
        case .scenes: return "theatermasks.fill"
        case .devices: return "lightbulb.fill"
        }
    }
}

/// Full native window — sidebar + spacious detail pane.
struct FullView: View {
    @ObservedObject var lamp: LampController
    @State private var section: AppSection = .control
    @State private var assignTarget: CGDirectDisplayID?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader.padding(14)
                Rectangle().fill(Color.razerHairline).frame(height: 1)
                List(AppSection.allCases, selection: $section) { s in
                    Label(s.title, systemImage: s.icon)
                        .font(.system(size: 12, weight: .bold)).textCase(.uppercase).tracking(0.8)
                        .tag(s)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(Color.razerBG)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
        } detail: {
            ZStack {
                RazerBackground()
                ScrollView {
                    detail
                        .padding(28)
                        .frame(maxWidth: 660, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 580, idealHeight: 680)
        .razerChrome()
        .onAppear { lamp.refreshScreenPermission(); lamp.refreshDisplays() }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.title3)
                .foregroundStyle(Color.razerGreen)
                .shadow(color: .razerGreen.opacity(0.7), radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(lamp.connected ? name(lamp.selected) : "YEELIGHTBAR")
                    .razerHeading(13).lineLimit(1)
                Text(lamp.connected ? headerSubtitle : "не подключено")
                    .font(.system(size: 10, weight: .medium)).textCase(.uppercase).tracking(0.5)
                    .foregroundStyle(Color.razerSecondary)
            }
            Spacer()
            if lamp.connected {
                Toggle("", isOn: Binding(get: { lamp.masterOn }, set: { _ in lamp.togglePower() }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(lamp.groupIPs.count > 1 ? "Вся группа (\(lamp.groupIPs.count))" : "Вся лампа: передний свет + подсветка")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if !lamp.connected && section != .devices {
            notConnected
        } else {
            switch section {
            case .control: lightSection
            case .effects: effectsSection
            case .scenes: scenesSection
            case .devices: devicesSection
            }
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Лампа не подключена").font(.title3).bold()
            Text("Открой раздел «Устройства», найди лампу и подключись.").foregroundStyle(Color.razerSecondary)
            Button("Перейти к устройствам") { section = .devices }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: sections

    /// One tab combining the front white and the ambient colour, so there's no jumping between tabs.
    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            controlSection
            ambientSection
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle(isOn: Binding(get: { lamp.power }, set: { lamp.setFrontPower($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Передний свет").font(.title3)
                    Text("белый свет на монитор — независим от подсветки ниже")
                        .font(.caption).foregroundStyle(Color.razerSecondary)
                }
            }.toggleStyle(.switch)
            GroupBox("Передний белый свет") {
                VStack(alignment: .leading, spacing: 18) {
                    slider("Яркость", $lamp.brightness, 1...100, { "\(Int($0))%" }) { lamp.pushBrightness() }
                    slider("Тёплость", $lamp.colorTempK, 2700...6500, { "\(Int($0)) K" }) { lamp.pushColorTemp() }
                }.padding(10)
            }
        }
    }

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { lamp.ambientOn }, set: { lamp.setAmbientPower($0) })) {
                Text("Подсветка включена").font(.title3)
            }.toggleStyle(.switch)
            GroupBox("Цвет подсветки") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Текущий цвет").font(.callout).foregroundStyle(Color.razerSecondary)
                        Spacer()
                        RoundedRectangle(cornerRadius: 6).fill(lamp.ambientColor).frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    }
                    GeometryReader { geo in
                        LinearGradient(gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                                       startPoint: .leading, endPoint: .trailing)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                                lamp.setAmbient(Color(hue: max(0, min(1, v.location.x / geo.size.width)), saturation: 0.9, brightness: 1))
                            })
                    }.frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack(spacing: 14) {
                        ForEach(presets, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 8).fill(c).frame(width: 40, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
                                .onTapGesture { lamp.setAmbient(c) }
                        }
                        Spacer()
                    }
                }.padding(10)
            }
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Эффект", selection: Binding(get: { lamp.syncMode }, set: { lamp.setSyncMode($0) })) {
                Text("Выкл").tag(SyncMode.off)
                Text("Экран").tag(SyncMode.screen)
                Text("Музыка").tag(SyncMode.music)
            }.pickerStyle(.segmented)

            if !lamp.screenHasPermission && lamp.syncMode != .off {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Нужно разрешение «Запись экрана» (после выдачи перезапусти приложение)").font(.callout)
                    Spacer()
                    Button("Открыть") { lamp.openScreenSettings() }
                }
            }
            if let s = lamp.screenSyncStatus ?? lamp.musicSyncStatus {
                Text(s).font(.callout).foregroundStyle(s.hasSuffix("…") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }

            if lamp.syncMode == .screen {
                screenPreview
                GroupBox("Какая лампа · с какого экрана · какая зона") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("В группе \(lamp.groupIPs.count). Каждая лампа берёт цвет со своего экрана и зоны.")
                                .font(.caption2).foregroundStyle(Color.razerSecondary)
                            Spacer()
                            Button { lamp.refreshDisplays() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help("Обновить список экранов")
                        }
                        ForEach(lamp.devices.filter { lamp.groupIPs.contains($0.ip) }, id: \.ip) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: d.model == "strip8" ? "alternatingcurrent" : "lightbulb")
                                    Text(name(d)).font(.callout).lineLimit(1)
                                    Spacer()
                                    if lamp.displays.count > 1 {
                                        Menu(displayShort(lamp.displayID(forLamp: d.ip))) {
                                            ForEach(lamp.displays) { disp in
                                                Button(disp.label) { lamp.setSyncDisplay(d.ip, disp.id) }
                                            }
                                        }.fixedSize()
                                    }
                                    Menu(zoneLabel(lamp.displayRegion(d.ip))) {
                                        Button("Верх") { lamp.setRegion(d.ip, .top) }
                                        Button("Низ") { lamp.setRegion(d.ip, .bottom) }
                                        Button("Лево") { lamp.setRegion(d.ip, .left) }
                                        Button("Право") { lamp.setRegion(d.ip, .right) }
                                        Button("Весь экран") { lamp.setRegion(d.ip, .full) }
                                    }.fixedSize()
                                }
                                if lamp.isAddressable(d) {
                                    let n = lamp.segments(forLamp: d.ip)
                                    HStack(spacing: 10) {
                                        Toggle("По сегментам", isOn: Binding(get: { n > 0 }, set: { lamp.setSegments(d.ip, $0 ? 12 : 0) }))
                                            .toggleStyle(.checkbox).font(.caption)
                                        if n > 0 {
                                            Stepper("\(n) сегм.", value: Binding(get: { lamp.segments(forLamp: d.ip) }, set: { lamp.setSegments(d.ip, $0) }), in: 2...30)
                                                .font(.caption).fixedSize()
                                            Button { lamp.toggleSegmentReversed(d.ip) } label: {
                                                Image(systemName: "arrow.left.arrow.right")
                                                    .foregroundStyle(lamp.segmentReversed[d.ip] == true ? Color.accentColor : .secondary)
                                            }.buttonStyle(.borderless).help("Развернуть направление сегментов")
                                        }
                                        Spacer()
                                    }.padding(.leading, 22)
                                }
                            }
                        }
                    }.padding(10)
                }
                GroupBox("Настройка") {
                    VStack(alignment: .leading, spacing: 16) {
                        slider("Размер зоны", $lamp.bandFraction, 0.1...0.6, { "\(Int($0 * 100))%" })
                        Toggle("Яркость следует за яркостью сцены", isOn: $lamp.brightnessFollow)
                        slider("Плавность", $lamp.syncSmoothing, 0.1...0.8, { "\(Int($0 * 100))%" })
                        slider("Насыщенность", $lamp.syncSaturation, 1.0...2.0, { String(format: "%.1f×", $0) })
                    }.padding(10)
                }
            }
            if lamp.syncMode == .music {
                GroupBox("Музыка (системный звук)") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Стиль", selection: Binding(get: { lamp.musicStyle }, set: { lamp.musicStyle = $0 })) {
                            Text("Бит (бас/кик)").tag(MusicStyle.beat)
                            Text("Спектр (RGB)").tag(MusicStyle.spectrum)
                        }.pickerStyle(.segmented)
                        slider("Чувствительность", $lamp.musicSensitivity, 2...8, { String(format: "%.1f", $0) })
                        Text("Бит — пульс под бас. Спектр — бас=красный, мид=зелёный, верха=синий.")
                            .font(.caption).foregroundStyle(Color.razerSecondary)
                    }.padding(10)
                }
            }
        }
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Готовые пресеты белого света").foregroundStyle(Color.razerSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                sceneBtn("Reading", "book", 4000, 100)
                sceneBtn("Relax", "cup.and.saucer", 2700, 40)
                sceneBtn("Focus", "target", 5000, 100)
                sceneBtn("Movie", "film", 2700, 15)
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { lamp.autoSearch() } label: {
                HStack {
                    if lamp.isSearching { ProgressView().controlSize(.small) } else { Image(systemName: "antenna.radiowaves.left.and.right") }
                    Text(lamp.isSearching ? "Идёт поиск…" : "Автопоиск ламп в сети")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(lamp.isSearching)

            if let err = lamp.connectError { Text(err).font(.callout).foregroundStyle(.red) }

            GroupBox("Найденные лампы") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Отметь несколько ламп — они управляются вместе (питание, цвет, сцены, эффекты).")
                        .font(.caption).foregroundStyle(Color.razerSecondary)
                    if lamp.devices.isEmpty {
                        Text("Пока ничего — нажми «Автопоиск».").foregroundStyle(Color.razerSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(lamp.devices, id: \.ip) { d in
                        let inGroup = lamp.groupIPs.contains(d.ip)
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(get: { inGroup }, set: { _ in lamp.toggleGroup(d) })) { EmptyView() }
                                .toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: d.model == "strip8" ? "alternatingcurrent" : "lightbulb.fill")
                                .foregroundStyle(inGroup ? Color.green : .secondary)
                            Button {
                                if inGroup { lamp.makePrimary(d) } else { lamp.toggleGroup(d) }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name(d)).foregroundStyle(.primary)
                                    Text(d.ip).font(.caption).foregroundStyle(Color.razerSecondary)
                                }
                            }.buttonStyle(.plain)
                            if d.ip == lamp.selected?.ip {
                                Text("основная").font(.caption2).foregroundStyle(.blue)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            Button("Мигнуть") { lamp.identify(d) }.controlSize(.small)
                        }.padding(.vertical, 2)
                    }
                }.padding(10)
            }
            GroupBox("Добавить вручную по IP") {
                HStack {
                    TextField("192.168.1.x", text: $lamp.manualIP).textFieldStyle(.roundedBorder).onSubmit { lamp.addManualIP() }
                    Button("Добавить") { lamp.addManualIP() }.disabled(lamp.manualIP.isEmpty)
                }.padding(10)
            }
        }
    }

    // MARK: live monitor-arrangement map

    private var groupLamps: [DiscoveredDevice] { lamp.devices.filter { lamp.groupIPs.contains($0.ip) } }

    /// A native "Displays" map: every connected monitor drawn in its real arrangement and to scale,
    /// numbered «Монитор N», showing the live zones of the lamps assigned to it. Click a monitor to
    /// assign which group lamps sample it — so with 3 monitors and 3 lamps you just see and tap.
    private var screenPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Подключено мониторов: \(lamp.displays.count)").font(.callout).foregroundStyle(Color.razerSecondary)
                Spacer()
                Button { lamp.refreshDisplays() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Обновить список мониторов")
            }
            Text("Нажми на монитор, чтобы выбрать, какая лампа берёт с него цвет.")
                .font(.caption2).foregroundStyle(Color.razerSecondary)
            displaysMap
        }
    }

    @ViewBuilder private var displaysMap: some View {
        let infos = lamp.displays
        if infos.isEmpty {
            Text("Мониторы не найдены").font(.caption).foregroundStyle(Color.razerSecondary)
        } else {
            let union = infos.dropFirst().reduce(infos[0].bounds) { $0.union($1.bounds) }
            let scale = max(0.0001, min(540 / max(1, union.width), 240 / max(1, union.height)))
            ZStack(alignment: .topLeading) {
                ForEach(infos) { info in
                    let w = max(64, info.bounds.width * scale - 8)
                    let h = max(44, info.bounds.height * scale - 8)
                    monitorBox(info, w: w, h: h)
                        .onTapGesture { assignTarget = (assignTarget == info.id) ? nil : info.id }
                        .popover(isPresented: Binding(get: { assignTarget == info.id },
                                                      set: { if !$0 { assignTarget = nil } }),
                                 arrowEdge: .bottom) { assignSheet(info) }
                        .position(x: (info.bounds.minX - union.minX) * scale + info.bounds.width * scale / 2,
                                  y: (info.bounds.minY - union.minY) * scale + info.bounds.height * scale / 2)
                }
            }
            .frame(width: max(64, union.width * scale), height: max(44, union.height * scale), alignment: .topLeading)
            .padding(.vertical, 6)
        }
    }

    /// Tap-to-assign popover: pick which group lamps sample this monitor.
    private func assignSheet(_ info: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Лампы на «\(info.short)»").font(.callout).bold()
            Text("\(info.width)×\(info.height)" + (info.isMain ? " · основной" : "")).font(.caption).foregroundStyle(Color.razerSecondary)
            Divider()
            if groupLamps.isEmpty {
                Text("Сначала добавь лампы в группу\nна вкладке «Устройства»").font(.caption).foregroundStyle(Color.razerSecondary)
            } else {
                ForEach(groupLamps, id: \.ip) { d in
                    let here = lamp.displayID(forLamp: d.ip) == info.id
                    Button { lamp.setSyncDisplay(d.ip, info.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: here ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(here ? Color.accentColor : .secondary)
                            Text(name(d))
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(14).frame(width: 250)
    }

    private func monitorBox(_ info: DisplayInfo, w: CGFloat, h: CGFloat) -> some View {
        let zones = zonesOn(info.id)
        let colors = lamp.regionColors[info.id] ?? [:]
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.82))   // the "screen"
            ForEach(zones, id: \.region) { z in
                let f = zoneFrac(z.region)
                Rectangle().fill(colors[z.region] ?? Color.white.opacity(0.12))
                    .frame(width: w * f.w, height: h * f.h)
                    .position(x: w * (f.x + f.w / 2), y: h * (f.y + f.h / 2))
            }
            VStack(spacing: 1) {
                Text("\(info.index)").font(.title3).bold().foregroundStyle(.white)
                Text("\(info.width)×\(info.height)").font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                if zones.isEmpty {
                    Text(info.isMain ? "осн. · нет ламп" : "нет ламп").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(zones.map(\.label).joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 3)
                }
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(info.isMain ? Color.blue : Color.secondary.opacity(0.55), lineWidth: info.isMain ? 2.5 : 1.5))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Zones assigned on a given display, with the short names of the lamp(s) on each.
    private func zonesOn(_ did: CGDirectDisplayID) -> [(region: SyncRegion, label: String)] {
        var byRegion: [SyncRegion: [String]] = [:]
        for d in lamp.devices where lamp.groupIPs.contains(d.ip) && lamp.displayID(forLamp: d.ip) == did {
            byRegion[lamp.displayRegion(d.ip) ?? .top, default: []].append(shortName(d))
        }
        let order: [SyncRegion] = [.full, .top, .bottom, .left, .right]
        return order.compactMap { r in byRegion[r].map { (r, $0.joined(separator: ", ")) } }
    }

    private func displayShort(_ did: CGDirectDisplayID) -> String {
        lamp.displays.first(where: { $0.id == did })?.short ?? "экран"
    }

    private func zoneFrac(_ r: SyncRegion) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let b = CGFloat(lamp.bandFraction)
        switch r {
        case .full:   return (0, 0, 1, 1)
        case .top:    return (0, 0, 1, b)
        case .bottom: return (0, 1 - b, 1, b)
        case .left:   return (0, 0, b, 1)
        case .right:  return (1 - b, 0, b, 1)
        }
    }

    private func shortName(_ d: DiscoveredDevice) -> String {
        if d.model == "lamp15" { return "Bar" }
        if d.model == "strip8" { return "Strip" }
        if !d.model.isEmpty { return d.model }
        return d.ip.split(separator: ".").last.map(String.init) ?? "?"
    }

    // MARK: helpers

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ display: @escaping (Double) -> String, _ commit: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(display(value.wrappedValue)).font(.callout).monospacedDigit().foregroundStyle(Color.razerSecondary)
            }
            Slider(value: value, in: range) { editing in if !editing { commit() } }
        }
    }

    private func sceneBtn(_ title: String, _ icon: String, _ ct: Int, _ b: Int) -> some View {
        Button { lamp.applyScene(ct: ct, bright: b) } label: {
            HStack { Image(systemName: icon); Text(title); Spacer() }.padding(.vertical, 6)
        }.buttonStyle(.bordered).controlSize(.large)
    }

    private var headerSubtitle: String {
        let ip = lamp.selected?.ip ?? ""
        return lamp.groupIPs.count > 1 ? "\(ip) · группа \(lamp.groupIPs.count)" : ip
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
