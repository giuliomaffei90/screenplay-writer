import SwiftUI

extension View {
    /// Tinted Liquid Glass for the one primary toolbar action; a bordered prominent button before macOS 26.
    @ViewBuilder func prominentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

extension ToolbarContent {
    /// Items without the shared glass capsule (e.g. a spinner); older systems have no capsule anyway.
    @ToolbarContentBuilder func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// A gap between toolbar groups on macOS 26; older toolbars have no glass groups to separate.
struct ToolbarGap: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }
}
