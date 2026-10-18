import Fluent

extension Error {
    /// Whether this is the database refusing a write that broke a unique or
    /// foreign key constraint.
    ///
    /// The design leans on constraints to decide races - one Apple account per
    /// user, one password identity per address, and later one booking per slot
    /// - which means a constraint violation is frequently a *normal* outcome
    /// rather than a fault. Telling that apart from a real failure needs this,
    /// and it goes through Fluent's `DatabaseError` rather than Postgres error
    /// codes so it does not have to change if the driver does.
    var isDatabaseConstraintFailure: Bool {
        (self as? any DatabaseError)?.isConstraintFailure == true
    }
}
