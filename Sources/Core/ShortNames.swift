import Foundation

/// Short, non-sensitive aliases for the menu bar.
///
/// The full, provider-confirmed name stays canonical everywhere identity
/// matters — the dropdown, the settings list, notifications. The menu bar gets
/// an alias instead, because a row of e-mail addresses up there would be both
/// unreadable and a small privacy leak to anyone glancing at the screen.
enum ShortName {

    static let maximumLength = 14

    /// A sensible starting alias for an account, derived from what the provider
    /// told us. Only ever a default: the user can type their own.
    ///
    /// The two providers get different rules because different things
    /// distinguish their accounts. Two Claude accounts usually share a plan, so
    /// the e-mail is what tells them apart. Two OpenAI accounts are most often
    /// a work plan and a personal one, so the plan is the more useful label and
    /// the e-mail is the fallback.
    static func derive(provider: ProviderKind, identity: AccountIdentity?) -> String {
        switch provider {
        case .claude:
            return fromEmail(identity?.email)
                ?? identity?.planLabel
                ?? provider.displayName
        case .openAI:
            return identity?.planLabel
                ?? fromEmail(identity?.email)
                ?? provider.displayName
        }
    }

    /// "starlogic@gmail.com" → "Starlogic"; "john.doe@example.com" → "John".
    ///
    /// Only the first segment of the local part is used: an alias earns its
    /// place in the menu bar by being short. Capitalisation of a run-together
    /// address like "starlogic" cannot be recovered, so it is left for the user
    /// to correct if they care.
    static func fromEmail(_ email: String?) -> String? {
        // `prefix(while:)` rather than `split`, which drops empty fields and
        // would treat "@example.com" as if the domain were the local part.
        guard let email = email else { return nil }
        let local = email.prefix { $0 != "@" }
        guard !local.isEmpty else { return nil }
        let segment = local.split(whereSeparator: { ".-_+".contains($0) }).first ?? local
        let cleaned = segment.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return nil }
        return capitalisedFirst(String(cleaned.prefix(maximumLength)))
    }

    private static func capitalisedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Shortest prefixes of `names` that stay unambiguous.
    ///
    /// Two names only collide when they also share a `group`, so an alias may
    /// safely repeat across providers when the rendered label carries a
    /// provider prefix — "C-B" and "G-B" are not ambiguous. Pass a constant
    /// group to make every name compete with every other, which is what the
    /// format without a provider prefix needs.
    ///
    /// Deterministic and order-stable: the same accounts always produce the
    /// same labels, so the menu bar does not reshuffle itself between refreshes.
    static func uniqueAbbreviations(_ names: [String], groups: [String]) -> [String] {
        precondition(names.count == groups.count)
        guard !names.isEmpty else { return [] }

        var result: [String] = []
        for (i, name) in names.enumerated() {
            let characters = Array(name)
            guard !characters.isEmpty else { result.append("?"); continue }

            // Grow the prefix until nothing else in the same group shares it.
            var length = 1
            while length < characters.count {
                let candidate = String(characters.prefix(length)).lowercased()
                let collides = names.indices.contains { j in
                    j != i && groups[j] == groups[i]
                        && String(Array(names[j]).prefix(length)).lowercased() == candidate
                }
                if !collides { break }
                length += 1
            }
            result.append(capitalisedFirst(String(characters.prefix(length))))
        }

        // Names that are genuinely identical cannot be separated by a prefix.
        // Numbering them is ugly, but an ambiguous menu bar is worse.
        var seen: [String: Int] = [:]
        for i in result.indices {
            let key = "\(groups[i])|\(result[i].lowercased())"
            seen[key, default: 0] += 1
            if seen[key]! > 1 { result[i] += "\(seen[key]!)" }
        }
        return result
    }
}
