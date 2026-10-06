import Foundation
import UserNotifications
import os.log

// MARK: - App Notification Manager

@MainActor
final class AppNotificationManager: NSObject, Sendable {
    
    static let shared = AppNotificationManager()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppNotificationManager")
    private let center = UNUserNotificationCenter.current()
    
    private var hasPromptedForAuthorization = false
    
    override init() {
        super.init()
    }
    
    /// Requests user notification permissions on-demand only when needed
    func requestAuthorizationIfNeeded() {
        guard !hasPromptedForAuthorization else { return }
        hasPromptedForAuthorization = true
        
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                self?.requestAuthorization()
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
        guard AppSettings.shared.showCompletionNotification,
              AppSettings.shared.notifyOnBatchCompleted else { return }
        
        guard total > 1 else { return }
        
        requestAuthorizationIfNeeded()
        
        let content = UNMutableNotificationContent()
        
        if failed == 0 && cancelled == 0 {
            content.title = "Conversions Complete"
            content.body = "\(completed) files were converted successfully."
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
