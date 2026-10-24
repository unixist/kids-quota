import Foundation
import Darwin

/// Domain rules are DNS label matches. No request-to-IP attribution is involved.
public enum DomainMatcher {
    public static func canonicalHostname(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("*"), !value.contains("\\"),
              let components = URLComponents(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              var hostname = components.url?.host?.lowercased() else {
            throw QuotaError.invalidPolicy("Enter a website hostname, such as example.org.")
        }
        if hostname.hasSuffix(".") { hostname.removeLast() }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard hostname.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else {
            throw QuotaError.invalidPolicy("Invalid website hostname.")
        }
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        guard inet_pton(AF_INET, hostname, &ipv4) != 1,
              inet_pton(AF_INET6, hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &ipv6) != 1,
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              !PublicSuffixes.shared.isPublicSuffix(hostname) else {
            throw QuotaError.invalidPolicy("Choose a website, not an IP address or public suffix.")
        }
        return hostname
    }

    public static func matches(hostname: String, rule: DomainRule) -> Bool {
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = rule.hostname.lowercased()
        return host == domain || (rule.includeSubdomains && host.hasSuffix("." + domain))
    }

    public static func overlaps(_ first: DomainRule, _ second: DomainRule) -> Bool {
        matches(hostname: first.hostname, rule: second) || matches(hostname: second.hostname, rule: first)
    }

    private struct PublicSuffixes {
        static let shared = PublicSuffixes()
        let exact: Set<String>
        let wildcards: Set<String>
        let exceptions: Set<String>

        init() {
            // Bundled and versioned with the application; runtime validation never
            // depends on fetching the list or on availability of the network.
            let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat")!
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var exact = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
            for line in content.split(separator: "\n") {
                let rule = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if rule.isEmpty || rule.hasPrefix("//") { continue }
                let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
                let bare = String(rule.dropFirst(prefix.count))
                guard let ascii = URL(string: "https://" + bare)?.host?.lowercased() else { continue }
                if prefix == "!" { exceptions.insert(ascii) }
                else if prefix == "*." { wildcards.insert(ascii) }
                else { exact.insert(ascii) }
            }
            // Fail safely for the common multi-label suffixes if the resource
            // becomes unreadable. Release tests also assert the full list exists.
            exact.formUnion(["co.uk", "com.au", "co.nz", "github.io", "appspot.com"])
            self.exact = exact; self.wildcards = wildcards; self.exceptions = exceptions
        }

        func isPublicSuffix(_ hostname: String) -> Bool {
            let labels = hostname.split(separator: ".").map(String.init)
            var suffixCount = 1
            for offset in labels.indices {
                let suffix = labels[offset...].joined(separator: ".")
                let count = labels.count - offset
                if exceptions.contains(suffix) { return labels.count == count - 1 }
                if exact.contains(suffix) { suffixCount = max(suffixCount, count) }
                if offset > 0 && wildcards.contains(suffix) { suffixCount = max(suffixCount, count + 1) }
            }
            return labels.count == suffixCount
        }
    }
}
