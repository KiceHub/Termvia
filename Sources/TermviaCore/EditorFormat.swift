import Foundation
import CoreFoundation

public enum EditorEncoding: String, CaseIterable, Sendable {
    case utf8 = "UTF-8", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE", gb18030 = "GB18030", latin1 = "ISO-8859-1", windows1252 = "Windows-1252"
    public var encoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .gb18030: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .latin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        }
    }
    public func decode(_ data: Data) -> String? { String(data: data, encoding: encoding) }
    public func encode(_ text: String) -> Data? { text.data(using: encoding, allowLossyConversion: false) }
}
public enum EditorLineEnding: String, CaseIterable, Sendable {
    case lf = "LF", crlf = "CRLF"
    public func apply(_ text: String) -> String {
        let value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return self == .lf ? value : value.replacingOccurrences(of: "\n", with: "\r\n")
    }
}
