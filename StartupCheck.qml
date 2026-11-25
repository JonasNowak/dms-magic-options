import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("magicOptions.pythonCheck", ["which", "python3"], (stdout, exitCode) => {
            if (exitCode !== 0) {
                done({
                    title: I18n.tr("python3 is required"),
                    details: I18n.tr("Install python3 with your package manager; it runs the gesture bridge.")
                })
                return
            }
            // Device permissions are reported in the popout, not here: a failed
            // startup check keeps the whole plugin unloaded, and the mouse may
            // simply not be connected right now.
            done(null)
        })
    }
}
