import SwiftUI

/// Tabs: Today / History / Check-in. Imports, coach replies and Settings live in the More menu;
/// everything for testing and tuning lives in Settings → Developer.
struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var router = AppRouter.shared
        TabView(selection: $router.tab) {
            Tab("Today", systemImage: "calendar", value: AppRouter.Tab.today) {
                NavigationStack { TodayView() }
            }
            Tab("History", systemImage: "list.bullet.rectangle", value: AppRouter.Tab.history) {
                NavigationStack { HistoryView() }
            }
            Tab("Check-in", systemImage: "checklist", value: AppRouter.Tab.checkIn) {
                NavigationStack { CheckInView(store: store) }
            }
        }
        .tint(Theme.cobalt)
        .sheet(isPresented: $router.showImport) {
            ImportFlow().environment(store)
        }
        .sheet(isPresented: $router.showSettings, onDismiss: router.settingsDismissed) {
            NavigationStack { SettingsView() }.tint(Theme.cobalt).environment(store)
        }
        .sheet(isPresented: $router.showAddReply) {
            AddCoachReplyView().environment(store)
        }
        .sheet(isPresented: $router.showChatImport) {
            ChatImportView().environment(store)
        }
        .sheet(item: $router.openReply) { reply in
            CoachReplyView(reply: reply).environment(store)
        }
        .fullScreenCover(isPresented: $router.showCheckInMorning, onDismiss: { router.morningFresh = false }) {
            CheckInMorningView(coordinator: CheckInCoordinator(store: store), store: store, fresh: router.morningFresh).environment(store)
        }
        .fullScreenCover(isPresented: $router.showMorningSession) {
            if let morning = store.morningAddOnDue() {
                SessionView(day: nil, addOns: [morning.addOn], weekNumber: store.todayDay?.week.number ?? 1, store: store)
            } else {
                MorningNothingDueView()
            }
        }
        .task {
            startMorningIfDue()
            await ShareInbox.drain(into: store)
        }
        .onOpenURL { url in WatchService.shared.handle(url: url) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            store.refreshCycle()
            startMorningIfDue()
            Task { await ShareInbox.drain(into: store) }
        }
    }
}

extension RootView {
    /// Check-in morning with no tap on the due morning (MorningStart), once per day.
    fileprivate func startMorningIfDue() {
        let settings = Settings.shared
        let schedule = CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt)
        guard MorningStart.shouldStart(schedule: schedule, lastSentAt: store.lastSentCheckIn?.sentAt,
                                       lastStartedDay: settings.lastMorningAutoStart) else { return }
        settings.lastMorningAutoStart = DayKey.string(.now)
        AppRouter.shared.tab = .today
        AppRouter.shared.showCheckInMorning = true
    }
}

#Preview {
    RootView().environment(Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-store")))
}


/// "Start my Setecho morning" on a day with no on-waking add-on due.
private struct MorningNothingDueView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Text("Nothing due this morning").font(.hudState).foregroundStyle(Theme.navy)
            Text("Your morning add-on is done for the week, or it's not one of its days.").font(.hudLabel).secondaryText().multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.setechoPrimary)
        }
        .padding(Theme.gutter)
        .background(Theme.page.ignoresSafeArea())
    }
}
