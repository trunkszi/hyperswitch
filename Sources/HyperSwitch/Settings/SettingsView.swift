import SwiftUI

/// The settings window.
///
/// A pinned source list against a grouped-`Form` detail pane — the shape macOS itself now
/// uses for settings. The segmented strip this replaces was faithful to the 2018 original
/// and read as such: a tab bar across the top is simply not what a current macOS settings
/// window looks like.
///
/// Two things do the work of making it feel native, and neither is decoration: the
/// sidebar's own material and selection capsule (never hand-drawn), and letting `Form`
/// own row height, insets and separators. The bilingual label problem solves itself as a
/// side effect — `LabeledContent` measures the label column per language, where a
/// hand-built grid had to be sized for whichever language was wider.
struct SettingsView: View {
    @Bindable var selection: TabSelection

    /// Wide enough for the longest label in either language.
    ///
    /// Sized from English, not Chinese: "App Switcher" is far longer than 应用切换器, and a
    /// column measured for the Chinese labels truncates it. Scales with the user's text
    /// size so it does not clip at larger sizes either.
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 200

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewColumnWidth(sidebarWidth)
        // The sidebar is the only navigation this window has, so it must never be
        // collapsible — losing it would leave no way to reach the other panes.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 580)
        .localizedFollowingPreference()
    }

    private var sidebar: some View {
        List(selection: bridgedSelection) {
            Section {
                ForEach(SettingsTab.primary) { row($0) }
            }
            Section {
                ForEach(SettingsTab.secondary) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    private func row(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            TabChip(symbol: tab.symbol, tint: tab.tint)
        }
        .tag(tab)
    }

    /// `NavigationSplitView` writes `nil` into its selection during layout passes, which
    /// would otherwise blank the detail pane. Swallowing the `nil` keeps the last choice.
    private var bridgedSelection: Binding<SettingsTab?> {
        Binding(
            get: { selection.current },
            set: { if let new = $0 { selection.current = new } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selection.current {
            case .general: GeneralPane()
            case .appSwitcher: AppSwitcherPane()
            case .interaction: InteractionPane()
            case .appearance: AppearancePane()
            case .about: AboutPane()
            }
        }
        // Applied once here rather than in each pane: this is what draws the rounded
        // section cards, the separators between rows and the styled section headers.
        // Without it a `Form` falls back to a plain stack and the headers read as loose
        // text stranded between controls.
        .formStyle(.grouped)
    }
}

/// The tinted rounded-square icon System Settings puts beside each sidebar row.
///
/// Colours come from system semantic colours rather than a bespoke palette, so Increase
/// Contrast keeps its ratios without anything here needing to be re-audited.
struct TabChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Shared controls

/// A numeric field with a stepper and a trailing unit.
///
/// The field is sized by the digits it must hold rather than a fixed point value, so it
/// grows with the user's text size instead of clipping.
///
/// `range` binds the *typed* number as well as the stepper. That is not symmetry for its
/// own sake: only the stepper clamps on its own, so a bound like `0...5000` used to be
/// advisory the moment anyone touched the keyboard, and a delay of 999999 ms is a
/// switcher that silently never appears with nothing on screen to explain why.
struct NumberField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100_000
    var unit: LocalizedStringKey?
    var digits: Int = 4
    /// Greys the whole row out. Separate from `.disabled()` at the call site only so the
    /// unit text dims with the field — `.disabled` sets an environment flag that controls
    /// respond to, and a `Text` is not a control, so it would otherwise stay full-strength
    /// beside a greyed-out field.
    var isEnabled: Bool = true

    @Environment(\.isEnabled) private var isEnabledByEnvironment
    @ScaledMetric(relativeTo: .body) private var digitWidth: CGFloat = 11

    /// What is being typed, or `nil` when the field is simply reflecting `value`.
    ///
    /// The keystrokes land here rather than straight in `value` so an out-of-range number
    /// is never written to the preference at all, not even for the instant between the
    /// commit and the clamp — `Preferences` persists on write, and the switcher reads it
    /// from another task.
    @State private var draft: Int?

    /// Bumped only when a clamp actually rewrote what was typed.
    ///
    /// Changing the field's identity is what rebuilds it from the binding. A `TextField`
    /// that is still first responder keeps displaying the text the user typed even after
    /// the bound value changes underneath it, so on ⏎ the preference would be 5000 while
    /// the field still read 999999 — the one state where a clamp is invisible.
    @State private var fieldGeneration = 0

    @FocusState private var isEditing: Bool

    private var isLive: Bool { isEnabled && isEnabledByEnvironment }

    /// Shows `value` until something is typed, then the draft.
    ///
    /// Deliberately not a `@State` seeded in `onAppear`: that flashes a 0 on the first
    /// frame and goes stale whenever the value changes from elsewhere — the stepper,
    /// Restore Defaults, the debug bridge.
    private var fieldValue: Binding<Int> {
        Binding(get: { draft ?? value }, set: { draft = $0 })
    }

    /// Writes the typed number back, inside `range`.
    private func commitDraft() {
        guard let typed = draft else { return }
        draft = nil
        let clamped = min(max(typed, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        if clamped != typed { fieldGeneration &+= 1 }
    }

    var body: some View {
        // Field and stepper stay separate views. Putting the TextField inside
        // `Stepper(value:in:) { }` looks tidier but macOS treats that closure as a plain
        // text label and drops any control in it — the field vanished entirely, leaving
        // just a stepper and a unit.
        //
        // Alignment instead comes from fixing all three widths, so every row in a column
        // has its field, stepper and unit at the same x regardless of how many digits or
        // how long the unit is.
        HStack(spacing: 4) {
            TextField("", value: fieldValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: CGFloat(digits) * digitWidth + 16)
                .focused($isEditing)
                // Both, because the two ways of leaving a text field are not
                // interchangeable: ⏎ submits without ever changing focus, and clicking
                // away changes focus without ever submitting. Clamping on only one of
                // them leaves the other as the hole the range was supposed to close.
                .onSubmit { commitDraft() }
                .onChange(of: isEditing) { _, editing in
                    if !editing { commitDraft() }
                }
                // The stepper (or a reset) moving the value out from under a half-typed
                // draft: the authoritative number wins, rather than the field going on
                // showing digits that no longer correspond to anything.
                .onChange(of: value) { _, _ in draft = nil }
                // Outermost so the whole focused field is rebuilt, not just the control
                // inside the focus modifier.
                .id(fieldGeneration)
            Stepper("", value: $value, in: range)
                .labelsHidden()
            if let unit {
                Text(unit)
                    .foregroundStyle(isLive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(minWidth: 30, alignment: .leading)
            }
        }
        .disabled(!isEnabled)
    }
}
