import SwiftUI

// Placeholders of the first build round: replaced by Home-network features (transfer, remote) and downloads.

struct TransferView: View {
    var body: some View { StateMessage(icon: "arrow.left.arrow.right", title: "Copia e invio dei profili", text: "In preparazione.").nxPage().navigationTitle("Profili tra dispositivi") }
}

struct RemoteView: View {
    var body: some View { StateMessage(icon: "appletvremote.gen4", title: "Telecomando della TV", text: "In preparazione.").nxPage().navigationTitle("Telecomando") }
}

struct DownloadsView: View {
    var body: some View { StateMessage(icon: "arrow.down.circle", title: "Download", text: "In preparazione.").nxPage().navigationTitle("Download") }
}

#if os(iOS)
struct DownloadButton: View {
    let request: PlayRequest
    var compact = false
    var body: some View { EmptyView() }
}

struct OfflineDownloadsGate: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack { DownloadsView(); NxButton("Indietro", kind: .quiet) { app.offlineDownloads = false } }.nxPage()
    }
}
#endif
