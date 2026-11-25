import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "magicOptions"

    component SectionCard: StyledRect {
        id: card
        width: parent.width
        height: cardColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer

        required property string title
        property string icon: ""
        default property alias content: cardColumn.data

        function loadValue() {
            for (let i = 0; i < cardColumn.children.length; i++) {
                const child = cardColumn.children[i]
                if (child.loadValue)
                    child.loadValue()
            }
        }

        Column {
            id: cardColumn
            width: parent.width - Theme.spacingL * 2
            anchors.centerIn: parent
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DIcon {
                    name: card.icon
                    size: 18
                    color: Theme.surfaceText
                    visible: card.icon !== ""
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: card.title
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    SectionCard {
        title: I18n.tr("Mouse")
        icon: "mouse"

        SelectionSetting {
            settingKey: "rightClick"
            label: I18n.tr("Right click")
            description: I18n.tr("How right-click is triggered on a Magic Mouse 1.")
            options: [
                { value: "twoFinger", label: I18n.tr("Two-finger click (physical)") },
                { value: "twoFingerTap", label: I18n.tr("Two-finger tap (touch)") },
                { value: "off", label: I18n.tr("Disabled") }
            ]
            defaultValue: "twoFinger"
        }

        Column {
            id: scrollSpeedSetting
            width: parent.width
            spacing: Theme.spacingXS

            property int value: 100

            function loadValue() {
                value = Number(root.loadValue("scrollSpeed", 100)) || 100
                if (!speedSlider.isDragging)
                    speedSlider.value = value
            }

            Component.onCompleted: Qt.callLater(loadValue)

            Row {
                width: parent.width
                StyledText {
                    width: parent.width - speedValueText.width
                    text: I18n.tr("Scroll speed")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Theme.fontWeightMedium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    id: speedValueText
                    text: (speedSlider ? speedSlider.value : scrollSpeedSetting.value) + "%"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: I18n.tr("Multiplier for wheel scrolling speed.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            DSlider {
                id: speedSlider
                width: parent.width
                minimum: 25
                maximum: 300
                step: 5
                value: scrollSpeedSetting.value
                unit: "%"
                wheelEnabled: false
                upDownKeysStep: false
                onSliderDragFinished: finalValue => {
                    scrollSpeedSetting.value = finalValue
                    root.saveValue("scrollSpeed", finalValue)
                }
            }
        }

        SelectionSetting {
            settingKey: "twoFingerSwipe"
            label: I18n.tr("Two-finger swipe")
            description: I18n.tr("Horizontal two-finger swipe goes back/forward, like a trackpad (browsers, apps).")
            options: [
                { value: "backForward", label: I18n.tr("Back / forward") },
                { value: "off", label: I18n.tr("Disabled") }
            ]
            defaultValue: "backForward"
        }

        SelectionSetting {
            settingKey: "threeFingerSwipe"
            label: I18n.tr("Three-finger swipe")
            description: I18n.tr("Horizontal three-finger swipe switches the niri workspace.")
            options: [
                { value: "workspace", label: I18n.tr("Switch workspace") },
                { value: "off", label: I18n.tr("Disabled") }
            ]
            defaultValue: "workspace"
        }

        SelectionSetting {
            settingKey: "fourFingerSwipeUp"
            label: I18n.tr("Four-finger swipe up")
            description: I18n.tr("Four-finger swipe up opens the niri overview.")
            options: [
                { value: "overview", label: I18n.tr("Open overview") },
                { value: "off", label: I18n.tr("Disabled") }
            ]
            defaultValue: "overview"
        }
    }

    SectionCard {
        title: I18n.tr("Behavior")
        icon: "touch_app"

        ToggleSetting {
            settingKey: "enableGestures"
            label: I18n.tr("Enable gestures")
            description: I18n.tr("Run the gesture bridge that maps multi-finger swipes to niri actions.")
            defaultValue: true
        }

        ToggleSetting {
            settingKey: "tapToClick"
            label: I18n.tr("Tap to click")
            description: I18n.tr("Tap lightly with one finger without pressing down to left-click.")
            defaultValue: false
        }

        ToggleSetting {
            settingKey: "showBatteryText"
            label: I18n.tr("Show battery percentage")
            description: I18n.tr("Print the battery percentage under the mouse in the popout. The ring always shows it.")
            defaultValue: false
        }
    }
}
