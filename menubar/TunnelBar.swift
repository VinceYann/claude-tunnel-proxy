// ============================================================
//  TunnelBar — Claude Tunnel Proxy 菜单栏小前端
//  --------------------------------------------
//  常驻状态栏，圆点颜色表示隧道状态：
//    🟢 绿 = 运行中   🟠 橙 = 部分运行   ⚪ 灰 = 已停止
//  点击圆点弹出菜单：启动 / 停止 / 打开目录 / 退出
// ============================================================

import AppKit

// 项目目录：由 app 自身位置反推，不硬编码绝对路径。
// TunnelBar.app 位于项目根目录下，向上退一级即为项目根，
// 因此整个项目可随意移动，无需重新编译。
let projectDir: String = {
    let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()  // …/TunnelBar.app
    return appURL.deletingLastPathComponent().path                // 项目根
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        statusItem = item
        refreshIcon()

        // 每 5 秒刷新一次状态圆点
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    // ---- 执行 shell（同步，返回 stdout）----
    @discardableResult
    private func runShell(_ args: [String]) -> String {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func currentState() -> String {
        runShell([projectDir + "/tunnel-daemon.sh", "state"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "隧道状态")
        img?.isTemplate = true
        button.image = img
        switch currentState() {
        case "running": button.contentTintColor = .systemGreen
        case "partial": button.contentTintColor = .systemOrange
        default:        button.contentTintColor = .systemGray
        }
        button.toolTip = "Claude Tunnel Proxy"
    }

    // ---- 点击弹出菜单 ----
    @objc private func statusItemClicked(_ sender: Any?) {
        let state = currentState()
        statusItem?.popUpMenu(buildMenu(state: state))
    }

    private func buildMenu(state: String) -> NSMenu {
        let menu = NSMenu()

        let statusTitle: String
        switch state {
        case "running": statusTitle = "状态：运行中 🟢"
        case "partial": statusTitle = "状态：部分运行 🟠"
        default:        statusTitle = "状态：已停止 ⚪"
        }
        menu.addItem(NSMenuItem(title: statusTitle, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let start = NSMenuItem(title: "启动隧道", action: #selector(startTunnel), keyEquivalent: "")
        start.target = self
        start.isEnabled = (state != "running")
        menu.addItem(start)

        let stop = NSMenuItem(title: "停止隧道", action: #selector(stopTunnel), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = (state == "running" || state == "partial")
        menu.addItem(stop)

        menu.addItem(.separator())

        let openDir = NSMenuItem(title: "打开项目目录", action: #selector(openProjectDir), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // ---- 动作（启动/停止放后台线程，避免阻塞 UI）----
    @objc private func startTunnel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runShell([projectDir + "/tunnel-daemon.sh", "start"])
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    @objc private func stopTunnel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runShell([projectDir + "/tunnel-daemon.sh", "stop"])
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    @objc private func openProjectDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: projectDir))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标，纯菜单栏
app.run()
