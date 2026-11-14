// 番茄鐘護眼：每 25 分鐘把所有螢幕蓋上暗幕、休息 5 分鐘，結束時響鈴，自動開始下一輪。
// 用法：Pomodoro [--work 分鐘] [--rest 分鐘]（可小數，測試用）
// 規則：提早結束休息要長按 5 秒；跳過的休息會補到下一輪（最多補 5 分鐘）；每 4 輪休 15 分鐘；每完成一輪工作累積 1 顆小蕃茄
import Cocoa
import ServiceManagement

// ---------- 設定 ----------
let defaults = UserDefaults.standard
var workMinutes = (defaults.object(forKey: "workMinutes") as? Double) ?? 25.0
var restMinutes = (defaults.object(forKey: "restMinutes") as? Double) ?? 5.0
let workChoices: [Double] = [15, 25, 30, 45, 50]
let restChoices: [Double] = [3, 5, 10, 15]
let args = CommandLine.arguments
var longRestMinutes = 15.0     // 長休息分鐘
var longEvery = 4              // 每幾輪一次長休息（0 = 不用）
var holdSeconds = 5.0          // 提早結束要長按幾秒
let maxMakeup = 5.0            // 補休最多加幾分鐘
var debugLog = false
var autoSkipAfter: Double? = nil   // 測試用：休息開始幾秒後自動「跳過」
func numArg(_ name: String) -> Double? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return Double(args[i + 1]) }
    return nil
}
if let v = defaults.object(forKey: "longRest") as? Double { longRestMinutes = v }
if let v = defaults.object(forKey: "longEvery") as? Int { longEvery = v }
if let v = defaults.object(forKey: "holdSec") as? Double { holdSeconds = v }
var endVolume: Float = (defaults.object(forKey: "endVolume") as? Float) ?? 0.6
let initialPage = Int(numArg("--page") ?? 0)        // 測試用：休息畫面一開始停在哪一頁
let pageCycle = args.contains("--pagecycle")          // 測試用：自動左右換頁
if let v = numArg("--long") { longRestMinutes = v }
if let v = numArg("--every") { longEvery = Int(v) }
if let v = numArg("--hold") { holdSeconds = v }
if let v = numArg("--autoskip") { autoSkipAfter = v }
debugLog = args.contains("--debug")
if debugLog { setvbuf(stdout, nil, _IOLBF, 0) }
if let i = args.firstIndex(of: "--work"), i + 1 < args.count, let v = Double(args[i + 1]) { workMinutes = v }
if let i = args.firstIndex(of: "--rest"), i + 1 < args.count, let v = Double(args[i + 1]) { restMinutes = v }

enum Phase { case work, rest }

// ---------- 小蕃茄（累積）----------
// 每完成一輪完整的工作計時 +1 顆；用「現在就休息」提早進休息不算。一天一筆，存在 UserDefaults。
// 測試（--debug）時用另一份資料，不會弄髒真正的紀錄。
let tomatoStore: UserDefaults = args.contains("--debug")
    ? (UserDefaults(suiteName: "local.nicole.pomodoro-dim.test") ?? .standard) : .standard
let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
}()
func tomatoLog() -> [String: Int] { (tomatoStore.dictionary(forKey: "tomatoLog") as? [String: Int]) ?? [:] }
@discardableResult func addTomato() -> Int {
    var log = tomatoLog(); let k = dayFmt.string(from: Date())
    log[k, default: 0] += 1
    tomatoStore.set(log, forKey: "tomatoLog")
    return log[k] ?? 1
}
func tomatoToday() -> Int { tomatoLog()[dayFmt.string(from: Date())] ?? 0 }
func tomatoTotal() -> Int { tomatoLog().values.reduce(0, +) }
func tomatoWeek() -> Int {   // 本週（週一開始）
    var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
    guard let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
    let log = tomatoLog(); var sum = 0
    for i in 0..<7 { if let d = cal.date(byAdding: .day, value: i, to: start) { sum += log[dayFmt.string(from: d)] ?? 0 } }
    return sum
}
func tomatoRow(_ n: Int) -> String { n == 0 ? "還沒有" : (n <= 12 ? String(repeating: "🍅", count: n) : "🍅 × \(n)") }

// 今天的小蕃茄順序：R＝紅（完整做完一輪）、O＝橘（按「現在就休息」提早休息）。每天重新計算（只看今天）。
// 紅蕃茄的總數仍存在 tomatoLog；順序只記新的，舊資料不足的紅蕃茄補在最前面。
func tomatoSeqLog() -> [String: String] { (tomatoStore.dictionary(forKey: "tomatoSeq") as? [String: String]) ?? [:] }
func addToSeq(_ ch: String) {
    var s = tomatoSeqLog(); let k = dayFmt.string(from: Date())
    s[k, default: ""] += ch
    // 只留最近 14 天，免得越存越多
    if s.count > 14 { for key in s.keys.sorted().dropLast(14) { s.removeValue(forKey: key) } }
    tomatoStore.set(s, forKey: "tomatoSeq")
}
func todaySeq() -> [Character] {
    let seq = tomatoSeqLog()[dayFmt.string(from: Date())] ?? ""
    let seqReds = seq.filter { $0 == "R" }.count
    let missing = max(0, tomatoToday() - seqReds)
    return Array(String(repeating: "R", count: missing) + seq)
}
func tomatoEmojiRow() -> String {
    let s = todaySeq()
    if s.isEmpty { return "還沒有" }
    return s.count <= 12 ? String(s.map { $0 == "O" ? "🟠" : "🍅" }) : "🍅 × \(s.filter { $0 == "R" }.count)　🟠 × \(s.filter { $0 == "O" }.count)"
}
// ---------- 專注／休息時間統計 ----------
// 實際計時：工作階段（沒暫停）累積成「專注」，休息階段累積成「休息」；電腦睡眠、關 app 的時間不算。一天一筆（秒）。
func timeLog(_ key: String) -> [String: Double] { (tomatoStore.dictionary(forKey: key) as? [String: Double]) ?? [:] }
func addTime(_ key: String, _ sec: Double) {
    var log = timeLog(key); log[dayFmt.string(from: Date()), default: 0] += sec
    tomatoStore.set(log, forKey: key)
}
func timeToday(_ log: [String: Double]) -> Double { log[dayFmt.string(from: Date())] ?? 0 }
func timeTotal(_ log: [String: Double]) -> Double { log.values.reduce(0, +) }
func timeWeek(_ log: [String: Double]) -> Double {
    var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
    guard let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
    var sum = 0.0
    for i in 0..<7 { if let d = cal.date(byAdding: .day, value: i, to: start) { sum += log[dayFmt.string(from: d)] ?? 0 } }
    return sum
}
func durText(_ sec: Double) -> String {   // 同時寫分鐘與小時
    let m = Int((sec / 60).rounded())
    return "\(m) 分鐘（" + String(format: "%.1f", sec / 3600) + " 小時）"
}
func tomatoImage(_ name: String) -> NSImage? {
    Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}

// ---------- 隨開機開啟（macOS 13 以上）----------
func loginEnabled() -> Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
}
func setLogin(_ on: Bool) -> String {
    guard #available(macOS 13.0, *) else { return "此功能需要 macOS 13 以上" }
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return ""
    } catch { return error.localizedDescription }
}
// 測試／腳本用：Pomodoro --login on|off|status，執行完直接結束
if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
    let v = args[i + 1]
    if v == "on" || v == "off" { let e = setLogin(v == "on"); if !e.isEmpty { print("失敗：\(e)") } }
    print(loginEnabled() ? "enabled" : "disabled")
    exit(0)
}

// 無邊框視窗預設不能成為 key，按鈕才點得到
// 護眼畫面用字體：蘭陽明體 Medium；沒裝就退回系統字體
func lanyang(_ size: CGFloat) -> NSFont {
    NSFont(name: "jf-lanyangming-2.0-Medium", size: size) ?? NSFont.systemFont(ofSize: size, weight: .light)
}

func lanyangBook(_ size: CGFloat) -> NSFont {
    NSFont(name: "jf-lanyangming-2.0-Book", size: size) ?? NSFont.systemFont(ofSize: size, weight: .ultraLight)
}

// 參角點標準色（2026-11-12 定稿）
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
// 超柔和漸層：在每兩個顏色之間插入很多中間色，並用 smoothstep 緩進緩出，色與色交界不會有轉折
func softGradient(_ stops: [(NSColor, CGFloat)], samples: Int = 40) -> (colors: [CGColor], locations: [NSNumber]) {
    var cols: [CGColor] = [], locs: [NSNumber] = []
    for n in 0..<samples {
        let t = CGFloat(n) / CGFloat(samples - 1)
        var k = 0
        while k < stops.count - 2 && t > stops[k + 1].1 { k += 1 }
        let (c0, p0) = stops[k], (c1, p1) = stops[k + 1]
        let u = min(1, max(0, (t - p0) / (p1 - p0)))
        let e = u * u * (3 - 2 * u)
        let a = c0.usingColorSpace(.sRGB)!, b = c1.usingColorSpace(.sRGB)!
        let m = NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * e,
                        green: a.greenComponent + (b.greenComponent - a.greenComponent) * e,
                        blue: a.blueComponent + (b.blueComponent - a.blueComponent) * e, alpha: 1)
        cols.append(m.cgColor); locs.append(NSNumber(value: Double(t)))
    }
    return (cols, locs)
}
let deepTeal = rgb(59, 110, 97)      // 深青綠 #3B6E61
let paleLime = rgb(205, 213, 146)    // 淺黃綠 #CDD592
let softWhite = rgb(243, 244, 240)   // 淺底 #F3F4F0
let lemon = rgb(255, 228, 107)       // 檸檬黃 #FFE46B
let nightGreen = rgb(9, 20, 17)      // 近黑的深青綠（底色）

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var onPage: ((Int) -> Void)?          // -1＝手指往右滑（看基礎設定）、+1＝手指往左滑（看本週）
    private var acc: CGFloat = 0
    private var fired = false
    private var dragX: CGFloat?
    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else { super.scrollWheel(with: e); return }
        if e.phase == .began || e.phase == .mayBegin { acc = 0; fired = false }
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX   // >0＝手指往右
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) { acc += dx }
        if !fired && abs(acc) > 70 { fired = true; onPage?(acc > 0 ? -1 : 1) }
        if e.phase == .ended || e.phase == .cancelled { acc = 0; fired = false }
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 123 { onPage?(1) } else if e.keyCode == 124 { onPage?(-1) } else { super.keyDown(with: e) }
    }
    override func mouseDown(with e: NSEvent) { dragX = e.locationInWindow.x }
    override func mouseUp(with e: NSEvent) {
        if let x0 = dragX { let dx = e.locationInWindow.x - x0; if abs(dx) > 140 { onPage?(dx > 0 ? -1 : 1) } }
        dragX = nil
    }
}

// 加字距的文字（細黑體 + 寬字距，是參考作品常見的「雜誌感」小字）
func spaced(_ lines: [(String, NSFont, NSColor, CGFloat)], align: NSTextAlignment = .center, gap: CGFloat = 6) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.paragraphSpacing = gap
    let out = NSMutableAttributedString()
    for (i, l) in lines.enumerated() {
        out.append(NSAttributedString(string: l.0 + (i < lines.count - 1 ? "\n" : ""), attributes: [
            .font: l.1, .foregroundColor: l.2, .kern: l.3, .paragraphStyle: para]))
    }
    return out
}

struct OverlayUI {
    let countdown: NSTextField
    let hint: NSTextField
    let title: NSTextField
    let note: NSTextField
    let skip: HoldButton
    let timeLine: NSTextField
}

// 要長按才會觸發的按鈕（防止手滑或習慣性跳過休息）；文字下方留一段距離，有一條淡淡的底線，
// 按住時一條柔和的淺黃綠亮線沿著底線慢慢拉長
final class HoldButton: NSButton {
    var onComplete: (() -> Void)?
    var idleTitle = ""
    private var timer: Timer?
    private var start = Date()
    private var progress: CGFloat = 0
    private var idleWidth: CGFloat = 0          // 沒按時文字的寬度＝線的總長（按住時文字變短，線不跟著縮）
    private let track = CALayer()
    private let bar = CAGradientLayer()
    private let lineGap: CGFloat = 18           // 線離文字底部的距離

    func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        track.backgroundColor = softWhite.withAlphaComponent(0.14).cgColor
        bar.colors = [paleLime.withAlphaComponent(0.15).cgColor, paleLime.cgColor, rgb(234, 230, 148).cgColor]
        bar.locations = [0, 0.6, 1]
        bar.startPoint = CGPoint(x: 0, y: 0.5); bar.endPoint = CGPoint(x: 1, y: 0.5)
        bar.cornerRadius = 1
        bar.shadowColor = paleLime.cgColor; bar.shadowOpacity = 0.35; bar.shadowRadius = 4; bar.shadowOffset = .zero
        layer?.addSublayer(track)
        layer?.addSublayer(bar)
        updateLine()
    }
    func show(_ t: String) {
        attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: softWhite.withAlphaComponent(0.55),
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .kern: 1.5])
        if t == idleTitle { idleWidth = attributedTitle.size().width }
        updateLine()
    }
    override func layout() { super.layout(); updateLine() }
    private func updateLine() {
        guard idleWidth > 0 else { return }
        // 線在文字下方（按鈕的層座標是上下顛倒的，往下＝y 增加）
        let x = bounds.width - idleWidth
        let y = bounds.height + lineGap
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: x, y: y, width: idleWidth, height: 1)
        bar.frame = CGRect(x: x, y: y - 0.5, width: idleWidth * progress, height: 2)
        bar.isHidden = progress <= 0
        CATransaction.commit()
    }
    private func setBar(_ p: CGFloat) { progress = p; updateLine() }
    override func mouseDown(with event: NSEvent) {
        start = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let el = Date().timeIntervalSince(self.start)
            if el >= holdSeconds {
                tm.invalidate(); self.timer = nil
                self.setBar(0); self.show(self.idleTitle)
                self.onComplete?()
            } else {
                self.setBar(CGFloat(el / holdSeconds))
                self.show("繼續按住… \(Int(ceil(holdSeconds - el)))")
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
    override func mouseUp(with event: NSEvent) {
        timer?.invalidate(); timer = nil
        setBar(0); show(idleTitle)
    }
}

// ---------- 儀表板（選單「儀表板」開窗）----------
// 字體與休息畫面相同（系統字體：超細數字＋小字寬字距）；每週日到週六一組，週日換新的一週。
final class DashText: NSTextField {
    var size: CGFloat = 12
    var weight: NSFont.Weight = .regular
    var tint: NSColor = softWhite
    var kern: CGFloat = 0
    var mono = false
    convenience init(_ size: CGFloat, _ weight: NSFont.Weight, _ tint: NSColor, kern: CGFloat = 0, mono: Bool = false) {
        self.init(frame: .zero)
        self.size = size; self.weight = weight; self.tint = tint; self.kern = kern; self.mono = mono
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
    }
    func put(_ s: String) {
        let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        attributedStringValue = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: tint, .kern: kern])
        sizeToFit()
    }
    func centered(_ s: String, cx: CGFloat, top: CGFloat, H: CGFloat) {
        put(s); frame.origin = CGPoint(x: cx - frame.width / 2, y: H - top - frame.height)
    }
    func left(_ s: String, x: CGFloat, top: CGFloat, H: CGFloat) {
        put(s); frame.origin = CGPoint(x: x, y: H - top - frame.height)
    }
}

final class DashCol {
    let day = DashText(12, .regular, softWhite, kern: 1)
    let fl = DashText(10, .regular, softWhite.withAlphaComponent(0.4), kern: 3)
    let fv = DashText(11, .regular, softWhite)
    let rl = DashText(10, .regular, softWhite.withAlphaComponent(0.4), kern: 3)
    let rv = DashText(11, .regular, softWhite)
    let fbar = CAGradientLayer()
    let rbar = CAGradientLayer()
}

final class Dashboard {
    var window: NSWindow?
    let W: CGFloat = 960, H: CGFloat = 740
    let content = NSView()
    let todayLab = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 4)
    let redNum = DashText(44, .ultraLight, softWhite, mono: true)
    let orgNum = DashText(44, .ultraLight, softWhite, mono: true)
    let fLab = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 4.5)
    let fNum = DashText(84, .ultraLight, softWhite, mono: true)
    let fUnit = DashText(22, .light, softWhite)
    let fHr = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 3)
    let rLab = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 4.5)
    let rNum = DashText(84, .ultraLight, rgb(255, 200, 130, 0.9), mono: true)
    let rUnit = DashText(22, .light, rgb(255, 200, 130, 0.9))
    let rHr = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 3)
    let chartLab = DashText(11, .regular, softWhite.withAlphaComponent(0.45), kern: 3)
    var cols: [DashCol] = []
    var lastSig = ""
    let dayNames = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]

    func orb(cx: CGFloat, topCy: CGFloat, d: CGFloat, red: Bool, glow: NSColor, top: NSColor, bottom: NSColor) {
        let cy = H - topCy
        let g = CAGradientLayer()
        g.type = .radial
        g.frame = CGRect(x: cx - d * 1.7, y: cy - d * 1.7, width: d * 3.4, height: d * 3.4)
        g.colors = [glow.withAlphaComponent(0.50).cgColor, glow.withAlphaComponent(0.20).cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        g.locations = [0, 0.35, 0.7, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
        content.layer?.addSublayer(g)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            func anim(_ key: String, _ a: CGFloat, _ b: CGFloat) -> CABasicAnimation {
                let x = CABasicAnimation(keyPath: key)
                x.fromValue = a; x.toValue = b; x.duration = 4; x.autoreverses = true; x.repeatCount = .infinity
                x.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return x
            }
            g.add(anim("transform.scale", 0.92, 1.08), forKey: "s")
            g.add(anim("opacity", 0.7, 1.0), forKey: "o")
        }
        let disc = CAGradientLayer()
        disc.frame = CGRect(x: cx - d / 2, y: cy - d * tomatoFlat / 2, width: d, height: d * tomatoFlat)
        disc.cornerRadius = d * tomatoFlat / 2
        disc.colors = [top.cgColor, bottom.cgColor]
        disc.startPoint = CGPoint(x: 0.2, y: 1); disc.endPoint = CGPoint(x: 0.8, y: 0)
        let fm = CAGradientLayer(); fm.type = .radial; fm.frame = disc.bounds
        fm.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fm.locations = [0, 0.9, 1]
        fm.startPoint = CGPoint(x: 0.5, y: 0.5); fm.endPoint = CGPoint(x: 1, y: 1)
        disc.mask = fm
        content.layer?.addSublayer(disc)
        if let cl = content.layer { orbFace(host: cl, x: cx - d / 2, cy: cy, d: d, red: red) }
    }

    func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "番茄鐘護眼｜儀表板"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = nightGreen
        w.appearance = NSAppearance(named: .darkAqua)
        buildContent(halo: true)
        w.contentView = content
        window = w
        w.center()
    }

    // 建出儀表板的內容（960×740）；halo＝true 時自帶底色與光暈（獨立視窗用），休息畫面裡不帶，直接用暗幕當底
    func buildContent(halo withHalo: Bool) {
        content.frame = NSRect(x: 0, y: 0, width: W, height: H)
        content.wantsLayer = true
        content.layer?.backgroundColor = withHalo ? nightGreen.cgColor : NSColor.clear.cgColor
        if withHalo {
            let halo = CAGradientLayer()
            halo.type = .radial
            halo.frame = CGRect(x: W * 0.12, y: H * 0.38, width: W * 0.76, height: H * 0.78)
            halo.colors = [deepTeal.withAlphaComponent(0.34).cgColor, deepTeal.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
            halo.locations = [0, 0.5, 1]
            halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
            content.layer?.addSublayer(halo)
        }
        orb(cx: 319, topCy: 119, d: 46, red: true, glow: rgb(255, 92, 72), top: rgb(255, 128, 104), bottom: rgb(226, 62, 56))
        orb(cx: 551, topCy: 119, d: 46, red: false, glow: rgb(255, 150, 60), top: rgb(255, 184, 96), bottom: rgb(240, 120, 40))
        for i in 0..<7 {
            let c = DashCol(); cols.append(c)
            for l in [c.fbar, c.rbar] { l.cornerRadius = 4; l.startPoint = CGPoint(x: 0.5, y: 1); l.endPoint = CGPoint(x: 0.5, y: 0); content.layer?.addSublayer(l) }
            _ = i
        }
        var views: [NSView] = [todayLab, redNum, orgNum, fLab, fNum, fUnit, fHr, rLab, rNum, rUnit, rHr, chartLab]
        for c in cols { views += [c.day, c.fl, c.fv, c.rl, c.rv] }
        for v in views { content.addSubview(v) }
    }

    func show() {
        if window == nil { build() }
        lastSig = ""
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func mins(_ s: Double) -> String { s <= 0 ? "—" : "\(Int((s / 60).rounded())) 分 · " + String(format: "%.1f", s / 3600) + " 小時" }

    func refresh() {
        guard let w = content.window, w.isVisible else { return }
        let f = timeLog("focusSec"), r = timeLog("restSec")
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 1      // 週日開頭
        guard let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return }
        let todayKey = dayFmt.string(from: Date())
        let seq = todaySeq()
        let reds = seq.filter { $0 == "R" }.count, oranges = seq.filter { $0 == "O" }.count
        let fT = timeToday(f), rT = timeToday(r)
        var days: [(key: String, label: String, fs: Double, rs: Double, today: Bool, future: Bool)] = []
        let md = DateFormatter(); md.dateFormat = "M/d"
        for i in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: i, to: start) else { continue }
            let k = dayFmt.string(from: d)
            days.append((k, "\(dayNames[i])　\(md.string(from: d))", f[k] ?? 0, r[k] ?? 0, k == todayKey, k > todayKey))
        }
        let sig = ([todayKey, "\(reds)", "\(oranges)"] + days.map { "\(Int($0.fs / 60)),\(Int($0.rs / 60))" }).joined(separator: "|")
        if sig == lastSig { return }
        lastSig = sig
        let cx = W / 2
        todayLab.centered("今天　TODAY", cx: cx, top: 44, H: H)
        redNum.left("× \(reds)", x: 364, top: 96, H: H)
        orgNum.left("× \(oranges)", x: 596, top: 96, H: H)
        for (lab, num, unit, hr, mid, secs) in [(fLab, fNum, fUnit, fHr, CGFloat(330), fT), (rLab, rNum, rUnit, rHr, CGFloat(650), rT)] {
            lab.centered(lab === fLab ? "專注" : "休息", cx: mid, top: 232, H: H)
            num.put("\(Int((secs / 60).rounded()))"); unit.put("分鐘")
            let total = num.frame.width + 8 + unit.frame.width, x0 = mid - total / 2
            num.frame.origin = CGPoint(x: x0, y: H - 252 - num.frame.height)
            unit.frame.origin = CGPoint(x: x0 + num.frame.width + 8, y: H - 252 - num.frame.height + 18)
            hr.centered(String(format: "%.1f 小時", secs / 3600), cx: mid, top: 360, H: H)
        }
        chartLab.left("本週　日 – 六　每週日重新開始　　左：專注　右：休息", x: 60, top: 432, H: H)
        let maxF = max(120 * 60, days.map { $0.fs }.max() ?? 0)
        let barH: CGFloat = 150, baseTop: CGFloat = 612
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, c) in cols.enumerated() where i < days.count {
            let d = days[i]
            let mid = 60 + 120 * CGFloat(i) + 60
            let dim: CGFloat = d.future ? 0.3 : (d.today ? 1.0 : 0.62)
            c.day.tint = softWhite.withAlphaComponent(d.today ? 0.95 : 0.55 * (d.future ? 0.6 : 1))
            c.day.centered(d.label, cx: mid, top: 626, H: H)
            c.fl.centered("專注", cx: mid, top: 650, H: H)
            c.fv.tint = softWhite.withAlphaComponent(0.9 * dim)
            c.fv.centered(d.future ? "—" : mins(d.fs), cx: mid, top: 664, H: H)
            c.rl.tint = rgb(255, 200, 130, 0.4)
            c.rl.centered("休息", cx: mid, top: 688, H: H)
            c.rv.tint = rgb(255, 200, 130, 0.9 * dim)
            c.rv.centered(d.future ? "—" : mins(d.rs), cx: mid, top: 702, H: H)
            let fh = d.fs > 0 ? max(3, CGFloat(d.fs / maxF) * barH) : 0
            let rh = d.rs > 0 ? max(3, CGFloat(d.rs / maxF) * barH) : 0
            let bottom = H - baseTop
            c.fbar.frame = CGRect(x: mid - 12, y: bottom, width: 8, height: fh)
            c.rbar.frame = CGRect(x: mid + 4, y: bottom, width: 8, height: rh)
            let fc: [CGColor] = d.today ? [paleLime.cgColor, deepTeal.cgColor] : [rgb(140, 201, 183, 0.28).cgColor, rgb(140, 201, 183, 0.28).cgColor]
            let rc: [CGColor] = d.today ? [rgb(255, 184, 96, 0.9).cgColor, rgb(240, 120, 40, 0.85).cgColor] : [rgb(255, 184, 96, 0.22).cgColor, rgb(255, 184, 96, 0.22).cgColor]
            c.fbar.colors = fc; c.rbar.colors = rc
        }
        CATransaction.commit()
    }
}


// ---------- 左下角紅橘光球的臉（蒂頭＋眼睛＋嘴巴）----------
let eyeColor = rgb(21, 48, 42, 0.92)
let tomatoFlat: CGFloat = 0.88          // 蕃茄光球扁一點點：高度是寬度的 88%
func orbFace(host: CALayer, x: CGFloat, cy: CGFloat, d: CGFloat, red: Bool) {
    let h = d * tomatoFlat
    let discTop = cy + h / 2
    // 蒂頭：四片細葉＋一小段梗（從 140×84 的設計稿等比縮放，柔綠）
    let sw = d * 0.62, sc = sw / 140
    let sx = x + d / 2 - sw / 2, oy = discTop + 0.2 * d
    func P(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: sx + px * sc, y: oy - py * sc) }
    let leaf = CGMutablePath()
    func lf(_ a: [(CGFloat, CGFloat)]) {      // a: 起點、第一段兩個控制點與終點、第二段兩個控制點與終點
        leaf.move(to: P(a[0].0, a[0].1))
        leaf.addCurve(to: P(a[3].0, a[3].1), control1: P(a[1].0, a[1].1), control2: P(a[2].0, a[2].1))
        leaf.addCurve(to: P(a[0].0, a[0].1), control1: P(a[4].0, a[4].1), control2: P(a[5].0, a[5].1))
        leaf.closeSubpath()
    }
    lf([(70, 46), (52, 30), (30, 30), (14, 38), (34, 44), (52, 52)])
    lf([(70, 46), (88, 30), (110, 30), (126, 38), (106, 44), (88, 52)])
    lf([(70, 46), (58, 50), (46, 62), (44, 76), (58, 68), (66, 60)])
    lf([(70, 46), (82, 50), (94, 62), (96, 76), (82, 68), (74, 60)])
    let green = rgb(94, 158, 106)
    let leafLayer = CAShapeLayer(); leafLayer.path = leaf; leafLayer.fillColor = green.cgColor
    host.addSublayer(leafLayer)
    let stem = CGMutablePath(); stem.move(to: P(70, 48)); stem.addCurve(to: P(76, 10), control1: P(69, 36), control2: P(70, 22))
    let stemLayer = CAShapeLayer(); stemLayer.path = stem; stemLayer.strokeColor = green.cgColor
    stemLayer.fillColor = nil; stemLayer.lineWidth = 8 * sc; stemLayer.lineCap = .round
    host.addSublayer(stemLayer)
    // 眼睛：兩顆小圓點（眼距 24%、眼徑 9%）
    let eg = d * 0.24, ed = d * 0.09
    for k in [-1, 1] {
        let e = CALayer()
        e.frame = CGRect(x: x + d / 2 + CGFloat(k) * eg / 2 - ed / 2, y: discTop - 0.52 * h - ed, width: ed, height: ed)
        e.cornerRadius = ed / 2; e.backgroundColor = eyeColor.cgColor
        host.addSublayer(e)
    }
    if red {
        // 腮紅：兩團很淡的柔光
        for bx in [0.16, 0.64] as [CGFloat] {
            let b = CAGradientLayer(); b.type = .radial
            b.frame = CGRect(x: x + bx * d - 0.06 * d, y: discTop - 0.72 * h - 0.04 * d, width: 0.32 * d, height: 0.2 * d)
            b.colors = [rgb(255, 190, 180, 0.45).cgColor, rgb(255, 190, 180, 0).cgColor]
            b.startPoint = CGPoint(x: 0.5, y: 0.5); b.endPoint = CGPoint(x: 1, y: 1)
            host.addSublayer(b)
        }
        // 嘴巴：一條細細的淺弧線，兩端圓
        let usc = d / 100
        let mx = x + d / 2 - 0.07 * d, my = discTop - 0.65 * h
        let m = CGMutablePath()
        m.move(to: CGPoint(x: mx + 1 * usc, y: my - 1 * usc))
        m.addQuadCurve(to: CGPoint(x: mx + 13 * usc, y: my - 1 * usc), control: CGPoint(x: mx + 7 * usc, y: my - 7 * usc))
        let ml = CAShapeLayer(); ml.path = m; ml.strokeColor = eyeColor.cgColor; ml.fillColor = nil
        ml.lineWidth = max(0.8, d * 0.03); ml.lineCap = .round
        host.addSublayer(ml)
    } else {
        // 橘色：一小橫嘴
        let mh = max(0.9, d * 0.032)
        let m = CALayer()
        m.frame = CGRect(x: x + d / 2 - 0.045 * d, y: discTop - 0.67 * h - mh, width: 0.09 * d, height: mh)
        m.cornerRadius = mh / 2; m.backgroundColor = eyeColor.cgColor
        host.addSublayer(m)
    }
}

// ---------- 休息畫面的左右分頁：左＝基礎設定、中＝休息、右＝本週儀表板（手指往右劃看設定、往左劃看本週）----------
struct SettingOption { let title: String; let isOn: () -> Bool; let tap: () -> Void }
struct SettingRow { let title: String; let options: [SettingOption] }

final class Chip: NSView {
    let titleText: String
    let label = DashText(13, .regular, softWhite)
    var onTap: (() -> Void)?
    var isOn = false { didSet { style() } }
    init(_ t: String) {
        titleText = t
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16; layer?.borderWidth = 1
        label.put(t)
        frame.size = CGSize(width: label.frame.width + 32, height: 32)
        label.frame.origin = CGPoint(x: 16, y: (32 - label.frame.height) / 2)
        addSubview(label)
        style()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onTap?() }
    func style() {
        layer?.borderColor = softWhite.withAlphaComponent(isOn ? 0.55 : 0.16).cgColor
        layer?.backgroundColor = softWhite.withAlphaComponent(isOn ? 0.14 : 0).cgColor
        label.tint = softWhite.withAlphaComponent(isOn ? 0.95 : 0.55)
        label.put(titleText)
    }
}

final class SettingsPage {
    let W: CGFloat = 960, H: CGFloat = 740
    let content = NSView()
    var chips: [(Chip, SettingOption)] = []
    init(rows: [SettingRow], onChange: @escaping () -> Void) {
        content.frame = NSRect(x: 0, y: 0, width: W, height: H)
        let head = DashText(12, .regular, softWhite.withAlphaComponent(0.45), kern: 4)
        head.centered("基礎設定　SETTINGS", cx: W / 2, top: 44, H: H)
        content.addSubview(head)
        var top: CGFloat = 130
        for row in rows {
            let lab = DashText(13, .regular, softWhite.withAlphaComponent(0.55), kern: 3)
            lab.left(row.title, x: 110, top: top + 8, H: H)
            content.addSubview(lab)
            var x: CGFloat = 370
            for opt in row.options {
                let c = Chip(opt.title)
                c.frame.origin = CGPoint(x: x, y: H - top - c.frame.height)
                c.onTap = { [weak self] in opt.tap(); self?.refresh(); onChange() }
                content.addSubview(c); chips.append((c, opt))
                x += c.frame.width + 12
            }
            top += 70
        }
        let foot = DashText(11, .regular, softWhite.withAlphaComponent(0.35), kern: 3)
        foot.centered("工作時間、休息時間、長休息：下一輪生效　　其餘馬上生效", cx: W / 2, top: 650, H: H)
        content.addSubview(foot)
        refresh()
    }
    func refresh() { for (c, o) in chips { c.isOn = o.isOn() } }
}

final class OverlayPages {
    let root: NSView
    let left = NSView(), right = NSView()
    let center: NSView
    let dash = Dashboard()
    let settings: SettingsPage
    var dots: [CALayer] = []
    init(size: CGSize, center: NSView, settings: SettingsPage, bottom: CGFloat) {
        root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        self.center = center; self.settings = settings
        dash.buildContent(halo: false)
        let o = CGPoint(x: (size.width - dash.W) / 2, y: (size.height - dash.H) / 2)
        for p in [left, right] { p.frame = NSRect(origin: .zero, size: size); p.wantsLayer = true }
        dash.content.frame.origin = o
        settings.content.frame.origin = o
        left.addSubview(settings.content)     // 手指往右劃 → 左邊那頁＝基礎設定
        right.addSubview(dash.content)        // 手指往左劃 → 右邊那頁＝本週儀表板
        for p in [left, center, right] { root.addSubview(p) }
        // 底部中間：三個小點＋「本週／設定」小字，提示可以左右滑
        let cx = size.width / 2, cy = bottom + 8
        for i in 0..<3 {
            let d = CALayer()
            d.frame = CGRect(x: cx - 3 + CGFloat(i - 1) * 16, y: cy - 3, width: 6, height: 6)
            d.cornerRadius = 3; d.backgroundColor = softWhite.cgColor
            root.layer?.addSublayer(d); dots.append(d)
        }
        let l = DashText(10, .regular, softWhite.withAlphaComponent(0.3), kern: 3)
        l.put("‹ 設定"); l.frame.origin = CGPoint(x: cx - 30 - l.frame.width, y: cy - l.frame.height / 2)
        let r = DashText(10, .regular, softWhite.withAlphaComponent(0.3), kern: 3)
        r.put("本週 ›"); r.frame.origin = CGPoint(x: cx + 30, y: cy - r.frame.height / 2)
        root.addSubview(l); root.addSubview(r)
    }
    func layout(page: Int, animated: Bool) {
        let w = root.bounds.width
        let targets: [(NSView, Int)] = [(left, -1), (center, 0), (right, 1)]
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (v, i) in targets { v.animator().setFrameOrigin(CGPoint(x: CGFloat(i - page) * w, y: 0)) }
            }
        } else {
            for (v, i) in targets { v.setFrameOrigin(CGPoint(x: CGFloat(i - page) * w, y: 0)) }
        }
        for (i, d) in dots.enumerated() { d.opacity = (i - 1 == page) ? 0.85 : 0.22 }
    }
}

final class App: NSObject, NSApplicationDelegate {
    let dashboard = Dashboard()
    var overlayPages: [OverlayPages] = []
    var restPage = 0
    var statusItem: NSStatusItem!
    var phase = Phase.work
    var deadline = Date()
    var paused = false
    var pausedRemaining: TimeInterval = 0
    var ticker: Timer?
    var overlays: [OverlayWindow] = []
    var overlayUIs: [OverlayUI] = []
    var restStart = Date()
    var restEndSound: NSSound?     // 要一直留著參照，聲音才不會播到一半被釋放
    var statusLine: NSMenuItem!
    var pauseItem: NSMenuItem!
    var workMenu: NSMenu!
    var restMenu: NSMenu!
    var loginItem: NSMenuItem!
    var tomatoTodayItem: NSMenuItem!
    var tomatoSumItem: NSMenuItem!
    var tomatoHistoryMenu: NSMenu!
    var timeFocusItem: NSMenuItem!
    var timeRestItem: NSMenuItem!
    var lastTickAt = Date()
    var tomatoDay = ""          // 上次刷新小蕃茄選單時的日期，換日時自動刷新
    var roundCount = 0          // 第幾次休息
    var restDebt = 0.0          // 欠的休息（分鐘），下一輪補
    var restNote = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        // 選單只留基本操作：這些項目仍會建立、更新文字，但不放進選單；統計改看休息畫面的儀表板
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tomatoTodayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tomatoSumItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let hItem = NSMenuItem(title: "小蕃茄紀錄", action: nil, keyEquivalent: "")
        tomatoHistoryMenu = NSMenu(); hItem.submenu = tomatoHistoryMenu
        timeFocusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        timeRestItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "暫停", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "現在就休息", action: #selector(restNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新開始工作計時", action: #selector(restartWork), keyEquivalent: ""))
        menu.addItem(.separator())
        let wItem = NSMenuItem(title: "工作時間（下一輪生效）", action: nil, keyEquivalent: "")
        workMenu = NSMenu()
        for m in workChoices {
            let i = NSMenuItem(title: "\(Int(m)) 分鐘", action: #selector(pickWork(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = m; workMenu.addItem(i)
        }
        wItem.submenu = workMenu; menu.addItem(wItem)
        let rItem = NSMenuItem(title: "休息時間（下一輪生效）", action: nil, keyEquivalent: "")
        restMenu = NSMenu()
        for m in restChoices {
            let i = NSMenuItem(title: "\(Int(m)) 分鐘", action: #selector(pickRest(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = m; restMenu.addItem(i)
        }
        rItem.submenu = restMenu; menu.addItem(rItem)
        refreshChecks()
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "隨開機開啟", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginEnabled() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "結束番茄鐘", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

        // 螢幕數量或解析度改變時，休息中要重鋪暗幕
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.phase == .rest else { return }
            self.buildOverlays()
        }
        refreshTomato()
        startWork()
        if args.contains("--dashboard") { dashboard.show() }
        if args.contains("--startrest") { startRest() }      // 測試／截圖用：一開就進休息畫面
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    // ---------- 階段切換 ----------
    func startWork() {
        phase = .work
        hideOverlays()
        deadline = Date().addingTimeInterval(workMinutes * 60)
        paused = false
        pauseItem.title = "暫停"
        update()
    }

    func startRest(earned: Bool = false, forced: Bool = false) {
        phase = .rest
        restStart = Date()
        roundCount += 1
        let isLong = longEvery > 0 && roundCount % longEvery == 0
        let base = isLong ? longRestMinutes : restMinutes
        let extra = min(restDebt, maxMakeup)
        restDebt = 0
        var notes: [String] = []
        if earned {                       // 完整做完一輪工作 → 小蕃茄 +1
            let n = addTomato()
            addToSeq("R")
            refreshTomato()
            if debugLog { print("TOMATO red today=\(n) week=\(tomatoWeek()) total=\(tomatoTotal()) seq=\(String(todaySeq()))") }
        } else if forced {                // 按「現在就休息」提早休息 → 多一顆橘蕃茄
            addToSeq("O")
            refreshTomato()
            if debugLog { print("TOMATO orange seq=\(String(todaySeq()))") }
        }
        if isLong { notes.append("第 \(roundCount) 輪，長休息") }
        if extra > 0 { notes.append(String(format: "含補休 %.1f 分鐘", extra)) }
        restNote = notes.joined(separator: "｜")
        deadline = Date().addingTimeInterval((base + extra) * 60)
        if debugLog { print(String(format: "REST round=%d base=%.2f extra=%.2f total=%.2f note=%@", roundCount, base, extra, base + extra, restNote)) }
        if let a = autoSkipAfter {
            let r = roundCount
            DispatchQueue.main.asyncAfter(deadline: .now() + a) { [weak self] in
                if let self = self, self.phase == .rest, self.roundCount == r { self.skipRest() }
            }
        }
        paused = false
        pauseItem.title = "暫停"
        play("Glass", times: 1)
        restPage = initialPage
        buildOverlays()
        if pageCycle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.changePage(-1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.changePage(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in self?.changePage(1) }
        }
        update()
    }

    func finishRest() {
        hideOverlays()
        playRestEnd()
        startWork()
    }

    // 休息結束的聲音：自製的太空漂浮長音（app 內的 RestEnd.m4a）；找不到檔案就退回系統的 Hero
    func playRestEnd() {
        if let url = Bundle.main.url(forResource: "RestEnd", withExtension: "m4a"),
           let s = NSSound(contentsOf: url, byReference: false) {
            restEndSound?.stop()
            restEndSound = s
            s.volume = endVolume      // 休息結束音量，預設 60%，可在休息畫面「基礎設定」改
            let ok = s.play()
            if debugLog { print(String(format: "PLAY rest-end ok=%@ duration=%.1f", ok ? "true" : "false", s.duration)) }
        } else {
            play("Hero", times: 3)
            if debugLog { print("PLAY fallback Hero") }
        }
    }

    // ---------- 計時 ----------
    func remaining() -> TimeInterval {
        paused ? pausedRemaining : max(0, deadline.timeIntervalSinceNow)
    }

    func tick() {
        // 累積實際專注／休息時間（暫停不算；間隔超過 3 秒＝電腦睡眠，不算）
        let now = Date(); let dt = now.timeIntervalSince(lastTickAt); lastTickAt = now
        if !paused && dt > 0 && dt < 3 { addTime(phase == .work ? "focusSec" : "restSec", dt) }
        if !paused && deadline.timeIntervalSinceNow <= 0 {
            if phase == .work { startRest(earned: true) } else { finishRest() }
            return
        }
        update()
    }

    func fmt(_ t: TimeInterval) -> String {
        let s = Int(ceil(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // 小蕃茄選單：今天（用 🍅 排出來）、本週與累積、最近 7 天、歸零
    func refreshTomato() {
        tomatoDay = dayFmt.string(from: Date())
        let t = tomatoToday()
        tomatoTodayItem.title = "今天  \(tomatoEmojiRow())" + (t > 0 ? "（\(t) 顆）" : "")
        tomatoSumItem.title = "本週 \(tomatoWeek()) 顆　累積 \(tomatoTotal()) 顆"
        tomatoHistoryMenu.removeAllItems()
        let log = tomatoLog()
        let wd = DateFormatter(); wd.locale = Locale(identifier: "zh_TW"); wd.dateFormat = "M/d（E）"
        for i in 0..<7 {
            guard let d = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let n = log[dayFmt.string(from: d)] ?? 0
            tomatoHistoryMenu.addItem(NSMenuItem(title: "\(wd.string(from: d))　\(n) 顆", action: nil, keyEquivalent: ""))
        }
        tomatoHistoryMenu.addItem(.separator())
        let reset = NSMenuItem(title: "全部歸零…", action: #selector(resetTomatoes), keyEquivalent: "")
        reset.target = self
        tomatoHistoryMenu.addItem(reset)
        if debugLog { print("MENU \(tomatoTodayItem.title) | \(tomatoSumItem.title)") }
    }

    // 專注／休息時間選單：只顯示今天（每天重新計算；過了午夜自動歸零顯示）
    func refreshTimeStats() {
        timeFocusItem.title = "專注　今天 \(durText(timeToday(timeLog("focusSec"))))"
        timeRestItem.title = "休息　今天 \(durText(timeToday(timeLog("restSec"))))"
    }

    @objc func resetTomatoes() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "要把所有小蕃茄歸零嗎？"
        a.informativeText = "目前累積 \(tomatoTotal()) 顆。歸零後無法復原。"
        a.addButton(withTitle: "取消")
        a.addButton(withTitle: "歸零")
        if a.runModal() == .alertSecondButtonReturn {
            tomatoStore.removeObject(forKey: "tomatoLog")
            tomatoStore.removeObject(forKey: "tomatoSeq")
            refreshTomato()
        }
    }

    func update() {
        if dayFmt.string(from: Date()) != tomatoDay { refreshTomato() }   // 過了午夜自動換日
        refreshTimeStats()
        dashboard.refresh()
        for p in overlayPages { p.dash.refresh() }
        let r = remaining()
        let icon = phase == .work ? "🍅" : "🌙"
        statusItem.button?.title = "\(icon) \(fmt(r))" + (paused ? " ⏸" : "")
        statusLine.title = (phase == .work ? "工作中，距離休息 " : "休息中，還有 ") + fmt(r)
        let timeLineText = "專注 \(durText(timeToday(timeLog("focusSec"))))　　休息 \(durText(timeToday(timeLog("restSec"))))"
        let t = Date().timeIntervalSince(restStart).truncatingRemainder(dividingBy: 8)
        for ui in overlayUIs {
            ui.countdown.stringValue = fmt(r)
            let inhale = t < 4
            ui.hint.attributedStringValue = spaced([
                (inhale ? "吸氣" : "吐氣", NSFont.systemFont(ofSize: 20, weight: .light), softWhite.withAlphaComponent(0.8), 8),
                (inhale ? "INHALE" : "EXHALE", NSFont.systemFont(ofSize: 11, weight: .regular), softWhite.withAlphaComponent(0.4), 5)], gap: 4)
            ui.note.stringValue = restNote
            ui.timeLine.stringValue = timeLineText
        }
    }

    // ---------- 暗幕 ----------
    // 平面光球（參考 Pinterest「Mind Balance」的發光圓盤）：邊緣清楚的平面圓，用乾淨的斜向漸層上色，
    // 沒有高光與陰影；圓盤外圍一圈帶顏色的光暈（上方偏淺黃綠、下方偏湖水青）。顏色取自參角點標準色與輔助色。
    func makeOrb(diameter D: CGFloat, center c: CGPoint) -> CALayer {
        let pad = D * 0.45                                   // 留空間給外圍光暈
        let host = CALayer()
        host.frame = CGRect(x: c.x - D / 2 - pad, y: c.y - D / 2 - pad, width: D + 2 * pad, height: D + 2 * pad)
        let discRect = CGRect(x: pad, y: pad, width: D, height: D)

        func glow(_ color: NSColor, dy: CGFloat, opacity: Float) {
            let g = CALayer()
            g.frame = discRect.insetBy(dx: D * 0.16, dy: D * 0.16)
            g.cornerRadius = D * 0.34
            g.backgroundColor = color.cgColor
            g.shadowColor = color.cgColor
            g.shadowOpacity = opacity
            g.shadowRadius = D * 0.22
            g.shadowOffset = CGSize(width: 0, height: dy)
            host.addSublayer(g)
        }
        glow(rgb(222, 224, 130), dy: D * 0.03, opacity: 0.80)
        glow(rgb(96, 178, 156), dy: -D * 0.03, opacity: 0.80)

        let disc = CAGradientLayer()
        disc.frame = discRect
        let sg = softGradient([(rgb(234, 230, 148), 0), (rgb(198, 214, 160), 0.30), (rgb(140, 201, 183), 0.66), (rgb(78, 138, 120), 1)])
        disc.colors = sg.colors
        disc.locations = sg.locations
        disc.startPoint = CGPoint(x: 0.22, y: 0.96)          // 左上
        disc.endPoint = CGPoint(x: 0.78, y: 0.04)            // 右下
        let feather = CAGradientLayer()
        feather.type = .radial
        feather.frame = disc.bounds
        var fc: [CGColor] = [], fl: [NSNumber] = []
        for n in 0..<28 {
            let t = CGFloat(n) / 27
            let u = max(0, (t - 0.72) / 0.28)
            let a = 1 - u * u * (3 - 2 * u)               // smoothstep：緩緩淡出
            fc.append(NSColor.white.withAlphaComponent(a).cgColor)
            fl.append(NSNumber(value: Double(t)))
        }
        feather.colors = fc
        feather.locations = fl
        feather.startPoint = CGPoint(x: 0.5, y: 0.5)
        feather.endPoint = CGPoint(x: 1.0, y: 1.0)
        disc.mask = feather
        host.addSublayer(disc)
        return host
    }

    func glowLayer(diameter d: CGFloat, center c: CGPoint, colors: [NSColor]) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        g.colors = colors.map { $0.cgColor } + [NSColor.clear.cgColor, NSColor.clear.cgColor]
        g.locations = [0, 0.35, 0.7, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        return g
    }

    // 呼吸：吸氣 4 秒放大、吐氣 4 秒縮小（用 autoreverse）；重鋪畫面時用 timeOffset 對上目前的呼吸節奏
    func breathe(_ layer: CALayer, from: CGFloat, to: CGFloat, fade: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        let offset = Date().timeIntervalSince(restStart).truncatingRemainder(dividingBy: 8)
        func anim(_ key: String, _ a: CGFloat, _ b: CGFloat) -> CABasicAnimation {
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = a; x.toValue = b
            x.duration = 4
            x.autoreverses = true
            x.repeatCount = .infinity
            x.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            x.timeOffset = offset
            return x
        }
        layer.add(anim("transform.scale", from, to), forKey: "breatheScale")
        if fade { layer.add(anim("opacity", 0.7, 1.0), forKey: "breatheFade") }
    }

    func label(_ size: CGFloat, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font
        l.textColor = color
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    func buildOverlays() {
        hideOverlays()
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false
            w.backgroundColor = nightGreen.withAlphaComponent(args.contains("--opaque") ? 1.0 : 0.96)   // --opaque：截圖用，完全不透出底下視窗
            w.isOpaque = false
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.setFrame(screen.frame, display: true)

            let size = screen.frame.size
            let S = min(size.width, size.height) * 0.74          // 光暈直徑
            let D = S * 0.60                                      // 光球直徑
            let center = CGPoint(x: size.width / 2, y: size.height * 0.56)   // 光球中心（約在畫面上方 44% 處）

            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.wantsLayer = true
            content.layerUsesCoreImageFilters = true
            // 遠處的柔光（淡）→ 光球 → 一圈極細的線（像水波）；三者隨呼吸漲縮、節奏略錯開
            let halo = glowLayer(diameter: S * 1.15, center: center,
                                 colors: [paleLime.withAlphaComponent(0.20), deepTeal.withAlphaComponent(0.30)])
            content.layer?.addSublayer(halo)
            breathe(halo, from: 0.90, to: 1.08, fade: true)
            let orb = makeOrb(diameter: D, center: center)
            content.layer?.addSublayer(orb)
            breathe(orb, from: 0.90, to: 1.08, fade: false)
            let rd = D * 1.16
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: center.x - rd / 2, y: center.y - rd / 2, width: rd, height: rd)
            ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: rd, height: rd), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = softWhite.withAlphaComponent(0.16).cgColor
            ring.lineWidth = 1
            content.layer?.addSublayer(ring)
            breathe(ring, from: 0.93, to: 1.05, fade: false)

            let sans = { (sz: CGFloat, wt: NSFont.Weight) in NSFont.systemFont(ofSize: sz, weight: wt) }
            let countdown = label(S, NSFont.monospacedDigitSystemFont(ofSize: S * 0.15, weight: .ultraLight), softWhite)
            let hint = label(S, sans(20, .light), softWhite)
            let title = label(S, sans(20, .light), softWhite)
            title.attributedStringValue = spaced([
                ("休息一下，看看遠方", sans(max(18, S * 0.04), .light), softWhite.withAlphaComponent(0.85), 10),
                ("TAKE A BREAK · LOOK FAR AWAY", sans(11, .regular), softWhite.withAlphaComponent(0.4), 5)], gap: 8)
            let note = label(S, sans(13, .regular), softWhite.withAlphaComponent(0.5))
            note.alignment = .left

            let skip = HoldButton(title: "", target: nil, action: nil)
            skip.isBordered = false
            skip.translatesAutoresizingMaskIntoConstraints = false
            skip.idleTitle = "提早結束休息（長按 \(Int(holdSeconds)) 秒）"
            skip.setup()
            skip.show(skip.idleTitle)
            skip.onComplete = { [weak self] in self?.skipRest() }

            let timeLine = label(S, sans(12, .regular), softWhite.withAlphaComponent(0.5))
            timeLine.alignment = .left
            for v in [countdown, hint, title, note, skip, timeLine] as [NSView] { content.addSubview(v) }
            let mx = size.width * 0.05, my = size.height * 0.055

            // 左下角：今天的小蕃茄，一顆一顆排成一列（紅＝完整做完一輪、橘＝提早休息），沒有數字
            let seq = todaySeq()
            // 左下角：今天的「紅色光球 × 數字」「橘色光球 × 數字」（光球跟中間的光球同一種平面柔光；每天重新計算）
            let reds = seq.filter { $0 == "R" }.count, oranges = seq.filter { $0 == "O" }.count
            let d = max(14, size.height * 0.024)                    // 光球直徑
            let rowH = d * 1.8
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            var x: CGFloat = 0
            let gapGroup = d * 1.8
            func addGroup(_ count: Int, red: Bool, glow: NSColor, top: NSColor, bottom: NSColor) {
                guard count > 0 else { return }
                let cy = rowH / 2
                let gl = glowLayer(diameter: d * 3.4, center: CGPoint(x: x + d / 2, y: cy),
                                   colors: [glow.withAlphaComponent(0.50), glow.withAlphaComponent(0.20)])
                row.layer?.addSublayer(gl)
                breathe(gl, from: 0.90, to: 1.10, fade: true)
                let disc = CAGradientLayer()
                disc.frame = CGRect(x: x, y: cy - d * tomatoFlat / 2, width: d, height: d * tomatoFlat)
                disc.cornerRadius = d * tomatoFlat / 2
                disc.colors = [top.cgColor, bottom.cgColor]
                disc.startPoint = CGPoint(x: 0.2, y: 1); disc.endPoint = CGPoint(x: 0.8, y: 0)
                // 邊緣柔化：外緣一小圈慢慢淡出（比硬邊柔、不糊）
                let fm = CAGradientLayer(); fm.type = .radial; fm.frame = disc.bounds
                fm.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
                fm.locations = [0, 0.9, 1]
                fm.startPoint = CGPoint(x: 0.5, y: 0.5); fm.endPoint = CGPoint(x: 1, y: 1)
                disc.mask = fm
                row.layer?.addSublayer(disc)
                if let rl = row.layer { orbFace(host: rl, x: x, cy: cy, d: d, red: red) }
                let num = NSTextField(labelWithString: "× \(count)")
                num.font = NSFont.monospacedDigitSystemFont(ofSize: d * 0.85, weight: .ultraLight)
                num.textColor = softWhite.withAlphaComponent(0.85)
                num.sizeToFit()
                num.frame.origin = CGPoint(x: x + d + d * 0.45, y: cy - num.frame.height / 2)
                row.addSubview(num)
                x += d + d * 0.45 + num.frame.width + gapGroup
            }
            addGroup(reds, red: true, glow: rgb(255, 92, 72), top: rgb(255, 128, 104), bottom: rgb(226, 62, 56))
            addGroup(oranges, red: false, glow: rgb(255, 150, 60), top: rgb(255, 184, 96), bottom: rgb(240, 120, 40))
            let maxX = max(1, x - gapGroup)
            content.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: mx),
                timeLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: mx),
                timeLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -my),
                row.bottomAnchor.constraint(equalTo: timeLine.topAnchor, constant: -4),
                row.widthAnchor.constraint(equalToConstant: maxX),
                row.heightAnchor.constraint(equalToConstant: seq.isEmpty ? 1 : rowH),
            ])
            NSLayoutConstraint.activate([
                countdown.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                countdown.topAnchor.constraint(equalTo: content.topAnchor, constant: size.height * 0.44 + D * 0.58 + S * 0.03),
                hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                hint.topAnchor.constraint(equalTo: countdown.bottomAnchor, constant: S * 0.012),
                title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                title.topAnchor.constraint(equalTo: content.topAnchor, constant: size.height * 0.075),
                note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: mx),
                note.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
                skip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -mx),
                skip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -my),
            ])
            let pages = OverlayPages(size: size, center: content, settings: makeSettingsPage(), bottom: my)
            pages.layout(page: restPage, animated: false)
            w.contentView = pages.root
            w.onPage = { [weak self] d in self?.changePage(d) }
            w.orderFrontRegardless()
            overlays.append(w)
            overlayPages.append(pages)
            overlayUIs.append(OverlayUI(countdown: countdown, hint: hint, title: title, note: note, skip: skip, timeLine: timeLine))
        }
        NSApp.activate(ignoringOtherApps: true)
        update()
    }

    func hideOverlays() {
        for w in overlays { w.orderOut(nil); w.close() }
        overlays.removeAll()
        overlayUIs.removeAll()
        overlayPages.removeAll()
    }

    // ---------- 聲音 ----------
    func play(_ name: String, times: Int) {
        DispatchQueue.global().async {
            for _ in 0..<times {
                if let s = NSSound(named: name) { s.play(); Thread.sleep(forTimeInterval: max(1.0, s.duration + 0.3)) }
            }
        }
    }

    // ---------- 休息畫面：換頁與設定 ----------
    func changePage(_ d: Int) {
        guard phase == .rest else { return }
        let np = max(-1, min(1, restPage + d))
        if np == restPage { return }
        restPage = np
        for p in overlayPages { p.layout(page: np, animated: true) }
    }
    func applyWork(_ m: Double) { workMinutes = m; defaults.set(m, forKey: "workMinutes") }
    func applyRest(_ m: Double) { restMinutes = m; defaults.set(m, forKey: "restMinutes") }
    func applyLongEvery(_ n: Int) { longEvery = n; defaults.set(n, forKey: "longEvery") }
    func applyLongRest(_ m: Double) { longRestMinutes = m; defaults.set(m, forKey: "longRest") }
    func applyHold(_ s: Double) {
        holdSeconds = s; defaults.set(s, forKey: "holdSec")
        for ui in overlayUIs { ui.skip.idleTitle = "提早結束休息（長按 \(Int(s)) 秒）"; ui.skip.show(ui.skip.idleTitle) }
    }
    func applyVolume(_ v: Float) { endVolume = v; defaults.set(v, forKey: "endVolume"); previewEndSound() }
    func previewEndSound() {     // 調音量時試聽 1.5 秒
        guard let url = Bundle.main.url(forResource: "RestEnd", withExtension: "m4a"),
              let s = NSSound(contentsOf: url, byReference: false) else { return }
        restEndSound?.stop(); restEndSound = s; s.volume = endVolume; s.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak s] in s?.stop() }
    }
    func syncSettings() {
        refreshChecks()
        loginItem.state = loginEnabled() ? .on : .off
        for p in overlayPages { p.settings.refresh() }
    }
    func makeSettingsPage() -> SettingsPage {
        func opts<T: Equatable>(_ vals: [T], _ title: @escaping (T) -> String, _ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> [SettingOption] {
            vals.map { v in SettingOption(title: title(v), isOn: { get() == v }, tap: { set(v) }) }
        }
        let rows = [
            SettingRow(title: "工作時間（分鐘）", options: opts(workChoices, { "\(Int($0))" }, { workMinutes }, { [weak self] in self?.applyWork($0) })),
            SettingRow(title: "休息時間（分鐘）", options: opts(restChoices, { "\(Int($0))" }, { restMinutes }, { [weak self] in self?.applyRest($0) })),
            SettingRow(title: "長休息頻率", options: opts([3, 4, 6, 0], { $0 == 0 ? "不用" : "每 \($0) 輪" }, { longEvery }, { [weak self] in self?.applyLongEvery($0) })),
            SettingRow(title: "長休息時間（分鐘）", options: opts([10.0, 15, 20, 30], { "\(Int($0))" }, { longRestMinutes }, { [weak self] in self?.applyLongRest($0) })),
            SettingRow(title: "提早結束要長按（秒）", options: opts([3.0, 5, 8, 10], { "\(Int($0))" }, { holdSeconds }, { [weak self] in self?.applyHold($0) })),
            SettingRow(title: "休息結束音量", options: opts([0.2, 0.4, 0.6, 0.8, 1.0] as [Float], { "\(Int(($0 * 100).rounded()))%" }, { endVolume }, { [weak self] in self?.applyVolume($0) })),
            SettingRow(title: "隨開機開啟", options: [
                SettingOption(title: "開", isOn: { loginEnabled() }, tap: { _ = setLogin(true) }),
                SettingOption(title: "關", isOn: { !loginEnabled() }, tap: { _ = setLogin(false) })]),
        ]
        return SettingsPage(rows: rows, onChange: { [weak self] in self?.syncSettings() })
    }

    // ---------- 選單動作 ----------
    @objc func togglePause() {
        guard phase == .work else { return }   // 休息中不能暫停
        if paused {
            deadline = Date().addingTimeInterval(pausedRemaining)
            paused = false
            pauseItem.title = "暫停"
        } else {
            pausedRemaining = max(0, deadline.timeIntervalSinceNow)
            paused = true
            pauseItem.title = "繼續"
        }
        update()
    }
    func refreshChecks() {
        for i in workMenu.items { i.state = (i.representedObject as? Double) == workMinutes ? .on : .off }
        for i in restMenu.items { i.state = (i.representedObject as? Double) == restMinutes ? .on : .off }
    }
    @objc func pickWork(_ s: NSMenuItem) {
        guard let m = s.representedObject as? Double else { return }
        workMinutes = m; defaults.set(m, forKey: "workMinutes"); refreshChecks()
    }
    @objc func pickRest(_ s: NSMenuItem) {
        guard let m = s.representedObject as? Double else { return }
        restMinutes = m; defaults.set(m, forKey: "restMinutes"); refreshChecks()
    }
    @objc func toggleLogin() {
        let err = setLogin(!loginEnabled())
        loginItem.state = loginEnabled() ? .on : .off
        if !err.isEmpty {
            let a = NSAlert()
            a.messageText = "無法設定隨開機開啟"
            a.informativeText = err + "\n\n請把 app 放在「應用程式」資料夾再試，或到 系統設定 → 一般 → 登入項目 手動加入。"
            a.runModal()
        }
    }
    @objc func openDashboard() { dashboard.show() }
    @objc func restNow() { startRest(forced: true) }
    @objc func restartWork() { startWork() }
    // 提早結束休息：沒休完的時間記成「欠的休息」，下一輪補（最多補 5 分鐘）
    @objc func skipRest() {
        let owed = remaining() / 60
        restDebt = min(maxMakeup, restDebt + owed)
        addToSeq("O")        // 提早結束休息 → 下一次休息畫面多一顆橘色光球
        if debugLog { print(String(format: "SKIP owed=%.2f debt=%.2f", owed, restDebt)) }
        startWork()
    }
    @objc func quit() { hideOverlays(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不佔 Dock，只出現在選單列
let delegate = App()
app.delegate = delegate
app.run()
