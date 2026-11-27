import Foundation
import UserNotifications

enum Notifier {
    static let checkInCategory = "HUNCH_CHECKIN"
    static let hunchedAction = "HUNCHED"
    static let fineAction = "FINE"

    /// Called on the main actor with the answer to a hunch check-in (true = hunched).
    nonisolated(unsafe) static var onCheckInAnswer: ((Bool) -> Void)?

    /// The check-in notification's Yes / No buttons.
    static func checkInCategoryDefinition() -> UNNotificationCategory {
        let yes = UNNotificationAction(identifier: hunchedAction, title: "Yes, I'm hunched", options: [])
        let no = UNNotificationAction(identifier: fineAction, title: "No, I'm fine", options: [])
        return UNNotificationCategory(identifier: checkInCategory, actions: [yes, no], intentIdentifiers: [], options: [])
    }

    /// Installs the answer handler and the check-in buttons. Call at launch: without it, check-ins sent
    /// later have no Yes / No buttons and answers are dropped. (Doesn't prompt for permission.)
    static func configure() {
        guard Bundle.main.bundleIdentifier != nil else { return }      // e.g. the test runner: no app bundle
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationHandler.shared
        center.setNotificationCategories([checkInCategoryDefinition()])
    }

    /// Asks for permission (deferred until it's relevant: calibrating, a test alert, "Ask me now").
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        configure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter sound: false when the app plays its own chime (so you don't hear two sounds).
    static func send(title: String, body: String, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// "Are you hunched right now?" with Yes / No buttons (teaches the personal hunch model).
    static func sendCheckIn() {
        let content = UNMutableNotificationContent()
        content.title = "Quick posture check"
        content.body = "Are your shoulders hunched right now? Your answer helps Posture learn what your hunch looks like."
        content.categoryIdentifier = checkInCategory
        let req = UNNotificationRequest(identifier: "hunch-checkin", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Shows posture alerts as banners even while the app is frontmost, and routes check-in answers back to the app.
private final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let answer: Bool?
        switch response.actionIdentifier {
        case Notifier.hunchedAction: answer = true
        case Notifier.fineAction: answer = false
        default: answer = nil
        }
        if let answer { DispatchQueue.main.async { Notifier.onCheckInAnswer?(answer) } }
        completionHandler()
    }
}
