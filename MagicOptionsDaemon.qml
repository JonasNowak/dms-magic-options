import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "magicOptions"

    property string pluginDir: {
        var url = Qt.resolvedUrl(".")
        var path = url.toString()
        if (path.indexOf("file://") === 0) path = path.substring(7)
        return path
    }

    // Last status JSON from mouse-config.sh, shared with the widget via plugin state.
    property var status: null

    // Settings passed to mouse-config.sh as environment variables, never as arguments.
    readonly property var envMap: ({
        rightClick: "MAGIC_RIGHT_CLICK",
        twoFingerSwipe: "MAGIC_TWO_FINGER_SWIPE",
        threeFingerSwipe: "MAGIC_THREE_FINGER",
        fourFingerSwipeUp: "MAGIC_FOUR_FINGER",
        enableGestures: "MAGIC_GESTURES",
        tapToClick: "MAGIC_TAP_TO_CLICK",
        scrollSpeed: "MAGIC_SCROLL_SPEED"
    })

    readonly property var defaults: ({
        rightClick: "twoFinger",
        twoFingerSwipe: "backForward",
        threeFingerSwipe: "workspace",
        fourFingerSwipeUp: "overview",
        enableGestures: true,
        tapToClick: false,
        scrollSpeed: 100
    })

    property bool pendingApply: false

    function setting(key) {
        var v = pluginData ? pluginData[key] : undefined
        return v === undefined || v === null ? defaults[key] : v
    }

    function applyEnvironment() {
        var env = {}
        for (var key in envMap) {
            var v = setting(key)
            if (key === "enableGestures" || key === "tapToClick")
                env[envMap[key]] = v === true ? "1" : "0"
            else
                env[envMap[key]] = String(v)
        }
        return env
    }

    Timer {
        id: pollTimer
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: root.refreshStatus()
    }

    Process {
        id: statusProcess
        command: ["sh", root.pluginDir + "mouse-config.sh", "status"]
        stdout: SplitParser {
            onRead: line => {
                var t = line.trim()
                if (t.length === 0) return
                try {
                    root.status = JSON.parse(t)
                    // polledAt changes every poll so identical readings still
                    // emit a state change and the widget gets notified.
                    root.status.polledAt = Date.now()
                    pluginService.savePluginState("magicOptions", "status", root.status)
                } catch (e) {}
            }
        }
        stderr: SplitParser { onRead: line => {} }
    }

    Timer {
        id: applyDebounce
        interval: 150
        repeat: false
        onTriggered: root.runApply()
    }

    Process {
        id: applyProcess
        command: ["sh", root.pluginDir + "mouse-config.sh", "apply"]
        environment: root.applyEnvironment()
        stdout: SplitParser { onRead: line => {} }
        stderr: SplitParser { onRead: line => {} }
        onExited: {
            if (root.pendingApply) {
                root.pendingApply = false
                applyDebounce.restart()
            }
        }
    }

    function refreshStatus() {
        if (!statusProcess.running)
            statusProcess.running = true
    }

    function runApply() {
        if (!applyProcess.running) {
            root.pendingApply = false
            applyProcess.running = true
        } else {
            root.pendingApply = true
        }
    }

    function applySettings() {
        if (applyProcess.running)
            root.pendingApply = true
        applyDebounce.restart()
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "magicOptions")
                Qt.callLater(root.applySettings)
        }
    }

    // PluginComponent injects pluginData after child completion; apply once it
    // arrives and again on every later change (widget/settings saves land here).
    Connections {
        target: root
        function onPluginDataChanged() {
            if (root.pluginData && Object.keys(root.pluginData).length > 0)
                Qt.callLater(root.applySettings)
        }
    }

    Component.onCompleted: {
        try {
            var s = pluginService.loadPluginState("magicOptions", "status", null)
            if (s) root.status = s
        } catch (e) {}
        Qt.callLater(function () {
            root.refreshStatus()
            root.applySettings()
        })
    }
}
