import CoreText
import Foundation

/// Approximates how wide titles and descriptions render in Google's desktop results, which use
/// Arial at 20px for titles and 14px for snippets. Google truncates titles around 580px and
/// descriptions around 990px; the audit uses slightly conservative thresholds.
public enum PixelWidth {
    public static let titleLimit: Double = 561
    public static let titleMinimum: Double = 200
    public static let descriptionLimit: Double = 985
    public static let descriptionMinimum: Double = 400

    // CTFont is an immutable CF type and safe to share across threads.
    nonisolated(unsafe) private static let titleFont = CTFontCreateWithName("Arial" as CFString, 20, nil)
    nonisolated(unsafe) private static let descriptionFont = CTFontCreateWithName("Arial" as CFString, 14, nil)

    public static func title(_ text: String) -> Double {
        measure(text, font: titleFont)
    }

    public static func description(_ text: String) -> Double {
        measure(text, font: descriptionFont)
    }

    private static func measure(_ text: String, font: CTFont) -> Double {
        guard !text.isEmpty else { return 0 }
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return (CTLineGetTypographicBounds(line, nil, nil, nil) * 10).rounded() / 10
    }
}
