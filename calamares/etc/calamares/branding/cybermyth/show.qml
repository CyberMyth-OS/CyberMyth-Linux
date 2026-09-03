/* CyberMyth OS installer slideshow.
 *
 * Adapted from calamares-settings-debian's show.qml (GPL-3+). Kept to a single
 * slide on purpose: the Presentation/Slide API is the part most likely to shift
 * between Calamares releases, and a QML error here shows a blank pane for the
 * whole install rather than failing loudly.
 */

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        interval: 20000
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Image {
            id: background1
            source: "slide1.png"
            width: 467; height: 280
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
        Text {
            anchors.horizontalCenter: background1.horizontalCenter
            anchors.top: background1.bottom
            text: qsTr("Welcome to CyberMyth OS.<br/>"+
                  "Anonymity and offensive security, on a Debian 13 base.<br/>"+
                  "The rest of the installation is automated and should complete in a few minutes.")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }
}
