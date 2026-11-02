import Cocoa
import Foundation

struct DiskInfo: Codable {
    var uuid: String?
    var connected: Bool
    var mounted: Bool
    var mount_point: String
    var volume_name: String
    var device_id: String?
    var whole_disk: String?
    var physical_disk: String?
    var used_gb: Double
    var free_gb: Double
    var total_gb: Double
}

struct SyncState: Codable {
    var mode: String
    var road_lock: Bool
    var road_activated_at: String?
    var last_sync_at: String?
    var last_sync_result: String?
    var sync_running: Bool
    var sync_pid: Int?
    var sync_direction: String?
    var sync_phase: String
    var sync_gb_session: Double
    var sync_gb_batch: Double
    var sync_speed: String
    var sync_percent: String
    var cooldown_remaining: Int
    var last_error: String?
}

struct FullStatus: Codable {
    var effective_mode: String
    var ssd: DiskInfo
    var sd: DiskInfo
    var state: SyncState
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var modeHeaderItem: NSMenuItem!
    var ssdInfoItem: NSMenuItem!
    var sdInfoItem: NSMenuItem!
    var syncPhaseItem: NSMenuItem!
    var lastSyncItem: NSMenuItem!
    var scheduleSummaryItem: NSMenuItem!

    var switchToRoadSyncItem: NSMenuItem!
    var switchToRoadQuickItem: NSMenuItem!
    var switchToDeskItem: NSMenuItem!
    var syncNowItem: NSMenuItem!
    var stopSyncItem: NSMenuItem!

    var settingsWindow: NSWindow?
    var ssdVolumePopup: NSPopUpButton!
    var sdVolumePopup: NSPopUpButton!
    var availableVolumes: [[String: Any]] = []
    var scheduleEnabledCheck: NSButton!
    var dayChecks: [Int: NSButton] = [:]
    var hourPopup: NSPopUpButton!
    var minutePopup: NSPopUpButton!
    var cooldownEnabledCheck: NSButton!
    var cooldownGbPopup: NSPopUpButton!
    var cooldownSecPopup: NSPopUpButton!
    var bwlimitPopup: NSPopUpButton!

    var refreshTimer: Timer?
    var isBusySwitching = false
    var iconCache: [String: NSImage] = [:]

    let appDir = NSHomeDirectory() + "/.disk-twin"
    var scriptPath: String { return appDir + "/disk_twin.py" }
    var configPath: String { return appDir + "/config.json" }
    var statePath: String { return appDir + "/state.json" }
    var logPath: String { return appDir + "/sync.log" }

    var lastStatus: FullStatus?

    func templateIcon(_ name: String, size: CGFloat = 15) -> NSImage? {
        let key = "\(name)_\(Int(size))"
        if let cached = iconCache[key] {
            return cached
        }
        let candidates = [
            (Bundle.main.resourcePath ?? "") + "/icons/\(name).svg",
            appDir + "/icons/\(name).svg",
            "/Volumes/Main 1TB/AI/DiskTwin/icons/\(name).svg"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: size, height: size)
                img.isTemplate = true
                iconCache[key] = img
                return img
            }
        }
        return nil
    }

    func bootstrapEnvironmentIfNeeded() {
        let fm = FileManager.default
        let iconsDst = appDir + "/icons"
        try? fm.createDirectory(atPath: iconsDst, withIntermediateDirectories: true)

        if let resPath = Bundle.main.resourcePath {
            let bundledScript = resPath + "/disk_twin.py"
            if fm.fileExists(atPath: bundledScript) {
                if !fm.fileExists(atPath: scriptPath) {
                    try? fm.copyItem(atPath: bundledScript, toPath: scriptPath)
                } else if let srcData = try? Data(contentsOf: URL(fileURLWithPath: bundledScript)),
                          let dstData = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)),
                          srcData != dstData {
                    try? srcData.write(to: URL(fileURLWithPath: scriptPath))
                }
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            }

            let bundledIcons = resPath + "/icons"
            if let files = try? fm.contentsOfDirectory(atPath: bundledIcons) {
                for file in files where file.hasSuffix(".svg") {
                    let s = bundledIcons + "/" + file
                    let d = iconsDst + "/" + file
                    if !fm.fileExists(atPath: d) {
                        try? fm.copyItem(atPath: s, toPath: d)
                    }
                }
            }
        }

        // Ensure LaunchAgent for Menu Bar auto-start at login exists
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        let menubarPlist = launchAgentsDir + "/com.antigravity.disktwin.menubar.plist"
        if !fm.fileExists(atPath: menubarPlist) {
            let execPath = Bundle.main.executablePath ?? "/Applications/DiskTwin.app/Contents/MacOS/DiskTwin"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.antigravity.disktwin.menubar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? plistContent.write(toFile: menubarPlist, atomically: true, encoding: .utf8)
        }

        // First-run initialization of config.json, state.json, excludes.txt, and scheduled LaunchAgent
        let schedPlist = launchAgentsDir + "/com.antigravity.disktwin.plist"
        if !fm.fileExists(atPath: configPath) || !fm.fileExists(atPath: schedPlist) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [self.scriptPath, "update-schedule"]
                try? proc.run()
                proc.waitUntilExit()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        bootstrapEnvironmentIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = templateIcon("computer-desktop", size: 16)
            btn.imagePosition = .imageLeading
            btn.title = " Desk"
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        buildMenu()
        statusItem.menu = menu

        refreshStatusAsync()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshStatusAsync()
        }
    }

    func buildMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        modeHeaderItem = NSMenuItem(title: "Mode: Checking...", action: nil, keyEquivalent: "")
        modeHeaderItem.image = templateIcon("computer-desktop")
        modeHeaderItem.isEnabled = false
        menu.addItem(modeHeaderItem)

        ssdInfoItem = NSMenuItem(title: "SSD: Checking...", action: nil, keyEquivalent: "")
        ssdInfoItem.image = templateIcon("hard-drive")
        ssdInfoItem.isEnabled = false
        menu.addItem(ssdInfoItem)

        sdInfoItem = NSMenuItem(title: "MicroSD: Checking...", action: nil, keyEquivalent: "")
        sdInfoItem.image = templateIcon("memory-stick")
        sdInfoItem.isEnabled = false
        menu.addItem(sdInfoItem)

        menu.addItem(NSMenuItem.separator())

        syncPhaseItem = NSMenuItem(title: "Sync Status: Idle", action: nil, keyEquivalent: "")
        syncPhaseItem.image = templateIcon("circle-check")
        syncPhaseItem.isEnabled = false
        menu.addItem(syncPhaseItem)

        lastSyncItem = NSMenuItem(title: "Last Sync: Never", action: nil, keyEquivalent: "")
        lastSyncItem.image = templateIcon("clock")
        lastSyncItem.isEnabled = false
        menu.addItem(lastSyncItem)

        scheduleSummaryItem = NSMenuItem(title: "Schedule: Loading...", action: nil, keyEquivalent: "")
        scheduleSummaryItem.image = templateIcon("calendar-clock")
        scheduleSummaryItem.isEnabled = false
        menu.addItem(scheduleSummaryItem)

        menu.addItem(NSMenuItem.separator())

        // Mode Switching
        switchToRoadSyncItem = NSMenuItem(
            title: "Switch to Road Mode (Sync & Eject SSD)",
            action: #selector(handleSwitchToRoadWithSync),
            keyEquivalent: "r"
        )
        switchToRoadSyncItem.image = templateIcon("hard-drive-download")
        switchToRoadSyncItem.target = self
        menu.addItem(switchToRoadSyncItem)

        switchToRoadQuickItem = NSMenuItem(
            title: "Quick Switch to Road Mode (Skip Sync)",
            action: #selector(handleSwitchToRoadQuick),
            keyEquivalent: ""
        )
        switchToRoadQuickItem.image = templateIcon("compass")
        switchToRoadQuickItem.target = self
        menu.addItem(switchToRoadQuickItem)

        switchToDeskItem = NSMenuItem(
            title: "Switch to Desk Mode...",
            action: #selector(handleSwitchToDesk),
            keyEquivalent: "d"
        )
        switchToDeskItem.image = templateIcon("computer-desktop")
        switchToDeskItem.target = self
        menu.addItem(switchToDeskItem)

        menu.addItem(NSMenuItem.separator())

        // Manual Sync Controls
        syncNowItem = NSMenuItem(
            title: "Sync Now (Main 1TB → MicroSD 1TB)",
            action: #selector(handleSyncNow),
            keyEquivalent: "s"
        )
        syncNowItem.image = templateIcon("backup-restore")
        syncNowItem.target = self
        menu.addItem(syncNowItem)

        stopSyncItem = NSMenuItem(
            title: "Stop Running Sync",
            action: #selector(handleStopSync),
            keyEquivalent: "."
        )
        stopSyncItem.image = templateIcon("ban")
        stopSyncItem.target = self
        stopSyncItem.isEnabled = false
        menu.addItem(stopSyncItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Schedule & Thermal Cool-Down Settings...",
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.image = templateIcon("cog")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(
            title: "Open Sync Log",
            action: #selector(openSyncLog),
            keyEquivalent: "l"
        )
        logItem.image = templateIcon("file-document")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit DiskTwin Toolbar",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.image = templateIcon("close-circle")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func refreshStatusAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [self.scriptPath, "status", "--json"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let decoder = JSONDecoder()
                let status = try decoder.decode(FullStatus.self, from: data)
                let cfgDict = self.readConfigDict()
                DispatchQueue.main.async {
                    self.lastStatus = status
                    self.updateUI(with: status, config: cfgDict)
                }
            } catch {
                // Ignore transient parse errors
            }
        }
    }

    func readConfigDict() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    func updateUI(with st: FullStatus, config: [String: Any]) {
        let s = st.state
        let ssd = st.ssd
        let sd = st.sd

        // Top Menu Bar Icon & Title (Monochromatic Template Icons per macOS HIG)
        if let btn = statusItem.button {
            btn.imagePosition = .imageLeading
            if isBusySwitching {
                btn.image = templateIcon("loader", size: 16)
                btn.title = " Switching..."
            } else if s.sync_running {
                if s.cooldown_remaining > 0 {
                    btn.image = templateIcon("hourglass", size: 16)
                    btn.title = " Cool \(s.cooldown_remaining)s"
                } else {
                    btn.image = templateIcon("backup-restore", size: 16)
                    let pct = s.sync_percent.isEmpty ? "" : " \(s.sync_percent)"
                    btn.title = "\(pct) (\(String(format: "%.1f", s.sync_gb_session))G)"
                }
            } else if st.effective_mode == "road" {
                btn.image = templateIcon("compass", size: 16)
                btn.title = " Road"
            } else if st.effective_mode == "both_connected_road_named" {
                btn.image = templateIcon("triangle-alert", size: 16)
                btn.title = " Plugged (Road)"
            } else if st.effective_mode == "ssd_unplugged_ready_for_road" {
                btn.image = templateIcon("compass", size: 16)
                btn.title = " Unplugged"
            } else {
                btn.image = templateIcon("computer-desktop", size: 16)
                btn.title = " Desk"
            }
        }

        // Dropdown header lines
        switch st.effective_mode {
        case "road":
            modeHeaderItem.image = templateIcon("compass")
            modeHeaderItem.title = "Mode: ROAD MODE (MicroSD is /Volumes/Main 1TB)"
        case "both_connected_road_named":
            modeHeaderItem.image = templateIcon("triangle-alert")
            modeHeaderItem.title = "Mode: SSD Reconnected — Click 'Switch to Desk Mode'"
        case "ssd_unplugged_ready_for_road":
            modeHeaderItem.image = templateIcon("triangle-alert")
            modeHeaderItem.title = "SSD Unplugged — Click 'Quick Switch to Road Mode'"
        default:
            modeHeaderItem.image = templateIcon("computer-desktop")
            let lockSuffix = s.road_lock ? " (Road Lock Active)" : ""
            modeHeaderItem.title = "Mode: DESK MODE\(lockSuffix)"
        }

        if ssd.mounted {
            ssdInfoItem.title = "External SSD: \(ssd.mount_point) (\(String(format: "%.1f", ssd.used_gb)) / \(String(format: "%.0f", ssd.total_gb)) GB)"
        } else if ssd.connected {
            ssdInfoItem.title = "External SSD: Connected (Unmounted)"
        } else {
            ssdInfoItem.title = "External SSD: Unplugged"
        }

        if sd.mounted {
            sdInfoItem.title = "MicroSD 1TB: \(sd.mount_point) (\(String(format: "%.1f", sd.used_gb)) / \(String(format: "%.0f", sd.total_gb)) GB)"
        } else if sd.connected {
            sdInfoItem.title = "MicroSD 1TB: Connected (Unmounted)"
        } else {
            sdInfoItem.title = "MicroSD 1TB: Not Detected"
        }

        if s.sync_running {
            syncPhaseItem.image = s.cooldown_remaining > 0 ? templateIcon("hourglass") : templateIcon("loader")
            let cleanPhase = s.sync_phase.replacingOccurrences(of: "❄️ ", with: "")
            let spd = s.sync_speed.isEmpty ? "" : " • \(s.sync_speed)"
            syncPhaseItem.title = "\(cleanPhase)\(spd)"
        } else {
            syncPhaseItem.image = templateIcon("circle-check")
            syncPhaseItem.title = "Sync Status: Idle"
        }

        let lastTime = s.last_sync_at ?? "Never"
        let lastRes = s.last_sync_result ?? ""
        lastSyncItem.title = "Last Sync: \(lastTime) — \(lastRes)"

        // Schedule & Thermal Summary
        let schedEnabled = (config["schedule_enabled"] as? Bool) ?? true
        let days = (config["schedule_days"] as? [Int]) ?? [3, 7]
        let hr = (config["schedule_hour"] as? Int) ?? 14
        let mn = (config["schedule_minute"] as? Int) ?? 0
        let coolEnabled = (config["cooldown_enabled"] as? Bool) ?? true
        let coolGb = (config["cooldown_every_gb"] as? Int) ?? 35
        let coolSec = (config["cooldown_seconds"] as? Int) ?? 60
        let bw = (config["bwlimit_mbps"] as? Int) ?? 0

        let dayMap = [1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat", 7: "Sun"]
        let dayNames = days.sorted().compactMap { dayMap[$0] }.joined(separator: ", ")
        let schedStr = schedEnabled ? "\(dayNames) @ \(String(format: "%02d:%02d", hr, mn))" : "Disabled"
        let bwStr = bw > 0 ? "\(bw)MB/s" : "Max Speed"
        let coolStr = coolEnabled ? "Cool \(coolSec)s/\(coolGb)GB • \(bwStr)" : "No Cooldown • \(bwStr)"
        scheduleSummaryItem.title = "Auto: \(schedStr) • \(coolStr)"

        // Enable/Disable Buttons
        let canAct = !s.sync_running && !isBusySwitching
        switchToRoadSyncItem.isEnabled = canAct && ssd.mounted && sd.connected && st.effective_mode != "road"
        switchToRoadQuickItem.isEnabled = canAct && sd.connected && st.effective_mode != "road"
        switchToDeskItem.isEnabled = canAct && ssd.connected && sd.connected && (st.effective_mode != "desk" || s.road_lock)
        syncNowItem.isEnabled = canAct && ssd.mounted && sd.mounted && st.effective_mode == "desk"
        stopSyncItem.isEnabled = s.sync_running
    }

    @objc func handleSwitchToRoadWithSync() {
        runCommandWithAlert(args: ["to-road", "--sync-first"], statusLabel: "Syncing & Switching to Road...")
    }

    @objc func handleSwitchToRoadQuick() {
        runCommandWithAlert(args: ["to-road"], statusLabel: "Switching to Road Mode...")
    }

    @objc func handleSwitchToDesk() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Switch back to Desk Mode"
        alert.informativeText = "Your External SSD ('Main 1TB') is connected.\n\nDid you create or modify files on the MicroSD while on the road that need to be copied back to your Main 1TB SSD first?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sync Road Changes → Main SSD, then Switch")
        alert.addButton(withTitle: "Switch Directly (No Road Changes to Copy)")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            runCommandWithAlert(args: ["to-desk", "--sync-back"], statusLabel: "Syncing Road Changes & Switching...")
        } else if resp == .alertSecondButtonReturn {
            runCommandWithAlert(args: ["to-desk"], statusLabel: "Switching to Desk Mode...")
        }
    }

    @objc func handleSyncNow() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [self.scriptPath, "sync"]
            try? proc.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.refreshStatusAsync()
            }
        }
    }

    @objc func handleStopSync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [self.scriptPath, "stop-sync"]
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self.refreshStatusAsync()
            }
        }
    }

    func runCommandWithAlert(args: [String], statusLabel: String) {
        isBusySwitching = true
        if let btn = statusItem.button {
            btn.image = templateIcon("loader", size: 16)
            btn.title = " Switching..."
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [self.scriptPath] + args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var ok = (proc.terminationStatus == 0)
            var msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (jsonObj["ok"] as? Bool) ?? ok
                msg = (jsonObj["message"] as? String) ?? msg
            }

            DispatchQueue.main.async {
                self.isBusySwitching = false
                self.refreshStatusAsync()
                if !ok {
                    NSApp.activate(ignoringOtherApps: true)
                    let errAlert = NSAlert()
                    errAlert.alertStyle = .warning
                    errAlert.messageText = "DiskTwin Action Notice"
                    errAlert.informativeText = msg
                    errAlert.runModal()
                }
            }
        }
    }

    func fetchAvailableVolumes() -> [[String: Any]] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [scriptPath, "list-volumes"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return arr
            }
        } catch {}
        return []
    }

    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            loadConfigIntoSettingsUI()
            win.makeKeyAndOrderFront(nil)
            return
        }

        let rect = NSRect(x: 0, y: 0, width: 490, height: 500)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "DiskTwin — Drives, Schedule & Thermal Protection"
        win.center()
        win.isReleasedWhenClosed = false

        let content = NSView(frame: rect)
        win.contentView = content

        var y = 452

        // Section 0: Hardware Drive Pairing (UUID-Bound)
        let driveTitle = NSTextField(labelWithString: "1. Paired Volumes (Tracked by Hardware UUID)")
        driveTitle.font = NSFont.boldSystemFont(ofSize: 13)
        driveTitle.frame = NSRect(x: 24, y: y, width: 440, height: 20)
        content.addSubview(driveTitle)
        y -= 32

        let ssdLabel = NSTextField(labelWithString: "Primary External SSD:")
        ssdLabel.frame = NSRect(x: 24, y: y, width: 155, height: 20)
        content.addSubview(ssdLabel)

        ssdVolumePopup = NSPopUpButton(frame: NSRect(x: 185, y: y - 3, width: 280, height: 26), pullsDown: false)
        content.addSubview(ssdVolumePopup)
        y -= 32

        let sdLabel = NSTextField(labelWithString: "Internal MicroSD / Mirror:")
        sdLabel.frame = NSRect(x: 24, y: y, width: 155, height: 20)
        content.addSubview(sdLabel)

        sdVolumePopup = NSPopUpButton(frame: NSRect(x: 185, y: y - 3, width: 280, height: 26), pullsDown: false)
        content.addSubview(sdVolumePopup)

        y -= 20
        let sep0 = NSBox(frame: NSRect(x: 24, y: y, width: 442, height: 1))
        sep0.boxType = .separator
        content.addSubview(sep0)
        y -= 26

        // Section 1: Automatic Schedule
        let schedTitle = NSTextField(labelWithString: "2. Automatic Background Sync Schedule")
        schedTitle.font = NSFont.boldSystemFont(ofSize: 13)
        schedTitle.frame = NSRect(x: 24, y: y, width: 430, height: 20)
        content.addSubview(schedTitle)
        y -= 28

        scheduleEnabledCheck = NSButton(checkboxWithTitle: "Enable automatic scheduled sync (only runs in Desk Mode)", target: nil, action: nil)
        scheduleEnabledCheck.frame = NSRect(x: 24, y: y, width: 430, height: 20)
        content.addSubview(scheduleEnabledCheck)
        y -= 32

        let daysLabel = NSTextField(labelWithString: "Days of Week:")
        daysLabel.frame = NSRect(x: 24, y: y, width: 95, height: 20)
        content.addSubview(daysLabel)

        let dayNames: [(Int, String)] = [(1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"), (7, "Sun")]
        var dx = 122
        for (dNum, dLabel) in dayNames {
            let cb = NSButton(checkboxWithTitle: dLabel, target: nil, action: nil)
            cb.frame = NSRect(x: dx, y: y, width: 50, height: 20)
            content.addSubview(cb)
            dayChecks[dNum] = cb
            dx += 48
        }
        y -= 34

        let timeLabel = NSTextField(labelWithString: "Run Time (24h):")
        timeLabel.frame = NSRect(x: 24, y: y, width: 105, height: 20)
        content.addSubview(timeLabel)

        hourPopup = NSPopUpButton(frame: NSRect(x: 130, y: y - 3, width: 75, height: 26), pullsDown: false)
        for h in 0..<24 {
            hourPopup.addItem(withTitle: String(format: "%02d", h))
        }
        content.addSubview(hourPopup)

        let colonLabel = NSTextField(labelWithString: ":")
        colonLabel.font = NSFont.boldSystemFont(ofSize: 13)
        colonLabel.frame = NSRect(x: 210, y: y, width: 12, height: 20)
        content.addSubview(colonLabel)

        minutePopup = NSPopUpButton(frame: NSRect(x: 222, y: y - 3, width: 75, height: 26), pullsDown: false)
        for m in [0, 15, 30, 45] {
            minutePopup.addItem(withTitle: String(format: "%02d", m))
        }
        content.addSubview(minutePopup)

        y -= 22
        let sep = NSBox(frame: NSRect(x: 24, y: y, width: 442, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        y -= 26

        // Section 2: MicroSD Thermal & SLC Cache Protection
        let thermTitle = NSTextField(labelWithString: "3. MicroSD Thermal Cool-Down & Wear Protection")
        thermTitle.font = NSFont.boldSystemFont(ofSize: 13)
        thermTitle.frame = NSRect(x: 24, y: y, width: 430, height: 20)
        content.addSubview(thermTitle)
        y -= 28

        cooldownEnabledCheck = NSButton(checkboxWithTitle: "Pause big copies periodically so MicroSD cools & flushes SLC cache", target: nil, action: nil)
        cooldownEnabledCheck.frame = NSRect(x: 24, y: y, width: 440, height: 20)
        content.addSubview(cooldownEnabledCheck)
        y -= 34

        let everyLabel = NSTextField(labelWithString: "Take a cool-down break every:")
        everyLabel.frame = NSRect(x: 24, y: y, width: 195, height: 20)
        content.addSubview(everyLabel)

        cooldownGbPopup = NSPopUpButton(frame: NSRect(x: 225, y: y - 3, width: 120, height: 26), pullsDown: false)
        for gb in [15, 25, 35, 50, 75, 100] {
            cooldownGbPopup.addItem(withTitle: "\(gb) GB")
            cooldownGbPopup.lastItem?.tag = gb
        }
        content.addSubview(cooldownGbPopup)
        y -= 34

        let durLabel = NSTextField(labelWithString: "Cool-down pause duration:")
        durLabel.frame = NSRect(x: 24, y: y, width: 195, height: 20)
        content.addSubview(durLabel)

        cooldownSecPopup = NSPopUpButton(frame: NSRect(x: 225, y: y - 3, width: 120, height: 26), pullsDown: false)
        for sec in [30, 45, 60, 90, 120] {
            cooldownSecPopup.addItem(withTitle: "\(sec) seconds")
            cooldownSecPopup.lastItem?.tag = sec
        }
        content.addSubview(cooldownSecPopup)
        y -= 34

        let bwLabel = NSTextField(labelWithString: "Sustained write speed cap:")
        bwLabel.frame = NSRect(x: 24, y: y, width: 195, height: 20)
        content.addSubview(bwLabel)

        bwlimitPopup = NSPopUpButton(frame: NSRect(x: 225, y: y - 3, width: 225, height: 26), pullsDown: false)
        let bwOptions: [(Int, String)] = [
            (0, "Unlimited (Full Native Speed)"),
            (110, "110 MB/s (Max UHS-I / DDR200)"),
            (90, "90 MB/s (High Sustained)"),
            (70, "70 MB/s (Balanced Fast)"),
            (50, "50 MB/s (Conservative)")
        ]
        for (mb, title) in bwOptions {
            bwlimitPopup.addItem(withTitle: title)
            bwlimitPopup.lastItem?.tag = mb
        }
        content.addSubview(bwlimitPopup)

        // Save & Cancel Buttons
        let saveBtn = NSButton(title: "Save & Apply", target: self, action: #selector(saveSettingsClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 340, y: 16, width: 116, height: 32)
        content.addSubview(saveBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(closeSettingsClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 240, y: 16, width: 92, height: 32)
        content.addSubview(cancelBtn)

        settingsWindow = win
        loadConfigIntoSettingsUI()
        win.makeKeyAndOrderFront(nil)
    }

    func loadConfigIntoSettingsUI() {
        let cfg = readConfigDict()
        availableVolumes = fetchAvailableVolumes()

        let curSsdUuid = (cfg["ssd_uuid"] as? String) ?? ""
        let curSdUuid = (cfg["sd_uuid"] as? String) ?? ""
        let curSsdName = (cfg["ssd_default_name"] as? String) ?? "Main 1TB"
        let curSdName = (cfg["sd_desk_name"] as? String) ?? "MicroSD 1TB"

        ssdVolumePopup.removeAllItems()
        sdVolumePopup.removeAllItems()

        var foundSsd = false
        var foundSd = false

        for (idx, vol) in availableVolumes.enumerated() {
            let vUuid = (vol["uuid"] as? String) ?? ""
            let vName = (vol["volume_name"] as? String) ?? "Volume"
            let vGb = (vol["total_gb"] as? Double) ?? 0.0
            let vProto = (vol["protocol"] as? String) ?? "Disk"
            let title = "\(vName) (\(String(format: "%.0f", vGb)) GB • \(vProto))"

            ssdVolumePopup.addItem(withTitle: title)
            ssdVolumePopup.lastItem?.tag = idx
            if vUuid == curSsdUuid {
                ssdVolumePopup.selectItem(withTag: idx)
                foundSsd = true
            }

            sdVolumePopup.addItem(withTitle: title)
            sdVolumePopup.lastItem?.tag = idx
            if vUuid == curSdUuid {
                sdVolumePopup.selectItem(withTag: idx)
                foundSd = true
            }
        }

        if !foundSsd && !curSsdUuid.isEmpty {
            ssdVolumePopup.addItem(withTitle: "\(curSsdName) (Offline • \(curSsdUuid.prefix(8)))")
            ssdVolumePopup.lastItem?.tag = -1
            ssdVolumePopup.selectItem(withTag: -1)
        }
        if !foundSd && !curSdUuid.isEmpty {
            sdVolumePopup.addItem(withTitle: "\(curSdName) (Offline • \(curSdUuid.prefix(8)))")
            sdVolumePopup.lastItem?.tag = -1
            sdVolumePopup.selectItem(withTag: -1)
        }

        let schedEnabled = (cfg["schedule_enabled"] as? Bool) ?? true
        scheduleEnabledCheck.state = schedEnabled ? .on : .off

        let days = Set((cfg["schedule_days"] as? [Int]) ?? [3, 7])
        for (dNum, cb) in dayChecks {
            cb.state = days.contains(dNum) ? .on : .off
        }

        let hr = (cfg["schedule_hour"] as? Int) ?? 14
        hourPopup.selectItem(withTitle: String(format: "%02d", hr))

        let mn = (cfg["schedule_minute"] as? Int) ?? 0
        if minutePopup.item(withTitle: String(format: "%02d", mn)) != nil {
            minutePopup.selectItem(withTitle: String(format: "%02d", mn))
        } else {
            minutePopup.selectItem(at: 0)
        }

        let coolEnabled = (cfg["cooldown_enabled"] as? Bool) ?? true
        cooldownEnabledCheck.state = coolEnabled ? .on : .off

        let coolGb = (cfg["cooldown_every_gb"] as? Int) ?? 35
        if !cooldownGbPopup.selectItem(withTag: coolGb) {
            cooldownGbPopup.selectItem(withTag: 35)
        }

        let coolSec = (cfg["cooldown_seconds"] as? Int) ?? 60
        if !cooldownSecPopup.selectItem(withTag: coolSec) {
            cooldownSecPopup.selectItem(withTag: 60)
        }

        let bw = (cfg["bwlimit_mbps"] as? Int) ?? 0
        if !bwlimitPopup.selectItem(withTag: bw) {
            bwlimitPopup.selectItem(withTag: 0)
        }
    }

    @objc func saveSettingsClicked() {
        var cfg = readConfigDict()

        let ssdIdx = ssdVolumePopup.selectedTag()
        if ssdIdx >= 0 && ssdIdx < availableVolumes.count {
            let vol = availableVolumes[ssdIdx]
            if let u = vol["uuid"] as? String, let n = vol["volume_name"] as? String {
                cfg["ssd_uuid"] = u
                cfg["ssd_default_name"] = n
                cfg["sd_road_name"] = n
            }
        }

        let sdIdx = sdVolumePopup.selectedTag()
        if sdIdx >= 0 && sdIdx < availableVolumes.count {
            let vol = availableVolumes[sdIdx]
            if let u = vol["uuid"] as? String, let n = vol["volume_name"] as? String {
                cfg["sd_uuid"] = u
                if n != (cfg["ssd_default_name"] as? String) {
                    cfg["sd_desk_name"] = n
                }
            }
        }

        cfg["schedule_enabled"] = (scheduleEnabledCheck.state == .on)

        var selectedDays: [Int] = []
        for dNum in 1...7 {
            if dayChecks[dNum]?.state == .on {
                selectedDays.append(dNum)
            }
        }
        cfg["schedule_days"] = selectedDays
        cfg["schedule_hour"] = Int(hourPopup.titleOfSelectedItem ?? "14") ?? 14
        cfg["schedule_minute"] = Int(minutePopup.titleOfSelectedItem ?? "0") ?? 0
        cfg["cooldown_enabled"] = (cooldownEnabledCheck.state == .on)
        cfg["cooldown_every_gb"] = cooldownGbPopup.selectedTag()
        cfg["cooldown_seconds"] = cooldownSecPopup.selectedTag()
        cfg["bwlimit_mbps"] = bwlimitPopup.selectedTag()

        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }

        settingsWindow?.orderOut(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [self.scriptPath, "update-schedule"]
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self.refreshStatusAsync()
            }
        }
    }

    @objc func closeSettingsClicked() {
        settingsWindow?.orderOut(nil)
    }

    @objc func openSyncLog() {
        if !FileManager.default.fileExists(atPath: logPath) {
            try? "DiskTwin Sync Log Initialized\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
