@testable import PadelFinderBackend
import Foundation
import NIOCore
import NIOPosix
import Testing
import Vapor

/// Records what would have gone to Resend, and answers with whatever the test
/// asks for.
///
/// This is why the mailer needed no account and no API key to be verified: the
/// contract is one POST, so a stub of the HTTP client exercises all of it -
/// the body we build, the header we set, and every way the provider can say no.
final class StubClient: Client, @unchecked Sendable {
    struct Captured: Sendable {
        let url: String
        let method: HTTPMethod
        let authorization: String?
        let body: String
    }

    let eventLoop: any EventLoop
    private let status: HTTPResponseStatus
    private let responseBody: String
    private(set) var captured: [Captured] = []

    init(eventLoop: any EventLoop, status: HTTPResponseStatus = .ok, responseBody: String = #"{"id":"stub"}"#) {
        self.eventLoop = eventLoop
        self.status = status
        self.responseBody = responseBody
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        self
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        captured.append(
            Captured(
                url: request.url.string,
                method: request.method,
                authorization: request.headers.bearerAuthorization?.token,
                body: request.body.map { String(buffer: $0) } ?? ""
            )
        )

        var buffer = ByteBufferAllocator().buffer(capacity: responseBody.utf8.count)
        buffer.writeString(responseBody)

        return eventLoop.makeSucceededFuture(
            ClientResponse(
                status: status,
                headers: ["content-type": "application/json"],
                body: buffer
            )
        )
    }
}

@Suite("Resend mailer")
struct ResendOTPMailerTests {
    /// NIO's shared group, so no test owns an event loop it has to shut down.
    private static let eventLoop: any EventLoop = NIOSingletons.posixEventLoopGroup.any()

    /// Nested `#require` calls cannot expand inside one another, so the decode
    /// is a plain function.
    private static func decodeJSON(_ body: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    }

    private func makeMailer(
        client: StubClient,
        fromAddress: String = "PadelFinder <codes@padelfinder.ge>"
    ) -> ResendOTPMailer {
        ResendOTPMailer(
            client: client,
            apiKey: "re_test_key",
            fromAddress: fromAddress,
            otpLifetime: 600,
            logger: Logger(label: "test")
        )
    }

    @Test("A successful send posts the code to Resend with our key")
    func successfulSend() async throws {
        let client = StubClient(eventLoop: Self.eventLoop)
        let mailer = makeMailer(client: client)

        try await mailer.sendCode("123456", to: "player@example.com", purpose: .signup)

        #expect(client.captured.count == 1)
        let request = try #require(client.captured.first)

        #expect(request.url == "https://api.resend.com/emails")
        #expect(request.method == .POST)
        #expect(request.authorization == "re_test_key")

        // The payload Resend actually needs. Asserted on the wire format rather
        // than on the Swift struct, because the struct is not the contract.
        let body = try #require(Self.decodeJSON(request.body))
        #expect(body["from"] as? String == "PadelFinder <codes@padelfinder.ge>")
        #expect(body["to"] as? [String] == ["player@example.com"])

        // The code has to appear in all three places a user might read it: the
        // notification (subject), the plain-text part, and the HTML part.
        let subject = try #require(body["subject"] as? String)
        let text = try #require(body["text"] as? String)
        let html = try #require(body["html"] as? String)
        #expect(subject.hasPrefix("123456"))
        #expect(text.contains("123456"))
        #expect(html.contains("123456"))
        #expect(text.contains("10 minutes"))
    }

    @Test("Each purpose gets its own wording")
    func purposesHaveDistinctCopy() async throws {
        var subjects: [String] = []

        for purpose in OTPPurpose.allCases {
            let client = StubClient(eventLoop: Self.eventLoop)
            try await makeMailer(client: client)
                .sendCode("123456", to: "player@example.com", purpose: purpose)

            let request = try #require(client.captured.first)
            let body = try #require(Self.decodeJSON(request.body))
            subjects.append(try #require(body["subject"] as? String))
        }

        // A reset code that reads like a sign-up code trains people to type
        // codes into whatever asked for one, which is how phishing works.
        #expect(Set(subjects).count == OTPPurpose.allCases.count)
    }

    @Test("A rejected send throws rather than reporting success")
    func rejectedSendThrows() async throws {
        let client = StubClient(
            eventLoop: Self.eventLoop,
            status: .unprocessableEntity,
            responseBody: #"{"message":"Invalid from address"}"#
        )

        // Swallowing this would answer 202 for an email that never left, and
        // the user would wait on the code screen forever.
        await #expect(throws: OTPMailerError.sendFailed(status: 422)) {
            try await makeMailer(client: client)
                .sendCode("123456", to: "player@example.com", purpose: .signup)
        }
    }

    @Test("Hitting the provider's rate limit is surfaced, not swallowed")
    func rateLimitIsSurfaced() async throws {
        let client = StubClient(
            eventLoop: Self.eventLoop,
            status: .tooManyRequests,
            responseBody: #"{"message":"Daily quota exceeded"}"#
        )

        // The free tier's daily ceiling. Without this the failure mode on a
        // launch-day spike is "the app is broken" with nothing in the logs.
        await #expect(throws: OTPMailerError.sendFailed(status: 429)) {
            try await makeMailer(client: client)
                .sendCode("123456", to: "player@example.com", purpose: .signup)
        }
    }

    @Test("A rejected key is surfaced")
    func badKeyIsSurfaced() async throws {
        let client = StubClient(eventLoop: Self.eventLoop, status: .unauthorized)

        await #expect(throws: OTPMailerError.sendFailed(status: 401)) {
            try await makeMailer(client: client)
                .sendCode("123456", to: "player@example.com", purpose: .signup)
        }
    }

    @Test("Nothing in the email body leaks the API key")
    func theKeyStaysInTheHeader() async throws {
        let client = StubClient(eventLoop: Self.eventLoop)
        try await makeMailer(client: client)
            .sendCode("123456", to: "player@example.com", purpose: .signup)

        let request = try #require(client.captured.first)
        #expect(!request.body.contains("re_test_key"))
    }

    @Test("OTP_MAILER=resend without a key fails at boot, not at first sign-up")
    func resendRequiresAKey() throws {
        // A deploy that boots green and then cannot send a single code is worse
        // than one that refuses to boot.
        #expect(throws: AuthConfigurationError.self) {
            try AuthConfiguration.validateMailerSettings(
                kind: .resend,
                apiKey: nil,
                environment: .production
            )
        }

        #expect(throws: Never.self) {
            try AuthConfiguration.validateMailerSettings(
                kind: .resend,
                apiKey: "re_live_key",
                environment: .production
            )
        }
    }

    @Test("The log mailer is refused in production, not merely warned about")
    func logMailerIsRefusedInProduction() throws {
        // It answers 202 for an email that was never sent, so no real user can
        // finish a sign-up and nothing says so - and it leaves every code in
        // the logs in plain text. A boot failure is the only signal loud enough.
        #expect(throws: AuthConfigurationError.self) {
            try AuthConfiguration.validateMailerSettings(
                kind: .log,
                apiKey: nil,
                environment: .production
            )
        }

        // An unset OTP_MAILER defaults to `log`, so production also refuses to
        // boot when the variable was simply forgotten.
        for environment in [Environment.development, .testing] {
            #expect(throws: Never.self) {
                try AuthConfiguration.validateMailerSettings(
                    kind: .log,
                    apiKey: nil,
                    environment: environment
                )
            }
        }
    }
}
