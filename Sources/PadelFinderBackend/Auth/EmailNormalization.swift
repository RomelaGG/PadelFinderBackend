import Foundation

extension String {
    /// Lowercased and trimmed. Every email entering the system goes through
    /// this before it is stored, compared, or used as an OTP lookup key.
    ///
    /// The `citext` columns make the database case-insensitive too; this makes
    /// the value we store and log *canonical*, which is a different thing and
    /// also worth having.
    ///
    /// Deliberately does not strip dots or `+tags` from Gmail addresses. Those
    /// are provider-specific rules, and guessing them wrong merges two people's
    /// accounts - a far worse failure than letting one person hold two.
    var normalizedEmail: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Just the domain, for log lines. Codes and addresses must not land in
    /// logs in full, but "which domain is bouncing" is exactly what you need
    /// when deliverability breaks.
    var emailDomainForLogging: String {
        guard let atIndex = lastIndex(of: "@") else {
            return "invalid"
        }
        return String(self[index(after: atIndex)...])
    }
}
