import SwiftUI

/// Which editor is open, and for which file.
struct MobileEditRequest: Identifiable {
    enum Kind { case image, video, audio, info }

    let id = UUID()
    let jobID: UUID
    let url: URL
    let kind: Kind

    init(job: Job, kind: Kind) {
        jobID = job.id
        url = job.url
        self.kind = kind
    }

    init(job: Job, editor: Mobile.Editor) {
        let kind: Kind = switch editor {
        case .image: .image
        case .video: .video
        case .audio: .audio
        }
        self.init(job: job, kind: kind)
    }
}

/// Shows the same editors as the Mac app, full screen. Saving runs the edit as a job in the list.
struct EditorHost: View {
    @EnvironmentObject private var queue: JobQueue
    @EnvironmentObject private var library: Library
    let request: MobileEditRequest
    let close: () -> Void

    var body: some View {
        editor
            .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var editor: some View {
        switch request.kind {
        case .image:
            ImageEditorView(url: request.url, onSave: { edit in
                close()
                run(.editImage(edit))
            }, onCancel: close)
        case .video:
            VideoEditorView(url: request.url, onSave: { edit in
                close()
                run(.editVideo(edit))
            }, onSnapshot: { seconds in
                run(.snapshot(seconds: seconds))
            }, onCancel: close)
        case .audio:
            AudioEditorView(url: request.url, onSave: { edit in
                close()
                run(.editAudio(edit))
            }, onCancel: close)
        case .info:
            MetadataEditorView(url: request.url, onSave: { edit in
                close()
                run(.writeMetadata(edit))
            }, onCancel: close)
        }
    }

    private func run(_ operation: JobOperation) {
        queue.start([(request.jobID, operation)], options: library.options, reveal: false)
    }
}
