import SwiftUI
import MediaCore

struct FollowingView: View {
    @ObservedObject var model: Downloader
    let onDownloadAll: (String) -> Void

    @ObservedObject private var session = RedditSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [String]?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !session.hasSession {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text(L("Connecte-toi à Reddit dans les Réglages pour voir les comptes que tu suis.",
                               "Sign in to Reddit in Settings to see the accounts you follow."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else if loading || (friends == nil && errorMessage == nil) {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L("Chargement des suivis…", "Loading followed accounts…"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36)).foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L("Réessayer", "Retry")) { retryCount += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                } else if let friends {
                    if friends.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .font(.system(size: 40)).foregroundStyle(.tertiary)
                            Text(L("Aucun compte suivi (ou liste privée indisponible).",
                                   "No followed accounts (or the list is unavailable)."))
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    } else {
                        List {
                            ForEach(friends, id: \.self) { name in
                                HStack(spacing: 10) {
                                    NavigationLink {
                                        FollowingUserPosts(username: name, model: model, onDownloadAll: onDownloadAll)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "person.crop.circle.fill")
                                                .font(.title3).foregroundStyle(.orange)
                                            Text(name).fontWeight(.medium).lineLimit(1)
                                        }
                                    }
                                    Button {
                                        onDownloadAll(name)
                                    } label: {
                                        Image(systemName: "arrow.down.circle").font(.title3)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(model.running)
                                    .accessibilityLabel(L("Tout télécharger de \(name)", "Download all from \(name)"))
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle(L("Suivis", "Following"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
            }
        }
        .tint(.orange)
        .task(id: "\(session.hasSession)-\(retryCount)") {
            if session.hasSession, friends == nil { await load() }
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let result = try await model.followedUsers()
            try Task.checkCancellation()
            friends = result
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct FollowingUserPosts: View {
    let username: String
    @ObservedObject var model: Downloader
    let onDownloadAll: (String) -> Void

    @State private var posts: [Post]?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0

    var body: some View {
        // Keep a concrete container alive while state changes so the loading
        // task and navigation modifiers never depend on an empty Group.
        VStack(spacing: 0) {
            if loading || (posts == nil && errorMessage == nil) {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("Lecture des posts…", "Loading posts…"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36)).foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L("Réessayer", "Retry")) { retryCount += 1 }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
            } else if let posts {
                if posts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text(L("Aucun post accessible (flux privé ou vide).",
                               "No accessible posts (private or empty feed)."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else {
                    List(posts) { post in
                        postRow(post)
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("u/\(username)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onDownloadAll(username)
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title3)
                }
                .disabled(model.running)
                .accessibilityLabel(L("Tout télécharger", "Download all"))
            }
        }
        .task(id: retryCount) {
            if posts == nil { await load() }
        }
    }

    private func postRow(_ post: Post) -> some View {
        let media = MediaExtractor.extract(post.html)
        return VStack(alignment: .leading, spacing: 4) {
            Text(post.title).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack(spacing: 8) {
                if let date = post.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if media.isEmpty {
                    Label(L("Sans média", "No media"), systemImage: "slash.circle")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Label(L("\(media.count) média\(media.count > 1 ? "s" : "")",
                            "\(media.count) media file\(media.count > 1 ? "s" : "")"),
                          systemImage: media.contains(where: mediaIsVideo) ? "video" : "photo")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func mediaIsVideo(_ media: Media) -> Bool {
        switch media {
        case .redditVideo, .redgifs: return true
        case .direct(let url): return isVideo(url)
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let result = try await model.previewPosts(username: username)
            try Task.checkCancellation()
            posts = result
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
