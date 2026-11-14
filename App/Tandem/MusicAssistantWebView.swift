import SwiftUI
import WebKit

/// Music Assistant's own web interface, for what the app's library screens don't cover: the
/// queue, settings, other players.
struct MusicAssistantWebView: View {
    let url: URL

    var body: some View {
        WebView(url: url)
            .navigationTitle("Music Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

/// A web view that loads `url` once, and again only when the URL itself changes, so that
/// navigating inside the page survives SwiftUI updates.
private struct WebView {
    let url: URL

    final class Coordinator {
        var loaded: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The page can act as a player itself; it shouldn't start sound on its own.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    @MainActor func load(in view: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.loaded != url else { return }
        coordinator.loaded = url
        view.load(URLRequest(url: url))
    }
}

#if os(iOS)
extension WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { load(in: view, context.coordinator) }
}
#else
extension WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { load(in: view, context.coordinator) }
}
#endif
