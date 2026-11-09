import Foundation

/// Something in selected text that has a quick action, found on this Mac with `NSDataDetector` and a
/// package-tracking pattern. Nothing is sent anywhere to detect it.
public enum DetectedItem: Equatable, Sendable {
    case email(String)
    case phone(String)
    case address(String)
    case link(URL)
    case date(Date, allDay: Bool, text: String)
    case tracking(String)
}

/// A quick action for detected text, like the chips Google Lens shows under selected text.
public struct TextQuickAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A system URL (mail, phone, messages or Apple Maps) opened with its default app.
        case system(URL)
        /// A web page, opened in the browser chosen in Settings.
        case website(URL)
        case contact(ContactCard)
        case calendar(CalendarEvent)
        /// A Google search for the number; sending it needs the same consent as Search.
        case track(String)
    }

    public let title: String
    public let symbol: String
    public let kind: Kind
}

public enum DataDetection {
    public static func items(in text: String) -> [DetectedItem] {
        var items: [DetectedItem] = []
        func add(_ item: DetectedItem) { if !items.contains(item) { items.append(item) } }
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address, .date]
        let range = NSRange(text.startIndex..., in: text)
        let tracking = trackingNumbers(in: text)
        if let detector = try? NSDataDetector(types: types.rawValue) {
            for match in detector.matches(in: text, range: range) {
                guard let matched = Range(match.range, in: text) else { continue }
                let value = String(text[matched])
                switch match.resultType {
                case .link:
                    guard let url = match.url else { continue }
                    if url.scheme?.lowercased() == "mailto" {
                        add(.email(String(url.absoluteString.dropFirst("mailto:".count))
                            .removingPercentEncoding ?? value))
                    } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        add(.link(url))
                    }
                case .phoneNumber:
                    let digits = value.filter(\.isNumber)
                    // Package numbers are long digit runs that also look like phone numbers.
                    guard digits.count >= 6, !tracking.contains(where: { $0.filter(\.isNumber) == digits }) else { continue }
                    add(.phone(match.phoneNumber ?? value))
                case .address:
                    add(.address(value.split(whereSeparator: \.isNewline).joined(separator: ", ")))
                case .date:
                    guard let date = match.date else { continue }
                    add(.date(date, allDay: !mentionsTime(value), text: value))
                default:
                    continue
                }
            }
        }
        tracking.forEach { add(.tracking($0)) }
        return items
    }

    /// Actions for detected items: getting in touch first, then one contact card with every email, phone and
    /// address, then places, websites, dates and packages.
    public static func actions(for items: [DetectedItem], selectedText: String) -> [TextQuickAction] {
        var contact: [TextQuickAction] = [], places: [TextQuickAction] = [], links: [TextQuickAction] = []
        var dates: [TextQuickAction] = [], packages: [TextQuickAction] = []
        var card = ContactCard()
        for item in items {
            switch item {
            case .email(let address):
                if let url = mailURL(address) {
                    contact.append(TextQuickAction(title: "Send email", symbol: "envelope", kind: .system(url)))
                }
                card.emails.append(address)
            case .phone(let number):
                if let call = phoneURL(number, scheme: "tel"), let text = phoneURL(number, scheme: "sms") {
                    contact.append(TextQuickAction(title: "Call", symbol: "phone", kind: .system(call)))
                    contact.append(TextQuickAction(title: "Text", symbol: "message", kind: .system(text)))
                }
                card.phones.append(number)
            case .address(let address):
                if let url = mapsURL(address) {
                    places.append(TextQuickAction(title: "Maps", symbol: "map", kind: .system(url)))
                }
                card.addresses.append(address)
            case .link(let url):
                links.append(TextQuickAction(title: "Open website", symbol: "safari", kind: .website(url)))
            case .date(let date, let allDay, let text):
                let event = CalendarEvent(title: CalendarEvent.title(from: selectedText, fallback: text), start: date,
                                          allDay: allDay, notes: selectedText)
                dates.append(TextQuickAction(title: "Add to calendar", symbol: "calendar.badge.plus", kind: .calendar(event)))
            case .tracking(let number):
                packages.append(TextQuickAction(title: "Track package", symbol: "shippingbox", kind: .track(number)))
            }
        }
        if !card.isEmpty {
            contact.append(TextQuickAction(title: "Add to contacts", symbol: "person.crop.circle.badge.plus",
                                           kind: .contact(card)))
        }
        return contact + places + links + dates + packages
    }

    public static func mailURL(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !trimmed.contains(where: { $0.isWhitespace || "?&#/".contains($0) }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = trimmed
        return components.url
    }

    /// `tel:` or `sms:` with only the digits and a leading plus, so nothing else in the text reaches the URL.
    public static func phoneURL(_ number: String, scheme: String) -> URL? {
        let digits = number.filter(\.isASCII).filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        return URL(string: "\(scheme):\(plus)\(digits)")
    }

    /// Apple Maps, so looking up an address sends nothing to Google.
    public static func mapsURL(_ address: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        guard let query = address.addingPercentEncoding(withAllowedCharacters: allowed), !query.isEmpty else { return nil }
        return URL(string: "maps://?q=\(query)")
    }

    static func mentionsTime(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}[:.]\d{2}|\b\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)|\bnoon\b|\bmidnight\b|\bo'clock\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Package tracking

    /// UPS, USPS, FedEx, DHL and Universal Postal Union (S10) numbers. Bare digit runs count only when the text
    /// mentions tracking or a carrier, because they are otherwise indistinguishable from other numbers.
    public static func trackingNumbers(in text: String) -> [String] {
        let upper = text.uppercased()
        var found: [String] = []
        func scan(_ pattern: String, accept: (String) -> Bool = { _ in true }) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
                guard let range = Range(match.range, in: upper) else { continue }
                let value = upper[range].filter { !$0.isWhitespace }
                if accept(value), !found.contains(value) { found.append(value) }
            }
        }
        scan(#"\b1Z[0-9A-Z]{16}\b"#)
        scan(#"\b[A-Z]{2}\d{9}[A-Z]{2}\b"#, accept: validS10)
        scan(#"\b9[2-5]\d{18,20}\b"#)
        let mentionsCarrier = upper.range(of: #"TRACK|FEDEX|\bUPS\b|USPS|\bDHL\b|PACKAGE|PARCEL|SHIPMENT"#,
                                          options: .regularExpression) != nil
        if mentionsCarrier {
            scan(#"(?<![\d+\-])(?:\d{10}|\d{12}|\d{15}|\d{20}|\d{22})(?![\d\-])"#)
        }
        return found
    }

    /// The S10 check digit (UPU standard), which rules out most random letter-digit strings.
    static func validS10(_ value: String) -> Bool {
        let digits = value.dropFirst(2).prefix(9).compactMap(\.wholeNumberValue)
        guard digits.count == 9 else { return false }
        let weights = [8, 6, 4, 2, 3, 5, 9, 7]
        let sum = zip(digits.prefix(8), weights).map(*).reduce(0, +)
        var check = 11 - sum % 11
        if check == 10 { check = 0 } else if check == 11 { check = 5 }
        return check == digits[8]
    }
}

// MARK: Contacts and calendar files

/// Text-file formats escape backslashes, commas, semicolons and line breaks, and fold long lines (RFC 6350/5545).
enum ContentLines {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Folds lines longer than 75 octets without splitting a character.
    static func fold(_ line: String) -> String {
        var output = "", current = "", octets = 0
        for character in line {
            let size = String(character).utf8.count
            if octets + size > 75 {
                output += current + "\r\n "
                current = ""
                octets = 1
            }
            current.append(character)
            octets += size
        }
        return output + current
    }

    static func join(_ lines: [String]) -> String {
        lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
}

/// A vCard that Contacts opens for the user to review; macOS Lens needs no Contacts permission.
public struct ContactCard: Equatable, Sendable {
    public var emails: [String] = []
    public var phones: [String] = []
    public var addresses: [String] = []

    public init(emails: [String] = [], phones: [String] = [], addresses: [String] = []) {
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
    }

    public var isEmpty: Bool { emails.isEmpty && phones.isEmpty && addresses.isEmpty }

    public var vCard: String {
        let name = emails.first ?? phones.first ?? addresses.first ?? "New contact"
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "N:;;;;", "FN:\(ContentLines.escape(name))"]
        lines += emails.map { "EMAIL;TYPE=INTERNET:\(ContentLines.escape($0))" }
        lines += phones.map { "TEL;TYPE=VOICE:\(ContentLines.escape($0))" }
        lines += addresses.map { "ADR;TYPE=WORK:;;\(ContentLines.escape($0));;;;" }
        lines += ["NOTE:Added from text selected with macOS Lens", "END:VCARD"]
        return ContentLines.join(lines)
    }
}

/// An iCalendar event that Calendar opens for the user to confirm; macOS Lens needs no Calendar permission.
public struct CalendarEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var allDay: Bool
    public var notes: String
    public var duration: TimeInterval = 3600

    public init(title: String, start: Date, allDay: Bool, notes: String) {
        self.title = title
        self.start = start
        self.allDay = allDay
        self.notes = notes
    }

    /// The first line of the selection that is more than just the date, shortened.
    public static func title(from text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? fallback
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    public func iCalendar(uid: String = UUID().uuidString, stamp: Date = Date(),
                          timeZone: TimeZone = .current) -> String {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = utc.locale
        day.timeZone = timeZone
        day.dateFormat = "yyyyMMdd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let range: [String]
        if allDay {
            let first = calendar.startOfDay(for: start)
            let next = calendar.date(byAdding: .day, value: 1, to: first) ?? first.addingTimeInterval(86_400)
            range = ["DTSTART;VALUE=DATE:\(day.string(from: first))", "DTEND;VALUE=DATE:\(day.string(from: next))"]
        } else {
            range = ["DTSTART:\(utc.string(from: start))", "DTEND:\(utc.string(from: start.addingTimeInterval(duration)))"]
        }
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//macOS Lens//Text selection//EN", "BEGIN:VEVENT",
                     "UID:\(ContentLines.escape(uid))@macos-lens", "DTSTAMP:\(utc.string(from: stamp))"] + range +
                    ["SUMMARY:\(ContentLines.escape(title))", "DESCRIPTION:\(ContentLines.escape(notes))",
                     "END:VEVENT", "END:VCALENDAR"]
        return ContentLines.join(lines)
    }
}
