import SwiftUI

/// Day/night looks: switch automatically at the chosen hours.
struct ScheduleSection: View {
    @Environment(LookStore.self) private var looks

    var body: some View {
        @Bindable var looks = looks
        Section {
            Toggle(isOn: $looks.scheduleEnabled.animation()) {
                Label("Switch Looks by Time", systemImage: "sun.and.horizon.fill")
            }
            if looks.scheduleEnabled {
                lookPicker("Day", systemImage: "sun.max.fill", selection: $looks.dayLookId)
                hourPicker("Day Starts", selection: $looks.dayStartHour)
                lookPicker("Night", systemImage: "moon.stars.fill", selection: $looks.nightLookId)
                hourPicker("Night Starts", selection: $looks.nightStartHour)
            }
        } header: {
            Text("Schedule")
        } footer: {
            if looks.scheduleEnabled {
                Text("Picking another look by hand keeps it until the next switch.")
            }
        }
    }

    private func lookPicker(_ title: String, systemImage: String, selection: Binding<UUID>) -> some View {
        Picker(selection: selection) {
            ForEach(looks.allLooks) { look in
                Label(look.name, systemImage: look.symbol).tag(look.id)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
                    .formatted(date: .omitted, time: .shortened) ?? "\(hour):00")
                    .tag(hour)
            }
        }
    }
}
