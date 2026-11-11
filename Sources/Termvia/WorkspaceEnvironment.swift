import SwiftUI

/// Independent hosting roots share the window's resolved appearance and locale.
private struct WorkspaceEnvironment: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.environment(\.locale, model.locale).environment(\.colorScheme, model.colorScheme)
    }
}
extension View {
    func workspaceEnvironment(model: AppModel) -> some View { modifier(WorkspaceEnvironment(model: model)) }
}
