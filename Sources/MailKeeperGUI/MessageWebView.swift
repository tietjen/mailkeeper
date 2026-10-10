import AppKit
import MailKeeperKit
import Observation
import SwiftUI
import WebKit

/// Renders a mail's HTML in a locked-down WKWebView (ADR-0003): no JavaScript, no persistent
/// website data, every network load blocked by a content rule list and a CSP; inline images
/// (`cid:`) come from the message itself through a custom scheme. Links open in the browser
/// only on an explicit click.
struct MessageWebView: NSViewRepresentable {
    let html: String
    let message: ParsedMessage
    /// Required: the view never exists without the blocking rules.
    let rules: WKContentRuleList

    static let scheme = "mk-cid"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator.cidHandler, forURLScheme: Self.scheme)
        config.userContentController.add(rules)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let document = Self.wrap(html)
        guard context.coordinator.loaded != document else { return }
        context.coordinator.loaded = document
        context.coordinator.cidHandler.message = message
        view.loadHTMLString(document, baseURL: nil)
    }

    /// CSP first (defence in depth next to the rule list), `cid:` rewritten to our scheme.
    static func wrap(_ html: String) -> String {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src \(scheme): data:; style-src 'unsafe-inline'; font-src data:\">"
            + "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"  // link hosts must not leak via DNS
        let base = "<meta name=\"color-scheme\" content=\"light dark\"><style>body{font:13px -apple-system,sans-serif;margin:12px;word-wrap:break-word}</style>"
        let rewritten = html.replacingOccurrences(of: "cid:", with: "\(scheme):", options: .caseInsensitive)
        return csp + base + rewritten
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: String?
        let cidHandler = CIDSchemeHandler()

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .other, action.request.url?.scheme == "about" || action.request.url == nil {
                return .allow  // the initial loadHTMLString
            }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        /// `target="_blank"` links: open in the browser on click, never a second web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// Serves `mk-cid:<content-id>` from the message's own MIME parts.
@MainActor
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var message: ParsedMessage?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let message,
              let part = Self.find(cid: String(url.absoluteString.dropFirst(MessageWebView.scheme.count + 1)), in: message.root) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = part.decodedBody
        task.didReceive(URLResponse(url: url, mimeType: part.contentType, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func find(cid raw: String, in part: MIMEPart) -> MIMEPart? {
        let cid = "<" + (raw.removingPercentEncoding ?? raw) + ">"
        if part.contentID?.caseInsensitiveCompare(cid) == .orderedSame { return part }
        for child in part.children {
            if let hit = find(cid: raw, in: child) { return hit }
        }
        return nil
    }
}

/// Compiled once at launch: block every load except our scheme and data: URIs. Until it is
/// ready the reader shows plain text, never unprotected HTML.
@MainActor @Observable
final class ContentRules {
    static let shared = ContentRules()
    private(set) var list: WKContentRuleList?

    func compile() async {
        let json = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^\(MessageWebView.scheme):"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:blank"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
        list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mailkeeper-block-remote", encodedContentRuleList: json)
    }
}
