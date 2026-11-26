import SwiftUI

struct AudioOutputDevicePicker: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var deviceMonitor: CoreAudioOutputDeviceMonitor

    @AppStorage("settings.audioAutoPauseArbitration", store: AppStoragePaths.userDefaults)
    private var autoPauseStored: Bool = true

    @State private var localAutoPause: Bool = true

    init(playback: PlaybackCoordinator, deviceMonitor: CoreAudioOutputDeviceMonitor? = nil) {
        self.playback = playback
        self.deviceMonitor = deviceMonitor ?? playback.outputDeviceMonitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Image(systemName: "hifispeaker.2.fill")
                    .foregroundStyle(AppTheme.Colors.accent)
                Text("Audio Output Device")
                    .font(AppTheme.Typography.sectionTitle)
                Spacer()
                Button {
                    deviceMonitor.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh Audio Devices")
                .accessibilityLabel("Refresh audio output devices")
                .accessibilityIdentifier("audioworkspace.device_picker.refresh")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    deviceRow(
                        title: "System Default",
                        subtitle: deviceMonitor.defaultDevice.map {
                            "\($0.name) · \(Self.formatRate($0.nominalSampleRateHz))"
                        } ?? "No active output device",
                        isSelected: deviceMonitor.selectedDeviceUID == nil,
                        isDefault: true
                    ) {
                        Task { _ = await playback.selectOutputDevice(uid: nil) }
                    }
                    .accessibilityIdentifier("audioworkspace.device_picker.system_default")
                    .accessibilityLabel("System Default output device")
                    .accessibilityValue(deviceMonitor.selectedDeviceUID == nil ? "Selected" : "Not selected")

                    if !deviceMonitor.availableDevices.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                    }

                    ForEach(deviceMonitor.availableDevices) { device in
                        let isSelected = deviceMonitor.selectedDeviceUID == device.uid
                        deviceRow(
                            title: device.name,
                            subtitle: "\(Self.formatRate(device.nominalSampleRateHz)) · \(device.outputChannelCount) ch\(device.isDefault ? " · Default" : "")",
                            isSelected: isSelected,
                            isDefault: device.isDefault
                        ) {
                            Task { _ = await playback.selectOutputDevice(uid: device.uid) }
                        }
                        .accessibilityIdentifier("audioworkspace.device_picker.device.\(device.uid)")
                        .accessibilityLabel("\(device.name), \(Self.formatRate(device.nominalSampleRateHz)), \(device.outputChannelCount) channels")
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    }
                }
            }
            .frame(maxHeight: 220)
            .accessibilityIdentifier("audioworkspace.device_picker.list")

            Divider()

            Toggle("Auto-pause other audio transport", isOn: $localAutoPause)
                .font(AppTheme.Typography.caption)
                .help("Automatically pause the Editor when the Library Player starts, and vice versa")
                .accessibilityLabel("Auto-pause other audio transport")
                .accessibilityHint("Non-destructively pauses the other player when playback starts")
                .accessibilityValue(localAutoPause ? "On" : "Off")
                .accessibilityIdentifier("audioworkspace.device_picker.auto_pause_toggle")
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: 310)
        .onAppear {
            localAutoPause = AppSettings.shared.audioAutoPauseArbitration
        }
        .onChange(of: autoPauseStored) { _, next in
            if localAutoPause != next {
                localAutoPause = next
            }
        }
        .onChange(of: localAutoPause) { _, next in
            if AppSettings.shared.audioAutoPauseArbitration != next {
                AppSettings.shared.audioAutoPauseArbitration = next
            }
        }
    }

    private func deviceRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        isDefault: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : (isDefault ? "speaker.wave.2" : "hifispeaker"))
                    .foregroundStyle(isSelected ? AppTheme.Colors.accent : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppTheme.Typography.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 5)
            .background(isSelected ? AppTheme.Colors.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func formatRate(_ hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "—" }
        return String(format: "%.1f kHz", hz / 1000.0)
    }
}
