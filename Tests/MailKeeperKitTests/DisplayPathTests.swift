import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Paths as the user sees them")
struct DisplayPathTests {
    @Test func theRealHomeBecomesATildeAndTheContainerStaysVisible() {
        let home = "/Users/jan"
        #expect(DisplayPath.tilde("/Users/jan/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/Logs/MailKeeper/audit.jsonl", home: home)
                == "~/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/Logs/MailKeeper/audit.jsonl")
        #expect(DisplayPath.tilde("/Users/jan/MailKeeperArchiv", home: home + "/") == "~/MailKeeperArchiv")
        #expect(DisplayPath.tilde("/Users/jan", home: home) == "~")
    }

    @Test func otherPathsStayAsTheyAre() {
        let home = "/Users/jan"
        #expect(DisplayPath.tilde("/Users/janine/Archiv", home: home) == "/Users/janine/Archiv")
        #expect(DisplayPath.tilde("/Volumes/Platte/Archiv", home: home) == "/Volumes/Platte/Archiv")
        #expect(DisplayPath.tilde("/Users/jan/Archiv", home: "") == "/Users/jan/Archiv")
    }

    @Test func theRealHomeIsNotTheSandboxContainer() {
        #expect(!DisplayPath.realHome.isEmpty)
        #expect(!DisplayPath.realHome.contains("/Library/Containers/"))
    }
}
