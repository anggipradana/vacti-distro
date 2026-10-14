import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Timer {
        interval: 6000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0B1324"
            Column {
                anchors.centerIn: parent
                spacing: 14
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Vacti OS"
                    color: "#EEF2F8"
                    font.pixelSize: 40
                    font.bold: true
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "The complete offensive security platform"
                    color: "#9FB0C6"
                    font.pixelSize: 18
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0B1324"
            Text {
                anchors.centerIn: parent
                width: parent.width * 0.7
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "VA   -   AI Pentest   -   Bug Bounty   -   CTF   -   Threat Intel"
                color: "#37B6FF"
                font.pixelSize: 22
            }
        }
    }
}
