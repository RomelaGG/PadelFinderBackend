import Foundation

/// The wording of the three code emails.
///
/// Kept apart from any provider so switching from Resend to SES later does not
/// touch the copy, and so the copy can be read and improved without reading
/// HTTP code.
///
/// Deliberately plain. A login code is not a marketing email: no images, no
/// tracking, no link to click. The code is the largest thing on the page
/// because on a phone most people read it from the notification without ever
/// opening the message.
struct OTPEmail: Sendable {
    let subject: String
    let plainText: String
    let html: String

    init(code: String, purpose: OTPPurpose, lifetime: TimeInterval) {
        let minutes = max(1, Int(lifetime / 60))

        let headline: String
        let explanation: String

        switch purpose {
        case .signup:
            subject = "\(code) is your PadelFinder code"
            headline = "Confirm your email"
            explanation = "Enter this code in the app to finish setting up your account."
        case .reset:
            subject = "\(code) is your PadelFinder password reset code"
            headline = "Reset your password"
            explanation = "Enter this code in the app to choose a new password."
        case .emailChange:
            subject = "\(code) is your PadelFinder confirmation code"
            headline = "Confirm your new email"
            explanation = "Enter this code in the app to start using this address for your account."
        }

        // The code leads the subject line on purpose: iOS shows the start of it
        // in the notification and offers it for autofill, so a well-formed
        // subject often means the user never opens the email at all.
        let warning = "If you did not ask for this, you can ignore this email. "
            + "Nobody can use the code without it."

        plainText = """
        \(headline)

        \(code)

        \(explanation)
        The code expires in \(minutes) minutes.

        \(warning)
        """

        html = """
        <!doctype html>
        <html>
          <body style="margin:0;padding:24px;background:#f5f5f4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#0a0a0a;">
            <div style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:12px;padding:32px;">
              <h1 style="margin:0 0 8px;font-size:20px;font-weight:600;">\(headline)</h1>
              <p style="margin:0 0 24px;font-size:15px;line-height:1.5;color:#44403c;">\(explanation)</p>
              <p style="margin:0 0 24px;font-size:36px;font-weight:700;letter-spacing:6px;font-variant-numeric:tabular-nums;">\(code)</p>
              <p style="margin:0 0 24px;font-size:14px;color:#57534e;">The code expires in \(minutes) minutes.</p>
              <p style="margin:0;font-size:13px;line-height:1.5;color:#78716c;">\(warning)</p>
            </div>
          </body>
        </html>
        """
    }
}
