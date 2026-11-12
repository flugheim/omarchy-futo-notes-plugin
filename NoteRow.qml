import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
  id: row

  property string title: ""
  property string path: ""
  property bool isImage: false
  property bool selected: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal activated()

  width: parent ? parent.width : implicitWidth
  height: inner.implicitHeight + Style.space(14)
  radius: Style.cornerRadius
  color: selected
    ? Style.hoverFillFor(foreground, Commons.Color.accent)
    : (area.containsMouse ? Style.hoverFillFor(foreground, 1.08) : "transparent")
  border.color: selected ? Style.hoverStateColor(foreground, Commons.Color.accent) : "transparent"
  border.width: selected ? 1 : 0

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.activated()
  }

  Column {
    id: inner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(3)

    Row {
      spacing: Style.space(8)
      Text {
        text: row.isImage ? "󰋩" : "󰠮"
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        text: row.title
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: inner.width - Style.space(28)
      }
    }
    Text {
      visible: row.path !== ""
      text: row.path
      color: Qt.darker(row.foreground, 1.6)
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
      width: inner.width
    }
  }
}