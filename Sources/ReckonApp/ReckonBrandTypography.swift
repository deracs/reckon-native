import CoreText
import SwiftUI

/// The bundled Newsreader wordmark registers only in this process, without installing a system font.
@MainActor
enum ReckonBrandTypography {
    static let wordmark: Font = {
        guard let url = Bundle.main.url(forResource: "Newsreader", withExtension: "ttf", subdirectory: "Fonts"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return .system(size: 26, weight: .semibold, design: .serif)
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        // Variable axes: wght = SemiBold; opsz = the displayed point size.
        let variation = [NSNumber(value: 0x77676874): NSNumber(value: 600),
                         NSNumber(value: 0x6F70737A): NSNumber(value: 26)]
        let face = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: variation] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(face, 26, nil))
    }()
}
