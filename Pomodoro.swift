// 番茄鐘護眼：每 25 分鐘把所有螢幕蓋上暗幕、休息 5 分鐘，結束時響鈴，自動開始下一輪。
// 用法：Pomodoro [--work 分鐘] [--rest 分鐘]（可小數，測試用）
// 規則：提早結束休息要長按 5 秒；跳過的休息會補到下一輪（最多補 5 分鐘）；每 4 輪休 15 分鐘
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
if let v = numArg("--long") { longRestMinutes = v }
if let v = numArg("--every") { longEvery = Int(v) }
if let v = numArg("--hold") { holdSeconds = v }
if let v = numArg("--autoskip") { autoSkipAfter = v }
debugLog = args.contains("--debug")
if debugLog { setvbuf(stdout, nil, _IOLBF, 0) }
if let i = args.firstIndex(of: "--work"), i + 1 < args.count, let v = Double(args[i + 1]) { workMinutes = v }
if let i = args.firstIndex(of: "--rest"), i + 1 < args.count, let v = Double(args[i + 1]) { restMinutes = v }

enum Phase { case work, rest }

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
}

// 要長按才會觸發的按鈕（防止手滑或習慣性跳過休息）；按住時底下的檸檬黃細線會慢慢拉長
final class HoldButton: NSButton {
    var onComplete: (() -> Void)?
    var idleTitle = ""
    private var timer: Timer?
    private var start = Date()
    private let bar = CALayer()

    func setup() {
        wantsLayer = true
        bar.backgroundColor = lemon.cgColor
        bar.frame = CGRect(x: 0, y: 0, width: 0, height: 2)
        layer?.addSublayer(bar)
    }
    func show(_ t: String) {
        attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: softWhite.withAlphaComponent(0.55),
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .kern: 1.5])
    }
    private func setBar(_ progress: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: 2)
        CATransaction.commit()
    }
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

final class App: NSObject, NSApplicationDelegate {
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
    var roundCount = 0          // 第幾次休息
    var restDebt = 0.0          // 欠的休息（分鐘），下一輪補
    var restNote = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
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
        startWork()
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

    func startRest() {
        phase = .rest
        restStart = Date()
        roundCount += 1
        let isLong = longEvery > 0 && roundCount % longEvery == 0
        let base = isLong ? longRestMinutes : restMinutes
        let extra = min(restDebt, maxMakeup)
        restDebt = 0
        var notes: [String] = []
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
        buildOverlays()
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
            s.volume = 1.0
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
        if !paused && deadline.timeIntervalSinceNow <= 0 {
            if phase == .work { startRest() } else { finishRest() }
            return
        }
        update()
    }

    func fmt(_ t: TimeInterval) -> String {
        let s = Int(ceil(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func update() {
        let r = remaining()
        let icon = phase == .work ? "🍅" : "🌙"
        statusItem.button?.title = "\(icon) \(fmt(r))" + (paused ? " ⏸" : "")
        statusLine.title = (phase == .work ? "工作中，距離休息 " : "休息中，還有 ") + fmt(r)
        let t = Date().timeIntervalSince(restStart).truncatingRemainder(dividingBy: 8)
        for ui in overlayUIs {
            ui.countdown.stringValue = fmt(r)
            let inhale = t < 4
            ui.hint.attributedStringValue = spaced([
                (inhale ? "吸氣" : "吐氣", NSFont.systemFont(ofSize: 20, weight: .light), softWhite.withAlphaComponent(0.8), 8),
                (inhale ? "INHALE" : "EXHALE", NSFont.systemFont(ofSize: 11, weight: .regular), softWhite.withAlphaComponent(0.4), 5)], gap: 4)
            ui.note.stringValue = restNote
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
            w.backgroundColor = nightGreen.withAlphaComponent(0.96)
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

            for v in [countdown, hint, title, note, skip] as [NSView] { content.addSubview(v) }
            let mx = size.width * 0.05, my = size.height * 0.055
            NSLayoutConstraint.activate([
                countdown.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                countdown.topAnchor.constraint(equalTo: content.topAnchor, constant: size.height * 0.44 + D * 0.58 + S * 0.03),
                hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                hint.topAnchor.constraint(equalTo: countdown.bottomAnchor, constant: S * 0.012),
                title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                title.topAnchor.constraint(equalTo: content.topAnchor, constant: size.height * 0.075),
                note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: mx),
                note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -my),
                skip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -mx),
                skip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -my),
            ])
            w.contentView = content
            w.orderFrontRegardless()
            overlays.append(w)
            overlayUIs.append(OverlayUI(countdown: countdown, hint: hint, title: title, note: note))
        }
        NSApp.activate(ignoringOtherApps: true)
        update()
    }

    func hideOverlays() {
        for w in overlays { w.orderOut(nil); w.close() }
        overlays.removeAll()
        overlayUIs.removeAll()
    }

    // ---------- 聲音 ----------
    func play(_ name: String, times: Int) {
        DispatchQueue.global().async {
            for _ in 0..<times {
                if let s = NSSound(named: name) { s.play(); Thread.sleep(forTimeInterval: max(1.0, s.duration + 0.3)) }
            }
        }
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
    @objc func restNow() { startRest() }
    @objc func restartWork() { startWork() }
    // 提早結束休息：沒休完的時間記成「欠的休息」，下一輪補（最多補 5 分鐘）
    @objc func skipRest() {
        let owed = remaining() / 60
        restDebt = min(maxMakeup, restDebt + owed)
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
