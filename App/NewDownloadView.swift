import SwiftUI
import MediaCore
import UIKit

/// Écran-matrice de la direction « Console d'archive » : l'onglet **Nouveau**.
///
/// Une seule action primaire (Télécharger / Arrêter, plein largeur), la source
/// en grille compacte à noms complets, et la **console de transfert** : une
/// carte `surfaceElevated` qui regroupe métriques monospaced, progression,
/// statut et bannière d'archive incomplète. Zéro valeur magique : tout passe
/// par les tokens `DS`.
struct NewDownloadView: View {
    @ObservedObject var model: Downloader
    @ObservedObject private var redditSession = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    @State private var sourceGridPresented = false
    @State private var filtersPresented = false
    @State private var tikTokSavedPresented = false
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.space(3)) {
                    commandCard
                    transferConsole
                }
                .padding(DS.space(4))
            }
            .background(DS.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L("Nouveau", "New"))
            .animation(reduceMotion ? nil : DS.spring, value: model.sourceKind)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { filtersPresented = true } label: {
                        Image(systemName: model.downloadFilter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .disabled(model.running)
                    .accessibilityLabel(L("Filtres de téléchargement", "Download filters"))
                }
            }
            .sheet(isPresented: $sourceGridPresented) {
                SourceGridSheet(model: model) {
                    sourceGridPresented = false
                }
            }
            .sheet(isPresented: $filtersPresented) {
                DownloadFilterSheet(model: model)
            }
            .sheet(isPresented: $tikTokSavedPresented) {
                TikTokSavedPicker(model: model,
                                  onChoose: { choice in
                    tikTokSavedPresented = false
                    model.tikTokSavedChoice = choice
                    model.start()
                }, onAccount: { name in
                    tikTokSavedPresented = false
                    model.sourceKind = "tt"
                    model.username = name
                    model.start()
                })
            }
        }
    }

    // MARK: - Commande

    /// Carte commande : la source, le champ, les options de la source et les
    /// indices occupent toute la zone au-dessus du bouton principal.
    private var commandCard: some View {
        VStack(spacing: DS.space(3)) {
            sourceFieldRow
            optionsRow
            sourceHintRow
            downloadButton
        }
        .padding(DS.space(4))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusL))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
    }

    private var sourceFieldRow: some View {
        HStack(spacing: DS.space(3)) {
            SourceKindButton(kind: SourceKind(rawValue: model.sourceKind) ?? .user) {
                guard !model.running else { return }
                sourceGridPresented = true
            }
            if model.sourceKind == "saved" {
                Text(L("Compte Reddit connecté", "Signed-in Reddit account"))
                    .font(.callout)
                    .foregroundStyle(DS.onSurfaceMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.space(3))
                    .frame(minHeight: 44)
            } else if model.sourceKind == "ts" {
                Text(L("Sauvegardés TikTok connectés", "Signed-in TikTok saved"))
                    .font(.callout)
                    .foregroundStyle(DS.onSurfaceMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.space(3))
                    .frame(minHeight: 44)
            } else {
                HStack(spacing: DS.space(1)) {
                    TextField(placeholder, text: $model.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).focused($editing)
                        .disabled(model.running)
                        .onSubmit { start() }
                    if !model.username.isEmpty && !model.running {
                        Button { model.username = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(DS.onSurfaceMuted)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Effacer le champ", "Clear input"))
                    }
                }
                .padding(.leading, DS.space(3))
                .padding(.trailing, model.username.isEmpty || model.running ? DS.space(3) : 0)
                .frame(minHeight: 44)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusM))
            }
        }
    }

    private var downloadButton: some View {
        Button {
            if model.running { model.stop() } else { start() }
        } label: {
            HStack(spacing: DS.space(2)) {
                Image(systemName: model.running ? "stop.fill" : "arrow.down")
                    .font(.system(size: 19, weight: .semibold))
                Text(model.running ? L("Arrêter", "Stop") : L("Télécharger", "Download"))
                    .font(DS.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(cannotStart)
        .buttonStyle(DSPrimaryButtonStyle())
        .accessibilityLabel(model.running ? L("Arrêter le téléchargement", "Stop download") : L("Télécharger", "Download"))
    }

    private var placeholder: String {
        switch model.sourceKind {
        case "r": return L("sub, ou lien de post", "sub, or post link")
        case "rg": return L("pseudo, #tag ou lien", "username, #tag or link")
        case "x": return L("nom, lien vidéo/album", "name, video/album link")
        case "tw": return L("compte X", "X account")
        case "tt": return L("compte TikTok ou vidéo", "TikTok account or video")
        case "ig": return L("compte Instagram", "Instagram account")
        default: return L("pseudo", "username")
        }
    }

    private var cannotStart: Bool {
        guard !model.running else { return false }
        if model.sourceKind == "ts" { return !tikTokSession.hasSession || tikTokSession.clearing }
        if model.sourceKind == "saved" { return !redditSession.hasSession || redditSession.clearing }
        if model.username.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        // Les trois sessions sont distinctes : X et TikTok ne se connectent
        // pas avec le compte Reddit.
        if isTwitterInput { return !xSession.hasSession || xSession.clearing }
        if isTikTokInput { return !tikTokSession.hasSession || tikTokSession.clearing }
        return model.needsSession && (!redditSession.hasSession || redditSession.clearing)
    }

    private var isSubredditInput: Bool {
        if let source = model.resolvedSource, case .subreddit = source { return true }
        return false
    }

    private var isXFetishInput: Bool {
        if let source = model.resolvedSource, case .xFetish = source { return true }
        return false
    }

    /// Options de la source sélectionnée : une seule rangée, dont le contenu
    /// ne montre que ce qui concerne la source en cours.
    @ViewBuilder private var optionsRow: some View {
        if isSubredditInput {
            Picker(L("Tri du subreddit", "Subreddit sort"), selection: $model.subSort) {
                Text(L("Nouveaux", "New")).tag("new")
                Text(L("Chauds", "Hot")).tag("hot")
                Text(L("Top du mois", "Top this month")).tag("top")
            }
            .pickerStyle(.segmented)
            .disabled(model.running)
            .accessibilityLabel(L("Tri du subreddit", "Subreddit sort"))
        } else if isXFetishInput {
            Picker(L("Médias X-Fetish", "X-Fetish media"), selection: $model.xFetishMediaKind) {
                Text(L("Images", "Images")).tag(XFetishMediaKind.images)
                Text(L("Vidéos", "Videos")).tag(XFetishMediaKind.videos)
                Text(L("Les deux", "Both")).tag(XFetishMediaKind.both)
            }
            .pickerStyle(.segmented)
            .disabled(model.running)
            .accessibilityLabel(L("Médias X-Fetish", "X-Fetish media"))
        } else if model.sourceKind == "ts" {
            Label(L("Les dossiers de favoris TikTok sont proposés au lancement.", "TikTok favorites folders are offered when starting."),
                  systemImage: "folder.badge.clock")
                .font(.caption).foregroundStyle(DS.onSurfaceMuted).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var isTwitterInput: Bool {
        if let source = model.resolvedSource, case .twitterUser = source { return true }
        // Le sélecteur reste pertinent tant que le champ X est vide/invalide.
        return model.resolvedSource == nil && model.sourceKind == "tw"
    }

    private var isTikTokInput: Bool {
        if let source = model.resolvedSource, case .tiktokUser = source { return true }
        // Le sélecteur reste pertinent tant que le champ TikTok est vide/invalide.
        return model.resolvedSource == nil && model.sourceKind == "tt"
    }

    @ViewBuilder private var sourceHintRow: some View {
        if isTwitterInput && !xSession.hasSession {
            sessionHint(L("Compte X : connecte-toi à X dans les Réglages. Sans session, X ne publie aucun média.", "X account: sign in to X in Settings. Without a session, X publishes no media."))
        } else if isTikTokInput && !tikTokSession.hasSession {
            sessionHint(L("Compte TikTok : connecte-toi à TikTok dans les Réglages. Sans session, TikTok ne publie aucun média.", "TikTok account: sign in to TikTok in Settings. Without a session, TikTok publishes no media."))
        } else if model.sourceKind == "ts" && !tikTokSession.hasSession {
            sessionHint(L("Sauvegardés TikTok : connecte-toi à TikTok dans les Réglages. Sans session, impossible de lire les publications enregistrées du compte.", "TikTok saved: sign in to TikTok in Settings. Without a session, the account's saved posts cannot be read."))
        } else if !isTwitterInput && !isTikTokInput && model.sourceKind != "ts" && model.needsSession && !redditSession.hasSession {
            if model.sourceKind == "saved" {
                sessionHint(L("Sauvegardés : connecte-toi à Reddit dans les Réglages. Le compte sera sélectionné automatiquement.", "Saved: sign in to Reddit in Settings. Your account will be selected automatically."))
            } else {
                sessionHint(L("Reddit : connecte-toi à Reddit dans les Réglages pour lire ce flux.", "Reddit: sign in to Reddit in Settings to read this feed."))
            }
        }
    }

    private func sessionHint(_ text: String) -> some View {
        Label(text, systemImage: "person.crop.circle.badge.questionmark")
            .font(.caption).foregroundStyle(DS.accentEmphasis).lineLimit(3).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Console de transfert (signature)

    /// Carte console : métriques, progression, statut, bannière. Toujours
    /// présente — c'est le tableau de bord du transfert, pas un état transitoire.
    private var transferConsole: some View {
        let showProgress = model.running || model.discovered > 0
        return VStack(alignment: .leading, spacing: DS.space(2)) {
            HStack(spacing: 0) {
                consoleMetric("\(model.files.count)", label: L("médias", "media"))
                metricDivider
                consoleMetric(model.totalSize, label: L("poids", "size"))
                metricDivider
                consoleMetric("\(model.count)/\(model.discovered)", label: L("repérés", "found"))
                    .opacity(showProgress ? 1 : 0)
                    .accessibilityHidden(!showProgress)
            }
            if model.running {
                if let unit = model.transferUnit, unit.total > 0 {
                    let sourceName = SourceSelection.spoken(SourceKind(rawValue: model.sourceKind) ?? .user)
                    ProgressView(value: unit.fraction)
                        .progressViewStyle(.linear)
                        .tint(DS.accent)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(sourceName)
                        .accessibilityValue("\(unit.done)/\(unit.total)")
                } else if model.discovered > 0 {
                    let fraction = min(1.0, Double(model.count) / Double(max(1, model.discovered)))
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(DS.accent)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Téléchargement en cours", "Downloading"))
                        .accessibilityValue("\(model.count)/\(model.discovered)")
                } else {
                    HStack(spacing: DS.space(2)) {
                        ProgressView().controlSize(.small)
                        Text(model.status.isEmpty ? L("Analyse en cours…", "Scanning…") : model.status)
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.status.isEmpty && !(model.running && model.transferUnit == nil && model.discovered == 0) {
                Text(model.status)
                    .font(.caption).foregroundStyle(DS.onSurfaceMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.storageLimitReached {
                HStack(spacing: DS.space(2)) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                    Text(L("Plafond d’espace atteint : libère de la place ou relève la limite dans les Réglages.",
                           "Storage limit reached: free up space or raise the limit in Settings."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(DS.error)
                .padding(DS.space(2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.error.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityElement(children: .combine)
            }
            if model.scanIncomplete {
                HStack(spacing: DS.space(2)) {
                    Image(systemName: "info.circle.fill")
                    Text(L("Archive incomplète : le parcours a atteint sa limite de pages. Relance pour continuer.",
                           "Incomplete archive: the scan reached its page limit. Relaunch to continue."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(DS.accentEmphasis)
                .padding(DS.space(2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DS.space(3))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusM))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
    }

    /// Grande métrique de la console : valeur monospaced en title3, libellé
    /// en caption sous la valeur, centrée dans sa colonne.
    private func consoleMetric(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .foregroundStyle(DS.onSurface)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(label)
                .font(DS.caption2)
                .foregroundStyle(DS.onSurfaceMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        DS.separator
            .frame(width: 1, height: 30)
            .padding(.vertical, DS.space(1))
    }

    private func start() {
        guard !model.running else { return }
        editing = false
        // Sauvegardés TikTok : choisir d'abord entre toutes les publications
        // enregistrées et un dossier de favoris du compte connecté.
        if model.sourceKind == "ts" {
            tikTokSavedPresented = true
            return
        }
        model.start()
    }
}

// MARK: - Sélection de la source

/// Source : face, libellé parlé et session requise — partagés par la
/// pastille et la feuille-grille. Les deux entrées TikTok partagent la marque
/// du service et ne se distinguent que par leur micro-libellé.
enum SourceSelection {
    static let order: [SourceKind] = [.user, .subreddit, .redGifs, .saved,
                                      .xFetish, .twitter, .tiktok, .tiktokSaved, .instagram]

    static func face(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return "u/"
        case .subreddit: return "r/"
        case .redGifs: return "RG"
        case .saved: return "♥"
        case .xFetish: return "x/"
        case .twitter: return "tw"
        case .tiktok: return "tt"
        case .tiktokSaved: return "ts"
        case .instagram: return "ig"
        }
    }

    static func icon(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return "person.crop.circle"
        case .subreddit: return "bubble.left.and.bubble.right"
        case .redGifs: return "film"
        case .saved: return "heart.fill"
        case .xFetish: return "flame"
        case .twitter: return "at"
        case .tiktok: return "music.note"
        case .tiktokSaved: return "bookmark.fill"
        case .instagram: return "camera"
        }
    }

    /// Marque officielle du service, quand il en existe une.
    ///
    /// `nil` pour RedGifs et X-Fetish : aucun logo public exploitable, la carte
    /// garde alors son symbole système. Les sauvegardés Reddit (`♥`) gardent
    /// aussi leur cœur : trois fois la même tête de Reddit dans une grille de
    /// neuf se lirait comme un défaut d'affichage.
    static func mark(_ kind: SourceKind) -> SourceMark? {
        switch kind {
        case .user, .subreddit: return .reddit
        case .twitter: return .x
        case .tiktok, .tiktokSaved: return .tiktok
        case .instagram: return .instagram
        case .redGifs, .saved, .xFetish: return nil
        }
    }

    static func spoken(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return L("Profil Reddit", "Reddit profile")
        case .subreddit: return L("Subreddit", "Subreddit")
        case .redGifs: return "RedGifs"
        case .saved: return L("Sauvegardés Reddit", "Reddit saved")
        case .xFetish: return L("Profil X-Fetish", "X-Fetish profile")
        case .twitter: return L("Compte X", "X account")
        case .tiktok: return L("Compte TikTok", "TikTok account")
        case .tiktokSaved: return L("Sauvegardés TikTok", "TikTok saved")
        case .instagram: return L("Compte Instagram", "Instagram account")
        }
    }

    /// Haptique léger de sélection : signal utile, sans vibration envahissante.
    static func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Pastille compacte de la source en cours : un appui ouvre la feuille-grille
/// de toutes les sources.
private struct SourceKindButton: View {
    let kind: SourceKind
    let open: () -> Void

    var body: some View {
        Button {
            SourceSelection.haptic()
            open()
        } label: {
            Text(SourceSelection.face(kind))
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .frame(width: 52, height: 48)
                .foregroundStyle(DS.accentEmphasis)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusM))
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel(L("Source : \(SourceSelection.spoken(kind)). Touchez pour choisir parmi toutes les sources.", "Source: \(SourceSelection.spoken(kind)). Tap to choose among all sources."))
    }
}

/// Feuille-grille des sources : neuf choix découvrables d'un coup d'œil, un
/// appui pour choisir. Le point accent signale une session manquante pour la
/// source ; les deux entrées TikTok y sont visuellement différenciées
/// (`tt` compte public, `ts` sauvegardés du compte connecté).
private struct SourceGridSheet: View {
    @ObservedObject var model: Downloader
    @ObservedObject private var reddit = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    let onPick: () -> Void
    @Environment(\.dismiss) private var dismiss

    private func sessionMissing(_ kind: SourceKind) -> Bool {
        switch kind {
        case .user, .subreddit, .saved: return !reddit.hasSession
        case .twitter: return !xSession.hasSession
        case .tiktok, .tiktokSaved: return !tikTokSession.hasSession
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.space(3)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.space(2)), count: 3), spacing: DS.space(2)) {
                        ForEach(SourceSelection.order, id: \.rawValue) { kind in
                            SourceGridCard(kind: kind,
                                           isCurrent: model.sourceKind == kind.rawValue,
                                           sessionMissing: sessionMissing(kind)) {
                                SourceSelection.haptic()
                                model.sourceKind = kind.rawValue
                                onPick()
                            }
                        }
                    }
                    HStack(spacing: DS.space(1)) {
                        Circle()
                            .fill(DS.accentEmphasis)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(L("Point accent : connexion requise dans les Réglages.", "Accent dot: sign-in required in Settings."))
                            .font(.caption2)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                }
                .padding(DS.space(4))
            }
            .background(DS.background)
            .navigationTitle(L("Télécharger depuis…", "Download from…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SourceGridCard: View {
    let kind: SourceKind
    let isCurrent: Bool
    let sessionMissing: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: DS.space(1)) {
                HStack(spacing: DS.space(1)) {
                    glyph
                    if sessionMissing {
                        Circle().fill(DS.accentEmphasis).frame(width: 7, height: 7)
                            .offset(x: 4, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                Text(SourceSelection.spoken(kind))
                    .font(DS.caption2)
                    .foregroundStyle(isCurrent ? DS.accentEmphasis : DS.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 30)
                Text(SourceSelection.face(kind))
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(DS.onSurfaceMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.space(2))
            .background(isCurrent ? DS.accent.opacity(0.12) : DS.surface,
                        in: RoundedRectangle(cornerRadius: DS.radiusM))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusM).strokeBorder(isCurrent ? DS.accentEmphasis : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel(SourceSelection.spoken(kind))
        .accessibilityValue(sessionMissing ? L("Connexion requise", "Sign-in required") : "")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// Marque officielle quand le service en a une, symbole système sinon.
    /// La hauteur est fixée dans les deux cas pour que les cartes d'une même
    /// rangée restent alignées, quel que soit le glyphe.
    @ViewBuilder private var glyph: some View {
        if let mark = SourceSelection.mark(kind) {
            SourceMarkView(mark: mark, tint: isCurrent ? DS.accentEmphasis : DS.onSurface, size: 22)
                .frame(height: 24)
        } else {
            Image(systemName: SourceSelection.icon(kind))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isCurrent ? DS.accentEmphasis : DS.onSurface)
                .frame(height: 24)
        }
    }
}

/// Choix des sauvegardés TikTok : toutes les publications enregistrées du
/// compte connecté, ou un dossier de favoris détecté sur la page
/// Sauvegardés (`collection_list`, signé par TikTok). La liste peut
/// être vide : TikTok ne la charge pas toujours sans interaction, et le choix
/// « toutes les publications enregistrées » reste proposé — le parcours
/// expliquera en journal ce que la page aura réellement servi.
struct TikTokSavedPicker: View {
    @ObservedObject var model: Downloader
    /// Trois cibles différenciées, affichées en sections distinctes :
    /// tout le sauvegardé du compte connecté, un dossier de favoris
    /// (collection), ou un compte TikTok public précis.
    let onChoose: (TikTokSavedCollection?) -> Void
    let onAccount: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var accountName = ""
    @State private var accountError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L("Toutes les publications enregistrées du compte connecté", "All saved posts of the signed-in account"),
                          systemImage: "square.grid.2x2")
                        .font(.subheadline)
                    Button {
                        onChoose(nil)
                    } label: {
                        Label(L("Tout télécharger", "Download all"),
                              systemImage: "arrow.down.circle.fill")
                    }
                } header: {
                    Text(L("Sauvegardés globaux", "Global saved posts"))
                }
                Section {
                    if model.tikTokSavedCollections.isEmpty {
                        Label(L("Aucun dossier détecté pour l'instant. TikTok ne les charge pas toujours sans interaction : relève la feuille pour réessayer.", "No folder detected so far. TikTok does not always load them without interaction: pull to refresh and retry."),
                              systemImage: "questionmark.folder")
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                    } else {
                        ForEach(model.tikTokSavedCollections) { folder in
                            Button {
                                onChoose(folder)
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer()
                                    Text(verbatim: "\(folder.itemCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(DS.onSurfaceMuted)
                                }
                            }
                        }
                    }
                } header: {
                    Text(L("Collections (dossiers de favoris)", "Collections (favorites folders)"))
                }
                Section {
                    Label(L("Médias publics d'un compte TikTok précis, sans lien avec les sauvegardés.", "Public media of a specific TikTok account, unrelated to saved posts."),
                          systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(DS.onSurfaceMuted)
                    HStack {
                        TextField(L("compte TikTok", "TikTok account"), text: $accountName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            do {
                                let name = try TikTokAPI.username(accountName)
                                accountError = nil
                                onAccount(name)
                            } catch {
                                accountError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel(L("Télécharger ce compte TikTok", "Download this TikTok account"))
                    }
                    if let accountError {
                        Text(accountError)
                            .font(.caption)
                            .foregroundStyle(DS.error)
                    }
                } header: {
                    Text(L("Un compte précis (comme tt)", "A specific account (like tt)"))
                }
                if let error = model.tikTokSavedListError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(DS.accentEmphasis)
                    }
                }
            }
            .navigationTitle(L("TikTok — quoi télécharger ?", "TikTok — what to download?"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accentEmphasis)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Annuler", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Actualiser", "Refresh")) {
                        Task { await model.loadTikTokSavedCollections() }
                    }
                    .disabled(model.tikTokSavedLoading)
                }
            }
            .overlay {
                if model.tikTokSavedLoading {
                    ProgressView(L("Recherche des collections et des sauvegardés…", "Looking for collections and saved posts…"))
                        .padding(DS.space(4))
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusM))
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                await model.loadTikTokSavedCollections()
            }
            .refreshable {
                await model.loadTikTokSavedCollections()
            }
        }
    }
}

#Preview("Nouveau — clair") {
    NewDownloadView(model: Downloader())
}

#Preview("Nouveau — sombre") {
    NewDownloadView(model: Downloader())
        .preferredColorScheme(.dark)
}

#Preview("Nouveau — texte accessibility XXL") {
    NewDownloadView(model: Downloader())
        .dynamicTypeSize(.accessibility3)
}
