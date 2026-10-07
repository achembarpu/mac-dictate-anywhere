import Foundation

/// The optional environment field persists names only; credential literals belong in Keychain.
enum OpenRouterCredentialPreferences {
    static let preferenceKey = "openRouterAPIKeyEnvironmentVariable"
    static let saveError = "Could not save the API key to Keychain. Try entering it again."

    static func isKey(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sk-or-")
    }

    static func environmentName(for input: String, storeKey: (String) -> Void) -> String {
        guard isKey(input) else { return input }
        storeKey(input.trimmingCharacters(in: .whitespacesAndNewlines))
        return OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable
    }

    struct Migration {
        let apiKey: String
        let environmentName: String
        let error: String?
    }

    static func migrate(defaults: UserDefaults, storedKey: String, writeKey: (String) -> Bool) -> Migration {
        let fallback = OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable
        let hint = defaults.string(forKey: preferenceKey) ?? fallback
        guard isKey(hint) else {
            return Migration(apiKey: storedKey, environmentName: hint, error: nil)
        }
        // Never overwrite an existing Keychain credential with an obsolete preference.
        let key = storedKey.isEmpty ? hint.trimmingCharacters(in: .whitespacesAndNewlines) : storedKey
        guard !storedKey.isEmpty || writeKey(key) else {
            // Keep the sole recoverable copy until Keychain succeeds, but only display
            // it in the secure API-key field. A later successful key edit scrubs it.
            return Migration(apiKey: key, environmentName: fallback, error: saveError)
        }
        defaults.set(fallback, forKey: preferenceKey)
        return Migration(apiKey: key, environmentName: fallback, error: nil)
    }

    static func removeLegacyKey(from defaults: UserDefaults) {
        guard let hint = defaults.string(forKey: preferenceKey), isKey(hint) else { return }
        defaults.set(OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable, forKey: preferenceKey)
    }
}
