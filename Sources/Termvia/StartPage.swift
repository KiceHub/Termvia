import SwiftUI
import TermviaCore

struct StartPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                BrandMark(size: 44).accessibilityIdentifier("Termvia.StartPage.Icon")
                Text("Termvia").font(.title2).accessibilityIdentifier("Termvia.StartPage.Title")
            }
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Button { model.presentHostEditor() } label: { Label(T("新建主机"), systemImage: "plus") }.help(T("新建主机"))
                        .accessibilityIdentifier("Termvia.StartPage.NewHost")
                    Button { model.connect(nil) } label: { Label(T("本地终端"), systemImage: "terminal") }.help(T("本地终端"))
                        .accessibilityIdentifier("Termvia.StartPage.LocalTerminal")
                }
                SettingsLink { Label(T("设置…"), systemImage: "gearshape") }.buttonStyle(.link).help(T("设置…"))
                    .accessibilityIdentifier("Termvia.StartPage.Settings")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)

#if TERMVIA_DIAGNOSTICS
        .background(AppearanceCheckProbe(role: "start-page"))
#endif

    }
}
