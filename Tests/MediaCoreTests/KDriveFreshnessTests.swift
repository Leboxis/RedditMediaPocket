import XCTest
@testable import MediaCore

final class KDriveFreshnessTests: XCTestCase {
    // MARK: - Noms de dossiers candidats

    func testCandidateFolderNamesForRedditUserIncludesPrefixedAndLegacyNames() {
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "u/alice"), ["Ualice", "Alice"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "alice"), ["Ualice", "Alice"])
    }

    func testCandidateFolderNamesForOtherPlatforms() {
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "r/pics"), ["Rpics"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "saved/leboxis"), ["Sleboxis"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "tw/nasa"), ["Nasa - X"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "tt/nasa"), ["Nasa - TikTok"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "ts/nasa"), ["Nasa - TikTok Saved"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "ig/nasa"), ["Nasa - Instagram"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "x/modelname"), ["X-Fetish modelname"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "rg/creator_1"), ["Rgcreator_1"])
        XCTAssertEqual(KDriveFreshness.candidateFolderNames(for: "rg/#nature"), ["Rg#nature"])
    }

    // MARK: - Inférence de source depuis un dossier kDrive

    func testInferredSourceFromKDriveFolderNames() {
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Nasa - X"), .twitterUser("Nasa"))
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Nasa - TikTok"), .tiktokUser("nasa"))
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Nasa - TikTok Saved"), .tiktokSaved("nasa"))
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Nasa - Instagram"), .instagramUser("nasa"))
        XCTAssertEqual(
            KDriveFreshness.inferredSource(fromFolderName: "X-Fetish itwasalwaysmysolesvip"),
            .xFetish(XFetishAlbums.Target(model: "itwasalwaysmysolesvip", videos: [], albums: []))
        )
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Rgupset_trash_3094"), .redgifsUser("upset_trash_3094"))
        XCTAssertEqual(KDriveFreshness.inferredSource(fromFolderName: "Rg#blondes"), .redgifsTag("blondes"))
        XCTAssertNil(KDriveFreshness.inferredSource(fromFolderName: "Tiktok - Videos"))
        XCTAssertNil(KDriveFreshness.inferredSource(fromFolderName: "Posts posts"))
        XCTAssertNil(KDriveFreshness.inferredSource(fromFolderName: "RgGif abc123"))
    }

    // MARK: - Extraction des items de source

    func testFromRedditPostsIgnoresTextOnlyPostsAndKeepsMediaAndGalleries() {
        let posts = [
            Post(id: "t3_text01", title: "Pinned text announcement", html: "<p>Just text</p>"),
            Post(id: "t3_img001", title: "Sunset photo", html: #"<a href="https://i.redd.it/abc123.jpg">link</a>"#),
            Post(id: "t3_gal002", title: "Album post", html: #"<a href="https://www.reddit.com/gallery/gal002">gallery</a>"#),
            Post(
                id: "t3_gal003",
                title: "JSON gallery",
                html: "",
                galleryMedia: [.direct(URL(string: "https://i.redd.it/g1.jpg")!)]
            )
        ]
        let items = KDriveSourceItem.fromRedditPosts(posts)
        XCTAssertEqual(items, [
            .redditPost(id: "img001", title: "Sunset photo"),
            .redditPost(id: "gal002", title: "Album post"),
            .redditPost(id: "gal003", title: "JSON gallery")
        ])
    }

    // MARK: - Index kDrive et correspondance multi-sources

    func testRemoteIndexMatchesRedditSingleAndGalleryAndTruncatedFiles() {
        let longTitle = String(repeating: "Très long titre accentué ", count: 10)
        let longStem = FilenamePolicy.downloadStem(title: longTitle, postID: "t3_long99")
        let truncatedRemote = FilenamePolicy.kDriveFileName("\(longStem).jpg")

        let index = KDriveRemoteIndex(fileNames: [
            "Sunset photo - img001.jpg",
            "Album post 1 - gal002.png",
            "Collision - col123-2.mp4",
            truncatedRemote
        ])

        XCTAssertTrue(index.contains(.redditPost(id: "t3_img001", title: "Updated title doesn't matter")))
        XCTAssertTrue(index.contains(.redditPost(id: "gal002", title: "Album post")))
        XCTAssertTrue(index.contains(.redditPost(id: "col123", title: "Collision")))
        XCTAssertTrue(index.contains(.redditPost(id: "t3_long99", title: longTitle)))
        XCTAssertFalse(index.contains(.redditPost(id: "t3_missing1", title: "Not on drive")))
    }

    func testRemoteIndexMatchesXTikTokInstagramRedgifsAndXFetish() {
        let index = KDriveRemoteIndex(fileNames: [
            "Tweet title - xm-111222333.jpg",
            "xmv-444555666.mp4",
            "Danse - tkv-777888999.mp4",
            "Slide - tkm-123456789-1.jpg",
            "Insta photo - igm-987654321.jpg",
            "Insta reel - igv-555666777.mp4",
            "upsettrash3094.mp4",
            "Album shoot - xf-42-101.jpg",
            "Clip - xfv-909.mp4"
        ])

        XCTAssertTrue(index.contains(.xMedia(storageKey: "xm-111222333", title: "Any")))
        XCTAssertTrue(index.contains(.xMedia(storageKey: "xmv-444555666", title: "")))
        XCTAssertFalse(index.contains(.xMedia(storageKey: "xm-999999999", title: "Missing")))

        XCTAssertTrue(index.contains(.tikTokMedia(storageKey: "tkv-777888999", title: "Danse")))
        XCTAssertTrue(index.contains(.tikTokMedia(storageKey: "tkm-123456789-1", title: "Slide")))
        XCTAssertFalse(index.contains(.tikTokMedia(storageKey: "tkv-000111222", title: "Missing")))

        XCTAssertTrue(index.contains(.instagramMedia(storageKey: "igm-987654321", title: "Insta photo")))
        XCTAssertTrue(index.contains(.instagramMedia(storageKey: "igv-555666777", title: "Insta reel")))
        XCTAssertFalse(index.contains(.instagramMedia(storageKey: "igm-111111111", title: "Missing")))

        XCTAssertTrue(index.contains(.redgifs(id: "UpsetTrash3094")))
        XCTAssertFalse(index.contains(.redgifs(id: "othergif123")))

        XCTAssertTrue(index.contains(.xFetishAlbum(albumID: "42")))
        XCTAssertTrue(index.contains(.xFetishImage(albumID: "42", imageID: "101", title: "Album shoot")))
        XCTAssertTrue(index.contains(.xFetishVideo(videoID: "909", title: "Clip")))
        XCTAssertFalse(index.contains(.xFetishAlbum(albumID: "99")))
    }

    // MARK: - Évaluation de la fraîcheur

    func testEvaluateUpToDateWhenAllSourceAndLocalItemsOnDrive() {
        let remote: Set<String> = [
            "Post A - aaa111.jpg",
            "Post B - bbb222.mp4",
            "Old Post - ccc333.jpg"
        ]
        let source: [KDriveSourceItem] = [
            .redditPost(id: "aaa111", title: "Post A"),
            .redditPost(id: "bbb222", title: "Post B")
        ]
        let status = KDriveFreshness.evaluate(
            remoteFileNames: remote,
            sourceItems: source,
            localFileNames: ["Post A - aaa111.jpg"]
        )
        XCTAssertEqual(status, .upToDate(remoteCount: 3, checkedSourceCount: 2))
        XCTAssertTrue(status.isUpToDate)
        XCTAssertFalse(status.needsAttention)
    }

    func testEvaluateOutdatedWhenNewMediaOnSourceNotLocallyOrOnDrive() {
        let remote: Set<String> = [
            "Pinned Post - pin000.jpg",
            "Old Post - old111.jpg"
        ]
        // Même si le premier post est épinglé et déjà sur kDrive, les 2
        // publications suivantes sont nouvelles et détectées comme manquantes.
        let source: [KDriveSourceItem] = [
            .redditPost(id: "pin000", title: "Pinned Post"),
            .redditPost(id: "new222", title: "Brand New 1"),
            .redditPost(id: "new333", title: "Brand New 2"),
            .redditPost(id: "old111", title: "Old Post")
        ]
        let status = KDriveFreshness.evaluate(
            remoteFileNames: remote,
            sourceItems: source,
            localFileNames: []
        )
        XCTAssertEqual(
            status,
            .outdated(newOnSourceCount: 2, fullPageMissing: false, localPendingCount: 0, remoteCount: 2)
        )
        XCTAssertFalse(status.isUpToDate)
        XCTAssertTrue(status.needsAttention)
    }

    func testEvaluateFullPageMissingSetsFlag() {
        let remote: Set<String> = ["Very old - old001.jpg"]
        let source: [KDriveSourceItem] = [
            .redgifs(id: "fresh1"),
            .redgifs(id: "fresh2"),
            .redgifs(id: "fresh3")
        ]
        let status = KDriveFreshness.evaluate(
            remoteFileNames: remote,
            sourceItems: source
        )
        XCTAssertEqual(
            status,
            .outdated(newOnSourceCount: 3, fullPageMissing: true, localPendingCount: 0, remoteCount: 1)
        )
    }

    func testEvaluatePendingUploadWhenSourceMediaAlreadyDownloadedLocally() {
        let remote: Set<String> = ["Old - old111.jpg"]
        let source: [KDriveSourceItem] = [
            .redditPost(id: "new222", title: "New Downloaded"),
            .redditPost(id: "old111", title: "Old")
        ]
        let local = ["New Downloaded - new222.jpg"]
        let status = KDriveFreshness.evaluate(
            remoteFileNames: remote,
            sourceItems: source,
            localFileNames: local
        )
        XCTAssertEqual(status, .pendingUpload(localPendingCount: 1, remoteCount: 1))
        XCTAssertTrue(status.needsAttention)
    }

    func testEvaluateNotOnDriveWhenRemoteFolderIsNil() {
        let source: [KDriveSourceItem] = [
            .xMedia(storageKey: "xm-100", title: "Hello")
        ]
        let status = KDriveFreshness.evaluate(
            remoteFileNames: nil,
            sourceItems: source,
            localFileNames: ["Hello - xm-100.jpg", "Other - xm-101.jpg"]
        )
        XCTAssertEqual(status, .notOnDrive(sourceNewCount: 1, localPendingCount: 2))
        XCTAssertTrue(status.needsAttention)
    }

    func testContainsCandidateFileSkipsExistingRemoteAndAllowsMissingGalleryItems() {
        let fallbackName = FilenamePolicy.kDriveFallbackName(for: "Question? - qqq422.jpg")
        let index = KDriveRemoteIndex(fileNames: [
            "Old - aaa111.jpg",
            "Album 1 - gal222.jpg",
            fallbackName
        ])

        XCTAssertTrue(index.containsCandidateFile(
            fileName: "Old - aaa111.jpg",
            redditSinglePostID: "t3_aaa111",
            redditSinglePostTitle: "Old"
        ))
        XCTAssertTrue(index.containsCandidateFile(
            fileName: "Question? - qqq422.jpg",
            redditSinglePostID: "t3_qqq422",
            redditSinglePostTitle: "Question?"
        ))
        XCTAssertTrue(index.containsCandidateFile(fileName: "Album 1 - gal222.jpg"))
        XCTAssertFalse(index.containsCandidateFile(fileName: "Album 2 - gal222.jpg"))
        XCTAssertFalse(index.containsCandidateFile(
            fileName: "Brand New - zzz999.mp4",
            redditSinglePostID: "t3_zzz999",
            redditSinglePostTitle: "Brand New"
        ))
    }
}
