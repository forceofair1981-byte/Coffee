import SwiftUI
import Charts
import Combine
import UniformTypeIdentifiers

@main
struct CoffeeRoastLogApp: App {
    @StateObject private var store = RoastStore()
    @StateObject private var roastTimer = RoastTimerModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .environmentObject(roastTimer)
                .tint(.brown)
        }
    }
}

struct TemperaturePoint: Codable, Identifiable, Hashable {
    var minute: Int
    var temperature: Double
    var id: Int { minute }
}

struct RoastEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var bean: String
    var temperature: Double
    var durationSeconds: Int
    var acidity: Int
    var bitterness: Int
    var temperatureLog: [TemperaturePoint]
}

struct TimerSnapshot: Codable {
    var elapsedSeconds: Int
    var runningSince: Date?
    var temperatureLog: [TemperaturePoint]
}

@MainActor
final class RoastStore: ObservableObject {
    @Published private(set) var records: [RoastEntry] = [] {
        didSet { persist() }
    }
    private let key = "coffee-roast-log-v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RoastEntry].self, from: data) {
            records = decoded.sorted { $0.date > $1.date }
        }
    }

    var beans: [String] {
        Array(Set(records.map(\.bean))).sorted()
    }

    func add(_ entry: RoastEntry) {
        records.insert(entry, at: 0)
        records.sort { $0.date > $1.date }
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
    }

    func replace(with newRecords: [RoastEntry]) {
        records = newRecords.sorted { $0.date > $1.date }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class RoastTimerModel: ObservableObject {
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var isRunning = false
    @Published private(set) var temperatureLog: [TemperaturePoint] = []

    private let key = "coffee-roast-active-timer-v1"
    private var accumulatedSeconds = 0
    private var runningSince: Date?

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(TimerSnapshot.self, from: data) else { return }
        accumulatedSeconds = snapshot.elapsedSeconds
        runningSince = snapshot.runningSince
        temperatureLog = snapshot.temperatureLog
        isRunning = runningSince != nil
        update()
    }

    var unrecordedMinutes: [Int] {
        guard elapsedSeconds >= 60 else { return [] }
        let due = Array(1...(elapsedSeconds / 60))
        let recorded = Set(temperatureLog.map(\.minute))
        return due.filter { !recorded.contains($0) }
    }

    func update(now: Date = Date()) {
        if let runningSince {
            elapsedSeconds = accumulatedSeconds + max(0, Int(now.timeIntervalSince(runningSince)))
        } else {
            elapsedSeconds = accumulatedSeconds
        }
        persist()
    }

    func start() {
        guard !isRunning else { return }
        runningSince = Date()
        isRunning = true
        update()
    }

    func pause() {
        guard let runningSince else { return }
        accumulatedSeconds = elapsedSeconds
        self.runningSince = nil
        isRunning = false
        update()
    }

    func reset() {
        accumulatedSeconds = 0
        elapsedSeconds = 0
        runningSince = nil
        isRunning = false
        temperatureLog = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func addTemperature(_ temperature: Double, at minute: Int) {
        guard unrecordedMinutes.contains(minute), (0...300).contains(temperature) else { return }
        temperatureLog.append(TemperaturePoint(minute: minute, temperature: temperature))
        temperatureLog.sort { $0.minute < $1.minute }
        persist()
    }

    private func persist() {
        let snapshot = TimerSnapshot(elapsedSeconds: elapsedSeconds,
                                     runningSince: runningSince,
                                     temperatureLog: temperatureLog)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct RoastBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var records: [RoastEntry]

    init(records: [RoastEntry] = []) { self.records = records }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        records = try WebsiteBackupDecoder.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let envelope = CoffeeBackupEnvelope(records: records.map { WebsiteRoastEntry($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(envelope))
    }
}

struct CoffeeBackupEnvelope: Encodable {
    var app = "coffee-roast-log"
    var backupVersion = 1
    var exportedAt = Date()
    var records: [WebsiteRoastEntry]
}

struct WebsiteRoastEntry: Encodable {
    var id: String
    var date: String
    var bean: String
    var temperature: Double
    var minutes: Int
    var seconds: Int
    var durationSeconds: Int
    var acidity: Int
    var bitterness: Int
    var temperatureLog: [TemperaturePoint]

    init(_ entry: RoastEntry) {
        id = entry.id.uuidString
        date = ISO8601DateFormatter().string(from: entry.date)
        bean = entry.bean
        temperature = entry.temperature
        minutes = entry.durationSeconds / 60
        seconds = entry.durationSeconds % 60
        durationSeconds = entry.durationSeconds
        acidity = entry.acidity
        bitterness = entry.bitterness
        temperatureLog = entry.temperatureLog
    }
}

enum WebsiteBackupDecoder {
    static func decode(_ data: Data) throws -> [RoastEntry] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] { rows = array }
        else if let envelope = object as? [String: Any],
                envelope["app"] as? String == "coffee-roast-log",
                let array = envelope["records"] as? [[String: Any]] { rows = array }
        else { throw CocoaError(.fileReadCorruptFile) }

        return try rows.map { row in
            guard let bean = (row["bean"] as? String ?? row["beanName"] as? String), !bean.isEmpty,
                  let temperature = decimal(row["temperature"]),
                  let acidity = number(row["acidity"]),
                  let bitterness = number(row["bitterness"]) else { throw CocoaError(.fileReadCorruptFile) }
            let duration = number(row["durationSeconds"]) ?? number(row["duration"])
                ?? ((number(row["minutes"]) ?? 0) * 60 + (number(row["seconds"]) ?? 0))
            let date = parseDate(row["date"]) ?? Date()
            let id = UUID(uuidString: row["id"] as? String ?? "") ?? UUID()
            let readings = (row["temperatureLog"] as? [[String: Any]] ?? []).compactMap { item -> TemperaturePoint? in
                guard let minute = number(item["minute"]), let value = decimal(item["temperature"]), minute > 0 else { return nil }
                return TemperaturePoint(minute: minute, temperature: value)
            }.sorted { $0.minute < $1.minute }
            return RoastEntry(id: id, date: date, bean: bean, temperature: temperature,
                              durationSeconds: max(0, duration), acidity: acidity, bitterness: bitterness,
                              temperatureLog: readings)
        }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func decimal(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            RoastEntryView()
                .tabItem { Label("焙煎を記録", systemImage: "plus.circle") }
            RoastHistoryView()
                .tabItem { Label("履歴・分析", systemImage: "chart.xyaxis.line") }
            CoffeeGearView()
                .tabItem { Label("道具・消耗品", systemImage: "shippingbox") }
        }
    }
}

struct RoastEntryView: View {
    @EnvironmentObject private var store: RoastStore
    @EnvironmentObject private var roastTimer: RoastTimerModel
    @State private var selectedBean = ""
    @State private var newBean = ""
    @State private var temperature = ""
    @State private var minutes = ""
    @State private var seconds = "0"
    @State private var acidity = 5.0
    @State private var bitterness = 5.0
    @State private var selectedMinute = 0
    @State private var readingTemperature = ""
    @State private var notice: String?
    @State private var showResetConfirmation = false

    private var beanToSave: String { newBean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedBean : newBean.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var elapsedText: String { String(format: "%02d:%02d", roastTimer.elapsedSeconds / 60, roastTimer.elapsedSeconds % 60) }

    var body: some View {
        NavigationStack {
            Form {
                Section("コーヒー豆") {
                    Picker("登録済みの豆", selection: $selectedBean) {
                        Text("豆を選択").tag("")
                        ForEach(store.beans, id: \.self) { bean in Text(bean).tag(bean) }
                    }
                    TextField("または、新しい豆の名前", text: $newBean)
                        .textInputAutocapitalization(.never)
                }

                Section("焙煎条件") {
                    HStack {
                        Text("焙煎温度")
                        Spacer()
                        TextField("200", text: $temperature)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("°C").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text("焙煎時間")
                        Spacer()
                        TextField("分", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 54)
                        Text("分").foregroundStyle(.secondary)
                        TextField("秒", text: $seconds).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 54)
                        Text("秒").foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Label("焙煎タイマー", systemImage: "timer")
                        Spacer()
                        Text(elapsedText).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                    }
                    HStack {
                        Button(roastTimer.isRunning ? "計測中" : "開始") { roastTimer.start() }
                            .buttonStyle(.borderedProminent).disabled(roastTimer.isRunning)
                        Button("一時停止") { roastTimer.pause() }
                            .buttonStyle(.bordered).disabled(!roastTimer.isRunning)
                        Button("リセット", role: .destructive) { showResetConfirmation = true }
                            .buttonStyle(.bordered)
                    }
                    if roastTimer.unrecordedMinutes.isEmpty {
                        Text("1分経過すると温度を入力できます").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("記録する経過分", selection: $selectedMinute) {
                            ForEach(roastTimer.unrecordedMinutes, id: \.self) { minute in
                                Text("\(minute)分").tag(minute)
                            }
                        }
                        HStack {
                            TextField("温度", text: $readingTemperature).keyboardType(.decimalPad)
                            Text("°C").foregroundStyle(.secondary)
                            Button("温度を記録") { recordTemperature() }
                                .buttonStyle(.borderedProminent)
                                .disabled(Double(readingTemperature) == nil)
                        }
                    }
                    if !roastTimer.temperatureLog.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(roastTimer.temperatureLog) { point in
                                    Text("\(point.minute)分 · \(point.temperature.formatted())°C")
                                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(.brown.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }
                } header: { Text("1分ごとの温度記録") }

                Section("味わいの評価") {
                    tasteSlider(title: "酸味", value: $acidity)
                    tasteSlider(title: "苦味", value: $bitterness)
                }

                Section {
                    Button { saveRoast() } label: {
                        Label("焙煎を保存", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("焙煎ノート")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Text(Date.now.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) } }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in roastTimer.update() }
            .onChange(of: roastTimer.unrecordedMinutes) { _, values in
                if !values.contains(selectedMinute) { selectedMinute = values.first ?? 0 }
            }
            .alert("確認", isPresented: $showResetConfirmation) {
                Button("リセット", role: .destructive) { roastTimer.reset() }
                Button("キャンセル", role: .cancel) { }
            } message: { Text("タイマーと温度ログを消去します。") }
            .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    private func tasteSlider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) / 10").foregroundStyle(.secondary) }
            Slider(value: value, in: 1...10, step: 1)
        }
    }

    private func recordTemperature() {
        guard let value = Double(readingTemperature), (0...300).contains(value), selectedMinute > 0 else { return }
        roastTimer.addTemperature(value, at: selectedMinute)
        readingTemperature = ""
    }

    private func saveRoast() {
        guard !beanToSave.isEmpty else { notice = "豆を選択するか、新しい豆の名前を入力してください。"; return }
        guard let temp = Double(temperature), (80...260).contains(temp) else { notice = "焙煎温度を80〜260°Cで入力してください。"; return }
        guard let mins = Int(minutes), let secs = Int(seconds), mins >= 0, (0...59).contains(secs), mins * 60 + secs > 0 else { notice = "焙煎時間を分・秒で入力してください。"; return }
        store.add(RoastEntry(bean: beanToSave, temperature: temp, durationSeconds: mins * 60 + secs, acidity: Int(acidity), bitterness: Int(bitterness), temperatureLog: roastTimer.temperatureLog))
        selectedBean = beanToSave
        newBean = ""
        temperature = ""
        minutes = ""
        seconds = "0"
        acidity = 5
        bitterness = 5
        roastTimer.reset()
        notice = "焙煎記録を保存しました。"
    }
}

struct RoastHistoryView: View {
    @EnvironmentObject private var store: RoastStore
    @State private var selectedBean = ""
    @State private var exportPresented = false
    @State private var importPresented = false
    @State private var notice: String?

    private var beanRecords: [RoastEntry] { store.records.filter { selectedBean.isEmpty || $0.bean == selectedBean } }
    private var daily: [DailyRoast] {
        let groups = Dictionary(grouping: beanRecords) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted().map { day in
            let entries = groups[day] ?? []
            return DailyRoast(day: day,
                              temperature: entries.map(\.temperature).reduce(0, +) / Double(max(entries.count, 1)),
                              duration: Double(entries.map(\.durationSeconds).reduce(0, +)) / Double(max(entries.count, 1)) / 60)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.records.isEmpty {
                    Section("豆ごとの統計") {
                        Picker("分析する豆", selection: $selectedBean) {
                            Text("すべて").tag("")
                            ForEach(store.beans, id: \.self) { Text($0).tag($0) }
                        }
                        if !beanRecords.isEmpty {
                            LabeledContent("焙煎回数", value: "\(beanRecords.count)回")
                            LabeledContent("平均温度", value: "\(average(\.temperature).formatted(.number.precision(.fractionLength(1))))°C")
                            LabeledContent("平均時間", value: "\(averageDuration.formatted(.number.precision(.fractionLength(1))))分")
                        }
                    }
                    Section("日別平均") {
                        if daily.isEmpty { Text("焙煎記録を追加するとグラフが表示されます").foregroundStyle(.secondary) }
                        else {
                            Chart(daily) { item in
                                LineMark(x: .value("日付", item.day, unit: .day), y: .value("温度", item.temperature)).foregroundStyle(.brown)
                                PointMark(x: .value("日付", item.day, unit: .day), y: .value("温度", item.temperature)).foregroundStyle(.brown)
                            }
                            .frame(height: 170)
                            .chartYAxisLabel("°C")
                            Chart(daily) { item in
                                LineMark(x: .value("日付", item.day, unit: .day), y: .value("時間", item.duration)).foregroundStyle(.green)
                                PointMark(x: .value("日付", item.day, unit: .day), y: .value("時間", item.duration)).foregroundStyle(.green)
                            }
                            .frame(height: 170)
                            .chartYAxisLabel("分")
                        }
                    }
                    Section("焙煎履歴") {
                        ForEach(beanRecords) { entry in RoastEntryRow(entry: entry) }
                            .onDelete { offsets in
                                let ids = Set(offsets.map { beanRecords[$0].id })
                                store.replace(with: store.records.filter { !ids.contains($0.id) })
                            }
                    }
                } else {
                    ContentUnavailableView("焙煎記録はまだありません", systemImage: "cup.and.saucer", description: Text("記録タブから最初の焙煎を登録してください。"))
                }
            }
            .navigationTitle("履歴・分析")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("JSONをバックアップ", systemImage: "square.and.arrow.up") { exportPresented = true }
                        Button("バックアップから復元", systemImage: "square.and.arrow.down") { importPresented = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileExporter(isPresented: $exportPresented,
                          document: RoastBackupDocument(records: store.records),
                          contentType: .json,
                          defaultFilename: "coffee-roast-log-backup") { result in
                if case .failure(let error) = result { notice = "バックアップを作成できませんでした: \(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    let urls = try result.get()
                    guard let url = urls.first else { return }
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let imported = try WebsiteBackupDecoder.decode(Data(contentsOf: url))
                    store.replace(with: imported)
                    notice = "\(imported.count)件の記録を復元しました。"
                } catch { notice = "復元できませんでした。バックアップファイルを確認してください。" }
            }
            .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    private func average(_ keyPath: KeyPath<RoastEntry, Double>) -> Double {
        guard !beanRecords.isEmpty else { return 0 }
        return beanRecords.map { $0[keyPath: keyPath] }.reduce(0, +) / Double(beanRecords.count)
    }

    private var averageDuration: Double {
        guard !beanRecords.isEmpty else { return 0 }
        return Double(beanRecords.map(\.durationSeconds).reduce(0, +)) / Double(beanRecords.count) / 60
    }
}

struct DailyRoast: Identifiable {
    var day: Date
    var temperature: Double
    var duration: Double
    var id: Date { day }
}

struct RoastEntryRow: View {
    let entry: RoastEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(entry.bean).font(.headline); Spacer(); Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Label("\(entry.temperature.formatted())°C", systemImage: "thermometer.medium")
                Label("\(entry.durationSeconds / 60)分\(entry.durationSeconds % 60)秒", systemImage: "clock")
            }.font(.subheadline)
            HStack { Label("酸味 \(entry.acidity)/10", systemImage: "leaf"); Label("苦味 \(entry.bitterness)/10", systemImage: "circle.lefthalf.filled") }.font(.caption).foregroundStyle(.secondary)
            if !entry.temperatureLog.isEmpty {
                Chart(entry.temperatureLog) { point in
                    LineMark(x: .value("経過分", point.minute), y: .value("温度", point.temperature)).foregroundStyle(.brown)
                    PointMark(x: .value("経過分", point.minute), y: .value("温度", point.temperature)).foregroundStyle(.brown)
                }
                .frame(height: 120)
                .chartXAxisLabel("経過分")
                .chartYAxisLabel("°C")
            }
        }
        .padding(.vertical, 4)
    }
}

struct CoffeeGearView: View {
    private let products: [CoffeeProduct] = [
        CoffeeProduct(title: "焙煎用コーヒー生豆", category: "消耗品・生豆", detail: "産地や精製方法を選んで焙煎を試す", symbol: "shippingbox", url: URL(string: "https://www.wild-coffee-store.com/")!),
        CoffeeProduct(title: "FUJI ROYAL 小型ロースター", category: "備品・焙煎", detail: "電気式ロースター「Cube e」の製品情報", symbol: "flame", url: URL(string: "https://www.fuji-royal.jp/products/roaster/cubee/")!),
        CoffeeProduct(title: "HARIO V60 ドリップスケール", category: "備品・計量", detail: "コーヒー豆や抽出量の計量に", symbol: "scalemass", url: URL(string: "https://hariocafe.myshopify.com/collections/%E6%8A%BD%E5%87%BA%E7%94%A8%E5%99%A8%E5%85%B7-brewing-equipment")!),
        CoffeeProduct(title: "バルブ付きコーヒー袋", category: "消耗品・保存", detail: "焙煎豆の小分け保存に", symbol: "archivebox", url: URL(string: "https://cafegoods-shop.com/SHOP/201005.html")!)
    ]
    @State private var category = "すべて"
    private var visibleProducts: [CoffeeProduct] { category == "すべて" ? products : products.filter { $0.category.hasPrefix(category) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("カテゴリ", selection: $category) {
                        Text("すべて").tag("すべて")
                        Text("備品").tag("備品")
                        Text("消耗品").tag("消耗品")
                    }.pickerStyle(.segmented)
                }
                Section("焙煎を支えるアイテム") {
                    ForEach(visibleProducts) { product in
                        Link(destination: product.url) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: product.symbol).font(.title2).foregroundStyle(.brown).frame(width: 42, height: 42).background(.brown.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(product.category.uppercased()).font(.caption2).foregroundStyle(.brown)
                                    Text(product.title).font(.headline).foregroundStyle(.primary)
                                    Text(product.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section {
                    Text("価格・在庫はリンク先でご確認ください。現在は通常の外部リンクです。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("道具・消耗品")
        }
    }
}

struct CoffeeProduct: Identifiable {
    var title: String
    var category: String
    var detail: String
    var symbol: String
    var url: URL
    var id: String { title }
}
