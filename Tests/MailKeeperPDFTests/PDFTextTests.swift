import CoreGraphics
import CoreText
import Foundation
import MailKeeperKit
import Testing
@testable import MailKeeperPDF

/// A PDF with one line of text per page (empty strings give blank pages).
func makePDF(_ pages: [String], userPassword: String? = nil) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    var info: [CFString: Any] = [:]
    if let userPassword {
        info[kCGPDFContextUserPassword] = userPassword
        info[kCGPDFContextOwnerPassword] = "owner-secret"
    }
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for text in pages {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Suite("PDF text extraction (runs only in the service)")
struct PDFTextTests {
    @Test func textOfAllPages() {
        let r = PDFTextExtraction.extract(makePDF(["Kündigung zum 31.12.2024", "Vertragsnummer 4711"]))
        #expect(r.status == .ok)
        #expect(r.text.contains("Kündigung") && r.text.contains("4711"))
    }

    @Test func emptyUserPasswordOpensRealPasswordDoesNot() {
        #expect(PDFTextExtraction.extract(makePDF(["Rechnung"], userPassword: "")).text.contains("Rechnung"))
        #expect(PDFTextExtraction.extract(makePDF(["Geheim"], userPassword: "s3cret")).status == .encrypted)
    }

    @Test func noTextJunkAndLimits() {
        #expect(PDFTextExtraction.extract(makePDF(["", ""])).status == .empty)
        #expect(PDFTextExtraction.extract(Data("hello, not a pdf".utf8)).status == .failed)
        #expect(PDFTextExtraction.extract(Data("%PDF-1.7\n garbage".utf8)).status == .failed)
        let long = PDFTextExtraction.extract(makePDF(Array(repeating: "Seite mit Text", count: 5)), maxPages: 2)
        #expect(long.status == .ok && long.text.components(separatedBy: "Seite").count - 1 == 2 && long.detail == "first 2 of 5 pages")
        #expect(PDFTextExtraction.extract(makePDF(["abcdefghij"]), maxCharacters: 4).text.count == 4)
        // time budget spent: keep the pages read so far (always at least the first)
        let partial = PDFTextExtraction.extract(makePDF(["eins", "zwei", "drei"]), timeBudget: 0)
        #expect(partial.status == .ok && partial.text.contains("eins") && !partial.text.contains("zwei")
                && partial.detail == "first 1 of 3 pages")
    }
}
