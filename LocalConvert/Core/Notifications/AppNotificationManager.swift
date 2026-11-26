import Foundation
import AppKit
import UserNotifications
import os.log

// MARK: - VoiceOver Accessibility Announcer

@MainActor
enum AccessibilityAnnouncer {
    private(set) static var recentAnnouncements: [String] = []
    private static var lastAnnouncedMessage: String?
    private static var lastAnnouncedTime: TimeInterval = 0

    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Prevent duplicate consecutive VoiceOver announcement spam within 1.2s
        let now = CFAbsoluteTimeGetCurrent()
        if lastAnnouncedMessage == trimmed && (now - lastAnnouncedTime) < 1.2 {
            return
        }
        lastAnnouncedMessage = trimmed
        lastAnnouncedTime = now

        recentAnnouncements.append(trimmed)
        if recentAnnouncements.count > 32 {
            recentAnnouncements.removeFirst(recentAnnouncements.count - 32)
        }
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: priority.rawValue
            ]
        )
    }

    static func resetRecentAnnouncements() {
        recentAnnouncements.removeAll()
        lastAnnouncedMessage = nil
        lastAnnouncedTime = 0
    }
}

// MARK: - App Notification Manager

@MainActor
final class AppNotificationManager: NSObject, Sendable, UNUserNotificationCenterDelegate {
    
    static let shared = AppNotificationManager()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
    private let center = UNUserNotificationCenter.current()
    
    private var hasPromptedForAuthorization = false
    
    override init() {
        super.init()
        let isTesting = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTesting {
            center.delegate = self
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
    
    /// Requests user notification permissions on-demand only when needed
    func requestAuthorizationIfNeeded() {
        guard !hasPromptedForAuthorization else { return }
        hasPromptedForAuthorization = true
        
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                Task { @MainActor [weak self] in
                    self?.requestAuthorization()
                }
            }
        }
    }
    
    /// Requests user notification permissions (alerts, sounds, badges)
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                Task { @MainActor in
                    Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
                        .error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Task { @MainActor in
                    Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
                        .info("Notification authorization granted: \(granted, privacy: .public)")
                }
            }
        }
    }
    
    /// Delivers completion notification for a single job
    func notifyJobCompleted(job: ConversionJob, result: ConversionResult) {
        if AppSettings.shared.notifyOnConversionCompleted {
            AccessibilityAnnouncer.announce("Conversion complete for \(job.sourceFilename).", priority: .medium)
        }
        guard AppSettings.shared.showCompletionNotification,
              AppSettings.shared.notifyOnConversionCompleted else { return }
        
        requestAuthorizationIfNeeded()
        
        let content = UNMutableNotificationContent()
        content.title = "Conversion Complete"
        content.body = "\(job.sourceFilename) was converted successfully."
        if AppSettings.shared.playCompletionSound {
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: "job-\(job.id.uuidString)",
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                Task { @MainActor in
                    Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
                        .error("Failed to post job completion notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    /// Delivers failure notification for a single job
    func notifyJobFailed(job: ConversionJob, error: ConversionError) {
        AccessibilityAnnouncer.announce(
            "Conversion failed for \(job.sourceFilename): \(error.userFacingMessage)",
            priority: .high
        )
        guard AppSettings.shared.showCompletionNotification,
              AppSettings.shared.notifyOnConversionFailed else { return }
        
        requestAuthorizationIfNeeded()
        
        let content = UNMutableNotificationContent()
        content.title = "Conversion Failed"
        content.body = "\(job.sourceFilename) could not be converted."
        if AppSettings.shared.playCompletionSound {
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: "job-fail-\(job.id.uuidString)",
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                Task { @MainActor in
                    Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
                        .error("Failed to post job failure notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    /// Delivers aggregated batch notification avoiding notification spam
    func notifyBatchCompleted(total: Int, completed: Int, failed: Int, cancelled: Int = 0) {
        guard total > 1 else { return }
        if failed == 0 && cancelled == 0 {
            AccessibilityAnnouncer.announce("Batch conversion complete: \(completed) files succeeded.", priority: .high)
        } else if completed == 0 && failed == 0 && cancelled > 0 {
            AccessibilityAnnouncer.announce("Batch conversion cancelled: \(cancelled) conversions stopped.", priority: .high)
        } else {
            AccessibilityAnnouncer.announce("Batch conversion finished: \(completed) succeeded, \(failed) failed.", priority: .high)
        }

        guard AppSettings.shared.showCompletionNotification,
              AppSettings.shared.notifyOnBatchCompleted else { return }
        
        requestAuthorizationIfNeeded()
        
        let content = UNMutableNotificationContent()
        
        if failed == 0 && cancelled == 0 {
            content.title = "Conversions Complete"
            content.body = "\(completed) files were converted successfully."
        } else if completed == 0 && failed == 0 && cancelled > 0 {
            content.title = "Conversions Cancelled"
            content.body = "\(cancelled) conversion(s) cancelled."
        } else if completed == 0 {
            content.title = "Conversions Failed"
            content.body = "\(failed) files failed to convert."
        } else {
            content.title = "Conversions Finished"
            content.body = "\(completed) completed, \(failed) failed."
        }
        
        if AppSettings.shared.playCompletionSound {
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: "batch-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                Task { @MainActor in
                    Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
                        .error("Failed to post batch completion notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
