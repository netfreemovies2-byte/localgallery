import SwiftUI
import WidgetKit

@main
struct PixelPicWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MemoriesWidget()
        FolderWidget()
        TagsWidget()
    }
}
