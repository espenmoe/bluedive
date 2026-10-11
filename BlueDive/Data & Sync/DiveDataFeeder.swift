import SwiftUI
import SwiftData

// MARK: - Dive Data Feeder

/// The app's only `@Query Dive` (and `@Query MarineSight`) owner. Attached once with
/// `.background(DiveDataFeeder())` to the `TabView` in `MainTabView`, next to
/// `DiverSourcesFeeder` and `RemoteChangeFeeder`, so it stays mounted whatever tab is shown:
/// DiveStore's caches (`dives`, summaries, filters, badges, widget data) follow every change in
/// dive membership — a dive added, deleted or merged here or on another device — even while
/// the Dives tab is not shown. A background view, not queries on `MainTabView` itself, so a
/// delivery re-evaluates only this view, not every tab.
struct DiveDataFeeder: View {
    @Environment(DiveStore.self) private var store
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @Query(sort: \MarineSight.name) private var allMarineSights: [MarineSight]
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @State private var prefs = UserPreferences.shared

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear {
                if !store.hasCacheBuilt {
                    // Cold launch: build the caches at once.
                    store.rebuildDerivedDiveState(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
                } else {
                    // A new window or a scene re-activation: the membership-guarded debounced
                    // path skips the rebuild when nothing changed.
                    store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
                }
                store.updateWidgetDiveData(dives: dives)
            }
            .onChange(of: dives) { _, _ in
                store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
            }
            // Depths are shown (and written to the widget) in the display unit.
            .onChange(of: prefs.depthUnit) { _, _ in
                store.updateWidgetDiveData(dives: dives)
                store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver)
            }
    }
}
