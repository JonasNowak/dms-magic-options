import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
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

    // --- Settings (persisted through pluginData) ---
    property string rightClick: "twoFinger"
    property string twoFingerSwipe: "backForward"
    property string threeFingerSwipe: "workspace"
    property string fourFingerSwipeUp: "overview"
    property bool enableGestures: true
    property bool tapToClick: false
    property int scrollSpeed: 100
    property bool showBatteryText: false

    // --- Device status (written by the daemon) ---
    property var status: null
    readonly property bool connected: status !== null && status.connected === true
    readonly property int battery: status !== null && status.battery !== null && status.battery !== undefined
        ? status.battery : -1
    readonly property color batteryColor: battery > 50 ? Theme.primary
        : battery > 20 ? Theme.warning
        : Theme.error

    property bool showMore: false

    function savedSetting(key, fallback) {
        try {
            if (pluginService && pluginService.loadPluginData) {
                var value = pluginService.loadPluginData("magicOptions", key, fallback)
                return value === undefined || value === null ? fallback : value
            }
        } catch (e) {}
        return pluginData && pluginData[key] !== undefined && pluginData[key] !== null
            ? pluginData[key] : fallback
    }

    function saveSetting(key, value) {
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData("magicOptions", key, value)
    }

    function loadSettings() {
        rightClick = savedSetting("rightClick", "twoFinger")
        twoFingerSwipe = savedSetting("twoFingerSwipe", "backForward")
        threeFingerSwipe = savedSetting("threeFingerSwipe", "workspace")
        fourFingerSwipeUp = savedSetting("fourFingerSwipeUp", "overview")
        enableGestures = savedSetting("enableGestures", true)
        tapToClick = savedSetting("tapToClick", false)
        scrollSpeed = Number(savedSetting("scrollSpeed", 100)) || 100
        showBatteryText = savedSetting("showBatteryText", false)
    }

    function loadStatus() {
        try {
            var s = pluginService.loadPluginState("magicOptions", "status", null)
            if (s) root.status = s
        } catch (e) {}
    }

    Component.onCompleted: {
        root.loadSettings()
        root.loadStatus()
    }

    // Re-read the daemon's shared state periodically; onPluginStateChanged
    // only fires when the state actually changes.
    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.loadStatus()
    }

    Connections {
        target: root
        function onPluginDataChanged() {
            if (root.pluginData && Object.keys(root.pluginData).length > 0)
                Qt.callLater(root.loadSettings)
        }
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "magicOptions")
                Qt.callLater(root.loadSettings)
        }
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === "magicOptions")
                root.loadStatus()
        }
    }

    // --- Shared visual: Magic Mouse inside a battery ring ---
    component MouseBatteryIcon: Item {
        id: icon
        required property real iconSize
        property int battery: root.battery
        property bool connected: root.connected

        width: iconSize
        height: iconSize

        Canvas {
            id: ring
            anchors.fill: parent
            property real ringWidth: icon.iconSize >= 48 ? Math.max(3, icon.iconSize * 0.055) : 2
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2, cy = height / 2
                var r = Math.min(width, height) / 2 - ringWidth / 2
                if (r <= 0) return
                ctx.lineWidth = ringWidth
                ctx.lineCap = "round"
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.strokeStyle = Theme.outlineVariant
                ctx.globalAlpha = icon.connected ? 1 : 0.4
                ctx.stroke()
                if (icon.connected && icon.battery >= 0) {
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0, Math.min(100, icon.battery)) / 100)
                    ctx.strokeStyle = root.batteryColor
                    ctx.globalAlpha = 1
                    ctx.stroke()
                }
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            Connections {
                target: icon
                function onBatteryChanged() { ring.requestPaint() }
                function onConnectedChanged() { ring.requestPaint() }
            }
        }

        Image {
            anchors.centerIn: parent
            width: Math.round(icon.iconSize * 0.74)
            height: width
            source: root.pluginDir + (icon.iconSize >= 48 ? "assets/magic-mouse.svg" : "assets/magic-mouse-icon.svg")
            fillMode: Image.PreserveAspectFit
            opacity: icon.connected ? 1 : 0.4
            smooth: true
            sourceSize.width: Math.max(width * 2, 48)
            sourceSize.height: Math.max(height * 2, 48)
        }
    }

    component QuickToggle: Row {
        id: qt
        required property string label
        required property bool checked
        signal toggled(bool on)
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            width: parent.width - toggle.width - parent.spacing
            text: qt.label
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
        }
        DToggle {
            id: toggle
            anchors.verticalCenter: parent.verticalCenter
            checked: qt.checked
            onToggled: isChecked => qt.toggled(isChecked)
        }
    }

    // --- Bar pills ---
    horizontalBarPill: Component {
        Item {
            implicitWidth: mouseIcon.width
            implicitHeight: mouseIcon.height
            MouseBatteryIcon {
                id: mouseIcon
                iconSize: Math.max(20, Math.min(root.widgetThickness - 4, root.iconSizeLarge + 2))
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: mouseIconV.width
            implicitHeight: mouseIconV.height
            MouseBatteryIcon {
                id: mouseIconV
                iconSize: Math.max(20, Math.min(root.widgetThickness - 4, root.iconSizeLarge + 2))
            }
        }
    }

    // --- Popout ---
    popoutWidth: 340
    popoutHeight: root.showMore ? 610 : 440
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Magic Mouse"
            showCloseButton: true
            closePopout: function () { popout.visible = false }

            Column {
                width: parent.width - Theme.spacingM * 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingM

                MouseBatteryIcon {
                    iconSize: 120
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    visible: root.connected && root.showBatteryText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.battery >= 0
                        ? "Battery " + root.battery + "%"
                        : "Battery unknown"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    visible: !root.connected
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "No Magic Mouse connected"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    visible: root.connected && root.status && root.status.hidrawWritable === false
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "hidraw not writable - add a udev rule (see README) or HID settings fall back to pkexec"
                    color: Theme.warning
                    font.pixelSize: Theme.fontSizeSmall
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    QuickToggle {
                        label: "Two-finger right click"
                        checked: root.rightClick === "twoFinger" || root.rightClick === "twoFingerTap"
                        onToggled: on => { root.rightClick = on ? "twoFinger" : "off"; root.saveSetting("rightClick", root.rightClick) }
                    }
                    QuickToggle {
                        label: "3-finger swipe switches workspace"
                        checked: root.threeFingerSwipe === "workspace"
                        onToggled: on => { root.threeFingerSwipe = on ? "workspace" : "off"; root.saveSetting("threeFingerSwipe", root.threeFingerSwipe) }
                    }
                    QuickToggle {
                        label: "4-finger swipe up opens overview"
                        checked: root.fourFingerSwipeUp === "overview"
                        onToggled: on => { root.fourFingerSwipeUp = on ? "overview" : "off"; root.saveSetting("fourFingerSwipeUp", root.fourFingerSwipeUp) }
                    }
                }

                Column {
                    visible: root.showMore
                    width: parent.width
                    spacing: Theme.spacingS

                    QuickToggle {
                        label: "2-finger swipe = back/forward"
                        checked: root.twoFingerSwipe === "backForward"
                        onToggled: on => { root.twoFingerSwipe = on ? "backForward" : "off"; root.saveSetting("twoFingerSwipe", root.twoFingerSwipe) }
                    }
                    QuickToggle {
                        label: "Enable gestures"
                        checked: root.enableGestures
                        onToggled: on => { root.enableGestures = on; root.saveSetting("enableGestures", on) }
                    }
                    QuickToggle {
                        label: "Tap to click"
                        checked: root.tapToClick
                        onToggled: on => { root.tapToClick = on; root.saveSetting("tapToClick", on) }
                    }
                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        Row {
                            width: parent.width
                            StyledText {
                                width: parent.width - popoutSpeedText.width
                                text: "Scroll speed"
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                id: popoutSpeedText
                                text: (popoutSpeedSlider ? popoutSpeedSlider.value : root.scrollSpeed) + "%"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        DSlider {
                            id: popoutSpeedSlider
                            width: parent.width
                            minimum: 25
                            maximum: 300
                            step: 5
                            value: root.scrollSpeed
                            unit: "%"
                            wheelEnabled: false
                            upDownKeysStep: false
                            onSliderDragFinished: finalValue => {
                                root.scrollSpeed = finalValue
                                root.saveSetting("scrollSpeed", finalValue)
                            }
                            Connections {
                                target: root
                                function onScrollSpeedChanged() {
                                    if (!popoutSpeedSlider.isDragging)
                                        popoutSpeedSlider.value = root.scrollSpeed
                                }
                            }
                        }
                    }
                    QuickToggle {
                        label: "Show battery percentage"
                        checked: root.showBatteryText
                        onToggled: on => { root.showBatteryText = on; root.saveSetting("showBatteryText", on) }
                    }
                }

                Row {
                    width: parent.width
                    layoutDirection: Qt.RightToLeft

                    Rectangle {
                        width: Theme.iconSize + Theme.spacingXS
                        height: width
                        radius: Theme.cornerRadius
                        color: gearArea.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHigh
                        border.color: Theme.outlineVariant
                        border.width: 1

                        DIcon {
                            anchors.centerIn: parent
                            name: "settings"
                            size: Theme.iconSizeSmall
                            color: root.showMore ? Theme.primary : Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: gearArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showMore = !root.showMore
                        }
                    }
                }
            }
        }
    }
}
