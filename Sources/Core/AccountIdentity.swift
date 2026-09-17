import Foundation

/// Who an account actually belongs to, as reported by the provider.
///
/// This is the answer to the question the whole dashboard exists to make easy:
/// *which account is this?* It is discovered from provider metadata during
/// onboarding, never guessed from the order credentials happen to appear in, and
/// never invented. `verified` records whether the provider told us or the user
/// typed it.
struct AccountIdentity: Codable, Equatable {
    /// The account's e-mail, when the provider reports one.
    var email: String?
    /// A stable provider-side identifier. The strongest key we have for telling
    /// two accounts apart and for spotting a duplicate.
    var providerAccountID: String?
    /// Organisation or workspace name, when reported. Kept verbatim; see
    /// `usefulOrganizationName` for whether it is worth showing.
    var organizationName: String?
    /// The person's own name, when the provider reports one. Not displayed —
    /// it exists so an organisation auto-named after the account holder can be
    /// recognised as such.
    var personName: String?
    /// The provider's own plan identifier, kept verbatim for diagnostics.
    var planRaw: String?
    /// A friendly plan name, but only where the mapping is certain.
    var planLabel: String?
    /// True when this came from provider metadata rather than from a person
    /// typing it into a box.
    var verified: Bool
    var detectedAt: Date

    init(email: String? = nil,
         providerAccountID: String? = nil,
         organizationName: String? = nil,
         personName: String? = nil,
         planRaw: String? = nil,
         planLabel: String? = nil,
         verified: Bool,
         detectedAt: Date = Date()) {
        self.email = email.flatMap { $0.isEmpty ? nil : $0 }
        self.providerAccountID = providerAccountID.flatMap { $0.isEmpty ? nil : $0 }
        self.organizationName = organizationName.flatMap { $0.isEmpty ? nil : $0 }
        self.personName = personName.flatMap { $0.isEmpty ? nil : $0 }
        self.planRaw = planRaw.flatMap { $0.isEmpty ? nil : $0 }
        self.planLabel = planLabel.flatMap { $0.isEmpty ? nil : $0 }
        self.verified = verified
        self.detectedAt = detectedAt
    }

    /// Did we learn enough to name this account after a person rather than a
    /// counter?
    var isIdentified: Bool { email != nil || providerAccountID != nil }

    /// Whether two identities describe the same account.
    ///
    /// A stable provider id settles it outright. Failing that we fall back to
    /// the e-mail, compared case-insensitively. Two identities that share
    /// nothing comparable are treated as *different*, because wrongly merging
    /// two accounts is a worse failure than showing a duplicate the user can
    /// remove.
    func matches(_ other: AccountIdentity) -> Bool {
        if let a = providerAccountID, let b = other.providerAccountID {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        if let a = email, let b = other.email {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        return false
    }

    /// The organisation, but only when naming it actually tells the user
    /// something.
    ///
    /// Both providers auto-create a personal organisation for an individual
    /// account and name it after the person — Anthropic returned the initials
    /// "AU", OpenAI returns "Personal org for you@example.com". Printing those
    /// beside an account adds a cryptic token and no information. A real shared
    /// organisation is worth showing; an echo of the account holder is not.
    var usefulOrganizationName: String? {
        guard let raw = organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Too short to read as a name. "AU" tells you nothing you did not know.
        guard raw.count > 3 else { return nil }
        // An auto-generated personal organisation, under either provider's
        // naming convention.
        if raw.lowercased().hasPrefix("personal org") { return nil }
        // Embeds an address — which is already the account's name.
        if raw.contains("@") { return nil }
        // Named after the account holder rather than after an organisation.
        if let person = personName, raw.caseInsensitiveCompare(person) == .orderedSame { return nil }
        if let email = email {
            if raw.caseInsensitiveCompare(email) == .orderedSame { return nil }
            let local = email.prefix { $0 != "@" }
            if !local.isEmpty, raw.caseInsensitiveCompare(String(local)) == .orderedSame { return nil }
        }
        return raw
    }

    /// Secondary metadata for the line under an account's name, e.g.
    /// "Plan: Pro · Acme Inc". Never the identity itself.
    var subtitle: String? {
        var parts: [String] = []
        if let plan = planLabel { parts.append("Plan: \(plan)") }
        if let org = usefulOrganizationName { parts.append(org) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// How an account is named in the menu, the menu bar and settings.
///
/// The user's first question is always "which account is this", so the e-mail
/// leads and the plan is secondary. A name the user typed always wins.
enum AccountNaming {

    static let unidentifiedSuffix = "(Unidentified account)"

    static func displayName(provider: ProviderKind,
                            identity: AccountIdentity?,
                            custom: String?) -> String {
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        guard let email = identity?.email else {
            // No invented name and no counter: say plainly that we could not
            // confirm who this is.
            return "\(provider.displayName) \(unidentifiedSuffix)"
        }
        // OpenAI plans distinguish two accounts that may share nothing else
        // visible, so the plan earns a place in the name there.
        if provider == .openAI, let plan = identity?.planLabel {
            return "OpenAI — \(plan) (\(email))"
        }
        return "\(provider.displayName) (\(email))"
    }

    /// Names this app generated for itself in an earlier version.
    ///
    /// Used when loading a stored account: an auto-generated name should give
    /// way to a real identity, while a name the user actually chose must
    /// survive. A name containing an "@" is treated as deliberate.
    static func isAutoGenerated(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("@") { return false }
        for provider in ProviderKind.allCases {
            let p = provider.displayName
            if trimmed == "\(p) \(unidentifiedSuffix)" { return true }
            // "Claude Account 1", "OpenAI Account 2"
            if trimmed.hasPrefix("\(p) Account "),
               Int(trimmed.dropFirst("\(p) Account ".count)) != nil { return true }
            // "Claude (pro)", "OpenAI (Self Serve Business Prolite)" — the plan
            // names an earlier version used before identity detection existed.
            if trimmed.hasPrefix("\(p) ("), trimmed.hasSuffix(")") { return true }
        }
        return false
    }
}
