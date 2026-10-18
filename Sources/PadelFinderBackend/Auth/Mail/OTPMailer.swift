import Vapor

/// Sends the 6-digit code.
///
/// A protocol with one implementation on purpose. Which email provider we use
/// is still open (ARCHITECTURE.md open question 4 - Resend, Postmark, SES and
/// Mailgun are all fine technically, and the choice should be made on
/// deliverability to Georgian inboxes), and nothing about sign-up should wait
/// on that decision. Adding the real one is a single new type.
///
/// Whichever provider wins, SPF, DKIM and DMARC have to be set up on the
/// sending domain before launch, or codes land in spam and sign-up breaks
/// silently with no error to debug.
protocol OTPMailer: Sendable {
    func sendCode(_ code: String, to email: String, purpose: OTPPurpose) async throws
}

/// Logs the code instead of sending it.
///
/// This is what makes the whole email flow testable with no account anywhere:
/// read the code off the console in development, read it off the mailer in
/// tests. The address is logged by domain only - full addresses do not belong
/// in logs, but "which domain is this going to" is exactly what you want when
/// deliverability breaks.
struct LoggingOTPMailer: OTPMailer {
    let logger: Logger

    func sendCode(_ code: String, to email: String, purpose: OTPPurpose) async throws {
        logger.notice(
            "OTP email (not actually sent - no mail provider configured)",
            metadata: [
                "domain": .string(email.emailDomainForLogging),
                "purpose": .string(purpose.rawValue),
                "code": .string(code)
            ]
        )
    }
}
