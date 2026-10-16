// ============================================================
//  TunnelBar — Claude Tunnel Proxy 菜单栏前端
//  --------------------------------------------
//  圆点颜色 = 隧道状态（与 tunnel-daemon.sh 的四种状态一一对应）：
//    ⚪ 白色（常亮）  静默      没有任何进程在运行
//    🟢 绿色（常亮）  完全启动  代理 + SSH 隧道 都在运行
//    🟠 橙色（闪烁）  部分启动  两个组件掉了一个
//    🔴 红色（闪烁）  致命错误  配置错误 / 启动失败，需要人工处理
//
//  点击圆点弹出菜单：启动 / 停止 / 重启 / 看日志 / 打开目录 / 退出
//  菜单顶部会写清楚「是哪个组件没起来」，不用再猜部分启动到底缺什么。
// ============================================================

import AppKit

// 项目目录：由 app 自身位置反推，不硬编码绝对路径。
// TunnelBar.app 位于项目根目录下，向上退一级即为项目根，
// 因此整个项目可随意移动，无需重新编译。
let projectDir: String = {
    let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()  // …/TunnelBar.app
    return appURL.deletingLastPathComponent().path                // 项目根
}()

// MARK: - 状态

enum TunnelState: String {
    case running, partial, fatal, stopped

    init(raw: String) {
        self = TunnelState(rawValue: raw) ?? .stopped
    }

    /// 只有这两种状态需要闪烁
    var blinks: Bool { self == .partial || self == .fatal }

    var color: NSColor {
        switch self {
        case .running: return .systemGreen
        case .partial: return .systemOrange
        case .fatal:   return .systemRed
        case .stopped: return .white
        }
    }

    var label: String {
        switch self {
        case .running: return "完全启动"
        case .partial: return "部分启动"
        case .fatal:   return "致命错误"
        case .stopped: return "静默"
        }
    }
}

/// tunnel-daemon.sh probe 的输出
struct TunnelStatus {
    var state: TunnelState = .stopped
    var proxyUp = false
    var sshUp = false
    var proxyPID = ""
    var sshPID = ""
    var host = ""
    var proxyAddr = ""
    var remotePort = ""
    var detail = ""
    var reason = ""
    var watch = "off"          // off / on / paused
    var watchPID = ""

    /// 解析 key=value 行（值里可以再出现 '='，所以只切第一个）
    static func parse(_ text: String) -> TunnelStatus {
        var kv: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            // 注意：值可能为空（如 "reason="），这里必须用区间取值。
            // 写成 line[line.index(after: eq)] 会拿到 endIndex 处的下标，越界崩溃。
            kv[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }

        // 读不到状态（脚本被删/被挪、权限不足、bash 报错）时不要假装"静默"，
        // 那会是一个谎报的白色圆点；报成致命错误，让人一眼看出前端坏了。
        guard kv["state"] != nil else {
            var bad = TunnelStatus()
            bad.state = .fatal
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            bad.reason = first.isEmpty
                ? "读不到隧道状态：tunnel-daemon.sh 没有输出"
                : "读不到隧道状态：\(first)"
            bad.detail = bad.reason
            return bad
        }

        var s = TunnelStatus()
        s.state     = TunnelState(raw: kv["state"] ?? "stopped")
        s.proxyUp   = kv["proxy"] == "up"
        s.sshUp     = kv["ssh"] == "up"
        s.proxyPID  = kv["proxy_pid"] ?? ""
        s.sshPID    = kv["ssh_pid"] ?? ""
        s.host      = kv["host"] ?? ""
        s.proxyAddr = kv["proxy_addr"] ?? ""
        s.remotePort = kv["remote_port"] ?? ""
        s.detail    = kv["detail"] ?? ""
        s.reason    = kv["reason"] ?? ""
        s.watch     = kv["watch"] ?? "off"
        s.watchPID  = kv["watch_pid"] ?? ""
        return s
    }

    /// 菜单顶部那行：说清到底缺什么，而不是只丢一个"部分启动"
    var headline: String {
        switch state {
        case .running: return "完全启动：代理 + SSH 隧道 均在运行"
        case .partial: return "部分启动：" + (proxyUp ? "SSH 隧道已断开" : "本地代理已退出")
        case .fatal:   return "致命错误：" + (reason.isEmpty ? "需要人工处理" : reason)
        case .stopped: return "静默：未启动"
        }
    }

    var proxyLine: String {
        proxyUp ? "运行中 · PID \(proxyPID)" : "未运行"
    }
    var sshLine: String {
        sshUp ? "运行中 · PID \(sshPID)" : "未运行"
    }

    /// 看门狗那一行
    var watchLine: String {
        watch == "on"
            ? "已开启" + (watchPID.isEmpty ? "" : " · PID \(watchPID)") + "（随隧道启停）"
            : "未开启"
    }

    var watchOn: Bool { watch == "on" }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var blinkTimer: Timer?

    private var status = TunnelStatus()
    private var blinkOn = true
    private var busy = false          // 正在执行 start/stop

    private let menu = NSMenu()
    private var menuIsOpen = false
    // 会随状态变化的行：菜单开着时就地改字，不用重开菜单
    private var statusRows: [(item: NSMenuItem, key: String, value: () -> String)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = dotImage(.white)
        item.button?.toolTip = "Claude Tunnel Proxy"
        menu.delegate = self
        item.menu = menu                 // 交给系统弹菜单；内容在 menuNeedsUpdate 里现算
        statusItem = item

        schedulePoll(3.0)
        refresh()
    }

    // MARK: - 圆点图标

    /// 直接画一个彩色圆点。
    ///
    /// 这里刻意不用 `NSImage(systemSymbolName:)` + `isTemplate` + `contentTintColor`：
    /// template 图像在状态栏里会被系统按菜单栏前景色重绘，contentTintColor 不生效，
    /// 圆点会永远是一个颜色（启动后图标不变化，就是踩了这个坑）。
    /// 非 template 的图不会被系统染，画什么颜色就是什么颜色。
    private func dotImage(_ color: NSColor, dimmed: Bool = false) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5))

            if dimmed {
                color.withAlphaComponent(0.22).setFill()
                circle.fill()
            } else {
                color.setFill()
                circle.fill()
                // 白色圆点在浅色菜单栏上会看不见，描一圈细边兜底
                if color == .white {
                    NSColor.black.withAlphaComponent(0.45).setStroke()
                    circle.lineWidth = 0.8
                    circle.stroke()
                }
            }
            return true
        }
        img.isTemplate = false     // 关键：不要让系统重绘
        return img
    }

    /// 按当前状态刷新圆点（含闪烁相位）
    private func paintIcon() {
        guard let button = statusItem?.button else { return }
        let dimmed = status.state.blinks && !blinkOn
        button.image = dotImage(status.state.color, dimmed: dimmed)

        let tip = "Claude Tunnel Proxy — \(status.state.label)：\(status.detail)"
        button.toolTip = tip
        button.setAccessibilityLabel("Claude Tunnel Proxy \(status.state.label)")
    }

    /// 需要闪烁的状态开闪烁定时器，其余关掉
    private func updateBlinkTimer() {
        if status.state.blinks {
            blinkOn = true
            guard blinkTimer == nil else { return }
            let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkOn.toggle()
                self.paintIcon()
            }
            RunLoop.main.add(t, forMode: .common)   // .common：菜单打开时也继续闪
            blinkTimer = t
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
    }

    // MARK: - 状态轮询

    private func schedulePoll(_ interval: TimeInterval) {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 到后台线程问一次状态，回到主线程更新界面（别阻塞菜单的 run loop）
    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = TunnelStatus.parse(self.runDaemon("probe"))
            DispatchQueue.main.async {
                self.status = status
                self.updateBlinkTimer()
                self.paintIcon()
                if self.menuIsOpen { self.syncStatusRows() }
            }
        }
    }

    // MARK: - 执行脚本

    @discardableResult
    private func runDaemon(_ command: String) -> String {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [projectDir + "/tunnel-daemon.sh", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Finder 启动的 app 环境很干净，补上脚本可能用到的 PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        task.environment = env
        do {
            try task.run()
        } catch {
            return "state=fatal\nreason=无法执行 tunnel-daemon.sh（\(error.localizedDescription)）\n"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 菜单

    // 每次打开菜单前都会走这里：现算一次状态，保证菜单里没有过期信息
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !busy else { return }
        status = TunnelStatus.parse(runDaemon("probe"))
        updateBlinkTimer()
        paintIcon()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func rebuildMenu() {
        menu.autoenablesItems = false    // 自己控制，标题行才能保持正常颜色
        menu.removeAllItems()
        statusRows = []

        // ---- 状态区：先说清「完全启动 / 部分启动 / 致命错误」 ----
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = dotImage(status.state.color)
        style(head, status.headline, color: status.state.color, bold: true)
        menu.addItem(head)
        statusRows.append((head, "", { [weak self] in self?.status.headline ?? "" }))

        addStatusRow(to: menu, key: "本地代理", value: { [weak self] in self?.status.proxyLine ?? "" })
        addStatusRow(to: menu, key: "SSH 隧道", value: { [weak self] in self?.status.sshLine ?? "" })
        addStatusRow(to: menu, key: "远程主机", value: { [weak self] in self?.hostLine ?? "" })
        addStatusRow(to: menu, key: "代理地址", value: { [weak self] in self?.status.proxyAddr ?? "" })
        addStatusRow(to: menu, key: "自动重连", value: { [weak self] in self?.status.watchLine ?? "" })

        menu.addItem(.separator())

        // ---- 操作 ----
        let start = action("启动隧道", #selector(startTunnel), symbol: "play.fill")
        start.isEnabled = !busy && status.state != .running
        menu.addItem(start)

        let stop = action("停止隧道", #selector(stopTunnel), symbol: "stop.fill")
        stop.isEnabled = !busy && status.state != .stopped
        menu.addItem(stop)

        let restart = action("重新启动", #selector(restartTunnel), symbol: "arrow.clockwise")
        restart.isEnabled = !busy
        menu.addItem(restart)

        menu.addItem(.separator())

        // ---- 看门狗：掉线自动重连（默认跟着隧道一起启停）----
        let watch = action(status.watchOn ? "暂停自动重连（本次）" : "开启自动重连",
                           #selector(toggleWatchdog), symbol: "arrow.triangle.2.circlepath")
        watch.isEnabled = !busy
        watch.state = status.watchOn ? .on : .off
        watch.toolTip = status.watchOn
            ? "只在本次生效：下次启动隧道会再开。想彻底关掉，在 .env 里写 WATCHDOG=off"
            : "隧道掉线时自动重连（代理没了只拉代理，SSH 断了只重建隧道），随隧道启停"
        menu.addItem(watch)

        menu.addItem(.separator())

        // ---- 排查用 ----
        menu.addItem(action("打开代理日志", #selector(openProxyLog), symbol: "doc.text"))
        menu.addItem(action("打开隧道日志", #selector(openTunnelLog), symbol: "doc.text"))
        menu.addItem(action("打开看门狗日志", #selector(openWatchLog), symbol: "doc.text"))
        menu.addItem(action("打开项目目录", #selector(openProjectDir), symbol: "folder"))
        menu.addItem(action("复制代理地址", #selector(copyProxyAddr), symbol: "doc.on.doc"))

        menu.addItem(.separator())

        menu.addItem(action("退出 TunnelBar（隧道继续运行）", #selector(quit), symbol: "power", key: "q"))
    }

    private func addStatusRow(to menu: NSMenu, key: String, value: @escaping () -> String) {
        let row = label(key, value())
        menu.addItem(row)
        statusRows.append((row, key, value))
    }

    private var hostLine: String {
        status.host.isEmpty ? "(未配置)" : "\(status.host)  →  远端 \(status.remotePort)"
    }

    /// 菜单开着时状态变了，就地改文字，不用重开菜单
    private func syncStatusRows() {
        for (i, row) in statusRows.enumerated() {
            if i == 0 {
                row.item.image = dotImage(status.state.color)
                style(row.item, status.headline, color: status.state.color, bold: true)
            } else {
                row.item.attributedTitle = label(row.key, row.value()).attributedTitle
            }
        }
    }

    // ---- 菜单项小工具 ----

    private func style(_ item: NSMenuItem, _ title: String, color: NSColor, bold: Bool) {
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.menuFont(ofSize: 12),
            .foregroundColor: color,
        ])
        item.isEnabled = true            // action 为 nil，点了也不会做事
        item.target = nil
    }

    /// 灰色只读信息行
    private func label(_ key: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(
            string: key.padding(toLength: max(key.count, 8), withPad: " ", startingAt: 0),
            attributes: [.font: NSFont.menuFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]))
        item.attributedTitle = text
        item.isEnabled = true
        item.target = nil
        return item
    }

    private func action(_ title: String, _ selector: Selector, symbol: String, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            item.image = img
        }
        return item
    }

    // MARK: - 动作

    private func perform(_ command: String, then finish: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        schedulePoll(0.7)          // 启停期间加密轮询，圆点很快跟上真实状态
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.runDaemon(command)
            DispatchQueue.main.async {
                self.busy = false
                self.schedulePoll(3.0)
                self.refresh()      // 立刻拉一次真实状态：失败会变成红色闪烁
                finish?()
            }
        }
    }

    @objc private func startTunnel()   { perform("start") }
    @objc private func stopTunnel()    { perform("stop") }
    @objc private func restartTunnel() { perform("restart") }

    /// 开启/关闭看门狗。开启时顺手把隧道拉到 running（看门狗第一轮就会去修）。
    @objc private func toggleWatchdog() {
        if status.watchOn {
            perform("watchdog stop")
        } else {
            perform("watchdog start")
        }
    }

    @objc private func openProxyLog()  { openLog(".run/proxy.log") }
    @objc private func openTunnelLog() { openLog(".run/tunnel.log") }
    @objc private func openWatchLog()  { openLog(".run/watchdog.log") }

    private func openLog(_ relative: String) {
        let path = projectDir + "/" + relative
        guard FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: console.path) {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                    withApplicationAt: console,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func openProjectDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: projectDir))
    }

    @objc private func copyProxyAddr() {
        let text = status.proxyAddr.isEmpty ? "127.0.0.1:1080" : status.proxyAddr
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        // 只退前端，隧道照常跑
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标，纯菜单栏
app.run()
