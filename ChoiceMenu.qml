import QtQuick
import qs.Commons

// One modal list, four uses: the action panel, the skin tone submenu, the
// category filter and preferences. They differ only in what fills `entries`,
// so they share a component rather than drifting apart visually.
//
// It draws and reports; it never takes focus. The picker owns the single key
// catcher and drives selectedIndex, which is what keeps focus from being
// handed around between surfaces that appear and vanish.
Item {
  id: menu

  property string title: ""
  property var entries: []
  property int selectedIndex: 0
  property bool showsPreview: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: Style.cornerRadius

  readonly property int rowHeight: Math.max(Style.space(30), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int headerHeight: Math.max(Style.space(26), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int menuWidth: Style.space(320)
  readonly property int listHeight: Math.min(menu.height - Style.space(80), Math.max(rowHeight, entries.length * rowHeight))

  signal activated(int index)
  signal hovered(int index)
  signal dismissed()

  visible: false

  function positionAt(index) {
    list.positionViewAtIndex(index, ListView.Contain)
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: menu.dismissed()
  }

  // Derived from the card colour rather than the theme's scrim token: some
  // themes leave that fully transparent, and then the grid reads straight
  // through the menu that is supposed to be in front of it.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(menu.background, 0.66)
  }

  Rectangle {
    id: card
    width: menu.menuWidth
    height: menu.headerHeight + menu.listHeight + Style.spacing.md * 2
    anchors.centerIn: parent
    radius: menu.cornerRadius
    color: menu.background
    border.width: Style.normalBorderWidth
    border.color: Util.alpha(menu.borderColor, 0.7)

    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      spacing: 0

      Text {
        width: parent.width
        height: menu.headerHeight
        text: menu.title
        color: menu.foreground
        opacity: 0.6
        font.family: menu.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.capitalization: Font.AllUppercase
        verticalAlignment: Text.AlignVCenter
        leftPadding: Style.spacing.rowPaddingX
        elide: Text.ElideRight
      }

      ListView {
        id: list
        width: parent.width
        height: menu.listHeight
        model: menu.entries.length
        clip: true
        interactive: menu.entries.length * menu.rowHeight > menu.listHeight
        highlightFollowsCurrentItem: false
        boundsBehavior: Flickable.StopAtBounds
        pixelAligned: true

        delegate: Rectangle {
          id: row
          required property int index

          readonly property var entry: menu.entries[index] || ({})
          readonly property bool current: index === menu.selectedIndex

          width: ListView.view.width
          height: menu.rowHeight
          radius: menu.cornerRadius
          color: current ? menu.selectedBackground : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.spacing.md

            Text {
              width: menu.showsPreview ? Style.space(28) : 0
              height: parent.height
              visible: menu.showsPreview
              text: row.entry.preview || ""
              font.family: menu.fontFamily
              font.pixelSize: Style.font.heading
              verticalAlignment: Text.AlignVCenter
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width - (menu.showsPreview ? Style.space(28) + parent.spacing : 0)
                - hint.width - parent.spacing
              height: parent.height
              text: row.entry.label || ""
              color: row.current ? menu.selectedText : menu.foreground
              font.family: menu.fontFamily
              font.pixelSize: Style.font.title
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
            }

            Text {
              id: hint
              height: parent.height
              text: row.entry.hint || ""
              color: row.current ? menu.selectedText : menu.foreground
              opacity: 0.55
              font.family: menu.fontFamily
              font.pixelSize: Style.font.bodySmall
              verticalAlignment: Text.AlignVCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: menu.hovered(row.index)
            onClicked: menu.activated(row.index)
          }
        }
      }
    }
  }
}
