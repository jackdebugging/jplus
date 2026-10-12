import Foundation

/// Enough of JQL for the demo: the queries the app builds (My Issues,
/// Mentions, search, versions, child issues, the search index) and the
/// simple ones a reviewer might type. Clauses on fields the demo doesn't
/// know match everything rather than failing.
nonisolated struct DemoJQL {
    indirect enum Expr {
        case and([Expr])
        case or([Expr])
        case not(Expr)
        case clause(field: String, op: String, values: [String])
        case all
    }

    let filter: Expr
    let order: [(field: String, ascending: Bool)]

    init(_ text: String) {
        var parser = Parser(tokens: Self.tokenize(text))
        filter = parser.parseQuery()
        order = parser.parseOrder()
    }

    // MARK: Evaluation

    func matches(_ issue: DemoIssue, in state: DemoState, currentUser: String) -> Bool {
        evaluate(filter, issue, state, currentUser)
    }

    func sorted(_ issues: [DemoIssue], in state: DemoState) -> [DemoIssue] {
        let keys: [(field: String, ascending: Bool)] = order.isEmpty ? [(field: "created", ascending: false)] : order
        return issues.sorted { lhs, rhs in
            for (field, ascending) in keys {
                let result = compare(lhs, rhs, field: field, state: state)
                if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
            }
            return lhs.key < rhs.key
        }
    }

    private func compare(_ lhs: DemoIssue, _ rhs: DemoIssue, field: String, state: DemoState) -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame) }
        switch field {
        case "updated": return order(lhs.updated, rhs.updated)
        case "created": return order(lhs.created, rhs.created)
        case "key", "issuekey", "id":
            return lhs.projectKey == rhs.projectKey ? order(lhs.number, rhs.number) : order(lhs.projectKey, rhs.projectKey)
        case "priority":
            // Jira sorts priority by its position, highest first for DESC.
            let rank = { (name: String) in state.priorities.count - (state.priorities.firstIndex(of: name) ?? state.priorities.count) }
            return order(rank(lhs.priority), rank(rhs.priority))
        case "rank": return order(lhs.rank, rhs.rank)
        case "summary": return lhs.summary.localizedStandardCompare(rhs.summary)
        case "status": return lhs.status.localizedStandardCompare(rhs.status)
        default: return .orderedSame
        }
    }

    private func evaluate(_ expr: Expr, _ issue: DemoIssue, _ state: DemoState, _ me: String) -> Bool {
        switch expr {
        case .all: return true
        case .and(let parts): return parts.allSatisfy { evaluate($0, issue, state, me) }
        case .or(let parts): return parts.contains { evaluate($0, issue, state, me) }
        case .not(let inner): return !evaluate(inner, issue, state, me)
        case .clause(let field, let op, let values): return clause(field, op, values, issue, state, me)
        }
    }

    private func clause(_ field: String, _ op: String, _ values: [String], _ issue: DemoIssue, _ state: DemoState, _ me: String) -> Bool {
        let negative = op == "!=" || op == "not in" || op == "is not" || op == "!~"
        let lowered = values.map { $0.lowercased() }
        let isEmptyTest = lowered.contains("empty") || lowered.contains("null")

        /// Equality against one or more of the issue's values.
        func equals(_ candidates: [String]) -> Bool {
            if isEmptyTest && (op == "is" || op == "is not" || op == "=" || op == "!=") {
                let empty = candidates.isEmpty
                return negative ? !empty : empty
            }
            let set = Set(candidates.map { $0.lowercased() })
            let hit = lowered.contains { set.contains($0) }
            return negative ? !hit : hit
        }

        func user(_ id: String?) -> [String] {
            guard let id, let user = state.users.first(where: { $0.id == id }) else { return [] }
            return [user.id, user.name, user.email]
        }

        switch field {
        case "project":
            let project = state.projects.first { $0.key == issue.projectKey }
            return equals([issue.projectKey] + (project.map { [$0.name, $0.id] } ?? []))
        case "key", "issuekey", "id":
            return equals([issue.key, String(issue.id)])
        case "assignee", "reporter", "creator", "watcher":
            let resolved = values.map { $0.lowercased() == "currentuser()" ? me : $0 }
            let ids: [String]
            switch field {
            case "assignee": ids = issue.assignee.map { [$0] } ?? []
            case "watcher": ids = issue.watchers
            default: ids = [issue.reporter]
            }
            if isEmptyTest { return equals(ids) }
            let hit = ids.contains { id in
                let names = Set(user(id).map { $0.lowercased() })
                return resolved.contains { names.contains($0.lowercased()) }
            }
            return negative ? !hit : hit
        case "resolution":
            let done = state.statuses.first { $0.name == issue.status }?.category == "done"
            let wantsUnresolved = lowered.contains("unresolved") || isEmptyTest
            let hit = wantsUnresolved ? !done : done
            return negative ? !hit : hit
        case "status":
            return equals([issue.status])
        case "statuscategory":
            let category = state.statuses.first { $0.name == issue.status }?.category ?? "new"
            let names: [String] = switch category {
            case "done": ["done", "complete"]
            case "indeterminate": ["in progress", "indeterminate"]
            default: ["to do", "new"]
            }
            return equals(names)
        case "issuetype", "type":
            return equals([issue.type])
        case "fixversion":
            let names = issue.fixVersions.flatMap { id in [id] + state.versions.filter { $0.id == id }.map(\.name) }
            return equals(issue.fixVersions.isEmpty ? [] : names)
        case "parent":
            return equals(issue.parent.map { [$0] } ?? [])
        case "priority":
            return equals([issue.priority])
        case "labels":
            return equals(issue.labels)
        case "component":
            return equals(issue.components)
        case "team":
            let team = state.teams.first { $0.id == issue.team }
            return equals(team.map { [$0.id, $0.name] } ?? [])
        case "text", "summary", "description", "comment":
            if lowered.first == "currentuser()" {
                let hit = ADF.mentions(issue.description, user: me) || issue.comments.contains { ADF.mentions($0.body, user: me) }
                return negative ? !hit : hit
            }
            var haystack = ""
            if field == "text" || field == "summary" { haystack += issue.summary + " " }
            if field == "text" || field == "description" { haystack += ADF.plainText(issue.description) + " " }
            if field == "text" || field == "comment" { haystack += issue.comments.map { ADF.plainText($0.body) }.joined(separator: " ") }
            if field == "text" { haystack += " " + issue.key }
            haystack = haystack.lowercased()
            let words = values.joined(separator: " ").lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*?\"'")) }
                .filter { !$0.isEmpty }
            let hit = !words.isEmpty && words.allSatisfy { haystack.contains($0) }
            return negative ? !hit : hit
        case "created", "updated":
            let date = field == "created" ? issue.created : issue.updated
            if isEmptyTest { return op == "is not" || op == "!=" }
            guard let value = values.first, let bound = Self.date(value) else { return true }
            switch op {
            case ">=": return date >= bound
            case ">": return date > bound
            case "<=": return date <= bound
            case "<": return date < bound
            case "=": return Calendar.current.isDate(date, inSameDayAs: bound)
            case "!=": return !Calendar.current.isDate(date, inSameDayAs: bound)
            default: return true
            }
        default:
            return true
        }
    }

    /// "-7d", "-2w", "-3h", "startOfDay()", "now()", "2026-10-01", "2026-10-01 14:30".
    static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let now = Date()
        if text == "now()" { return now }
        if text.hasPrefix("startofday") { return Calendar.current.startOfDay(for: now) }
        if text.hasPrefix("startofweek") { return Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start }
        if let match = text.wholeMatch(of: /([-+]?\d+)\s*([mhdw])/), let amount = Double(match.1) {
            let unit: Double = switch match.2 { case "m": 60; case "h": 3_600; case "w": 604_800; default: 86_400 }
            return now.addingTimeInterval(amount * unit)
        }
        for format in ["yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    // MARK: Parsing

    enum Token: Equatable {
        case word(String)
        case string(String)
        case symbol(String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "\"" || c == "'" {
                var value = ""
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i]); i += 1
                }
                i += 1
                tokens.append(.string(value))
                continue
            }
            if "(),".contains(c) { tokens.append(.symbol(String(c))); i += 1; continue }
            if "=!~<>".contains(c) {
                var op = String(c)
                if i + 1 < chars.count, "=~".contains(chars[i + 1]) { op.append(chars[i + 1]); i += 1 }
                tokens.append(.symbol(op)); i += 1
                continue
            }
            var word = ""
            while i < chars.count, !chars[i].isWhitespace, !"(),=!~<>\"'".contains(chars[i]) {
                word.append(chars[i]); i += 1
            }
            // Functions such as currentUser() stay one word.
            if i + 1 < chars.count, chars[i] == "(" {
                var j = i + 1
                var args = ""
                while j < chars.count, chars[j] != ")" { args.append(chars[j]); j += 1 }
                if j < chars.count, !args.contains(",") {
                    word += "(" + args + ")"
                    i = j + 1
                }
            }
            tokens.append(.word(word))
        }
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        var index = 0

        private var current: Token? { index < tokens.count ? tokens[index] : nil }

        private func isWord(_ token: Token?, _ word: String) -> Bool {
            if case .word(let value)? = token { return value.caseInsensitiveCompare(word) == .orderedSame }
            return false
        }

        private var atOrderBy: Bool { isWord(current, "order") && isWord(index + 1 < tokens.count ? tokens[index + 1] : nil, "by") }

        mutating func parseQuery() -> Expr {
            guard current != nil, !atOrderBy else { return .all }
            return parseOr()
        }

        private mutating func parseOr() -> Expr {
            var parts = [parseAnd()]
            while isWord(current, "or") { index += 1; parts.append(parseAnd()) }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        private mutating func parseAnd() -> Expr {
            var parts = [parseNot()]
            while isWord(current, "and") { index += 1; parts.append(parseNot()) }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        private mutating func parseNot() -> Expr {
            if isWord(current, "not") { index += 1; return .not(parseNot()) }
            if current == .symbol("(") {
                index += 1
                let inner = parseOr()
                if current == .symbol(")") { index += 1 }
                return inner
            }
            return parseClause()
        }

        private mutating func parseClause() -> Expr {
            guard let fieldToken = current, !atOrderBy else { return .all }
            index += 1
            let field: String
            switch fieldToken {
            case .word(let value), .string(let value): field = value.lowercased()
            case .symbol: return .all
            }

            var op = ""
            if case .symbol(let symbol)? = current, symbol != "(" && symbol != ")" && symbol != "," {
                op = symbol; index += 1
            } else if isWord(current, "in") {
                op = "in"; index += 1
            } else if isWord(current, "not"), isWord(index + 1 < tokens.count ? tokens[index + 1] : nil, "in") {
                op = "not in"; index += 2
            } else if isWord(current, "is") {
                index += 1
                if isWord(current, "not") { op = "is not"; index += 1 } else { op = "is" }
            } else {
                return .all
            }

            var values: [String] = []
            if current == .symbol("(") {
                index += 1
                while let token = current, token != .symbol(")") {
                    if case .word(let value) = token { values.append(value) }
                    if case .string(let value) = token { values.append(value) }
                    index += 1
                }
                index += 1
            } else if let token = current {
                switch token {
                case .word(let value), .string(let value): values.append(value)
                case .symbol: break
                }
                index += 1
            }
            return .clause(field: field, op: op.lowercased(), values: values)
        }

        mutating func parseOrder() -> [(field: String, ascending: Bool)] {
            guard atOrderBy else { return [] }
            index += 2
            var order: [(String, Bool)] = []
            while let token = current {
                guard case .word(let field) = token else { index += 1; continue }
                index += 1
                var ascending = true
                if isWord(current, "desc") { ascending = false; index += 1 } else if isWord(current, "asc") { index += 1 }
                order.append((field.lowercased(), ascending))
                if current == .symbol(",") { index += 1 }
            }
            return order
        }
    }
}
