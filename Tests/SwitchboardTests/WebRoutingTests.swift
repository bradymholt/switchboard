import Foundation
import Testing
@testable import Switchboard

struct WebRoutingTests {
    @Test func unwrapsGoogleRedirector() {
        let url = URL(string: "https://www.google.com/url?q=https://app.asana.com/0/1&sa=D")!
        #expect(WebRouting.unwrappingRedirector(url).absoluteString == "https://app.asana.com/0/1")
    }

    @Test func leavesOtherGooglePagesAlone() {
        let url = URL(string: "https://docs.google.com/document/d/abc/edit")!
        #expect(WebRouting.unwrappingRedirector(url) == url)
    }

    @Test func recognizesSignInPages() {
        #expect(WebRouting.isSignInPage(URL(string: "https://accounts.google.com/signin")!))
        #expect(WebRouting.isSignInPage(URL(string: "https://login.microsoftonline.com/common")!))
        #expect(!WebRouting.isSignInPage(URL(string: "https://docs.google.com/document/d/abc")!))
    }

    @Test func treatsGoogleSubdomainsAsSeparateSites() {
        #expect(WebRouting.siteKey("docs.google.com") != WebRouting.siteKey("mail.google.com"))
        #expect(WebRouting.siteKey("ynab.slack.com") == WebRouting.siteKey("files.slack.com"))
        #expect(WebRouting.siteKey("www.bbc.co.uk") == "bbc.co.uk")
    }

    @Test func detectsGoogleAccountSwitch() {
        let current = URL(string: "https://calendar.google.com/calendar/u/0/r")!
        #expect(WebRouting.isGoogleAccountSwitch(to: URL(string: "https://calendar.google.com/calendar/u/0/r?authuser=1")!, from: current))
        #expect(!WebRouting.isGoogleAccountSwitch(to: URL(string: "https://calendar.google.com/calendar/u/0/r/week")!, from: current))
        #expect(!WebRouting.isGoogleAccountSwitch(to: URL(string: "https://docs.google.com/u/1/")!, from: current))
    }
}
