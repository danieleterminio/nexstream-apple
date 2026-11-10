import Foundation

/// System notifications, when the platform has them (iPhone). The Apple TV shows the in-app alert only.
protocol AlertScheduler: AnyObject {
    /// Shows `title` / `body` at `at`; tapping it opens `url`. Replaces a pending alert with the same id.
    func schedule(id: String, at: Millis, title: String, body: String, url: String)
    func cancel(id: String)
    func requestPermission()
}

/// "Avvisami": reminders live per profile in the database and are mirrored into system notifications where there are any
/// (2 minutes before the start). While the app is open the in-app alert shows as well (see `NexCore.checkAlerts`).
final class Reminders {
    static let leadMs: Millis = 2 * Clock.minute
    private let db: AppDB
    private let profiles: Profiles
    weak var scheduler: AlertScheduler?

    init(db: AppDB, profiles: Profiles) { self.db = db; self.profiles = profiles }

    func ids() -> Set<String> { Set(db.reminderIds(profiles.id)) }
    private func alertId(_ pid: Int64, _ sid: String) -> String { "rem-\(pid)-\(sid)" }

    /// Sets or removes the reminder; true when it is now set.
    func toggle(streamId: String, at: Millis, title: String, sub: String?) -> Bool {
        let pid = profiles.id
        if pid == 0 { return false }
        if db.reminder(pid, streamId) != nil {
            db.deleteReminder(pid, streamId); scheduler?.cancel(id: alertId(pid, streamId))
            return false
        }
        let r = ReminderEntity(profileId: pid, streamId: streamId, at: at, title: title, sub: sub, createdAt: Clock.now)
        db.upsertReminder(r)
        scheduler?.requestPermission()
        schedule(r)
        return true
    }
    func remove(_ r: ReminderEntity) { db.deleteReminder(r.profileId, r.streamId); scheduler?.cancel(id: alertId(r.profileId, r.streamId)) }

    /// Re-arm every future reminder (app start). Past ones older than 3 h are dropped.
    func rescheduleAll() {
        let now = Clock.now
        db.purgeReminders(before: now - 3 * Clock.hour)
        for r in db.reminders() where r.at > now { schedule(r) }
    }
    private func schedule(_ r: ReminderEntity) {
        scheduler?.schedule(id: alertId(r.profileId, r.streamId), at: max(r.at - Reminders.leadMs, Clock.now + 1000), title: "Sta per iniziare: \(r.title)", body: r.sub ?? "Tra 2 minuti",
                            url: "nexstream://open/live/\(r.streamId)?profile=\(r.profileId)")
    }
    /// Reminders whose moment has come (the in-app alert): they are removed and returned.
    func takeDue() -> [ReminderEntity] {
        let now = Clock.now
        let due = db.reminders().filter { $0.at - Reminders.leadMs <= now }
        for r in due { db.deleteReminder(r.profileId, r.streamId) }
        return due.filter { $0.at > now - 10 * Clock.minute }
    }
}

/// "Segui la tua squadra". Each profile keeps its own teams (football clubs and national teams), stored in the `meta` table
/// as `teams.<profileId>`. A team is identified by its crest / flag: a programme is one of its matches when one side of
/// "Home - Away" resolves to that same crest, exactly the way the match cards draw it. So "Juve", "Juventus" and
/// "Juventus FC" all count, and "Juventus Story" (no opponent) does not.
///
/// The matches feed the Home row "Le tue squadre", push them to the top of "Sport in diretta" and of the carousel, and
/// arm an alert 10 minutes before each kick-off.
final class Teams {
    struct Team: Hashable, Identifiable { let name: String; let crest: String; var id: String { crest } }
    /// One match of the followed teams, on its best channel.
    struct TeamMatch {
        let showing: Showing; let teams: [Team]; let start: Millis; let stop: Millis
        var profileIds: Set<Int64> = []
        var kickoff: Millis
        var title: String { showing.match?.text ?? showing.title }
    }

    static let leadMs: Millis = 10 * Clock.minute
    private static let armedKey = "teams.armed"
    /// Second teams, youth and women's sides share the club's crest but are not "the team".
    private static let reserves = Rx.i(#"\b(next ?gen|u ?\d\d|under ?\d\d|primavera|women|femminile|frauen|feminin|b team|ii)\b"#)
    private static let notAMatch = Rx.i(#"\b(sintesi|highlights?|replica|differita|best of|story|magazine|studio|pre ?partita|post ?partita|conferenza|primavera|under ?\d+|femminile|women)\b"#)
    private static let weakWords: Set<String> = ["calcio", "club", "city", "united", "real", "sporting", "athletic", "atletico"]

    private let db: AppDB
    private let profiles: Profiles
    weak var scheduler: AlertScheduler?
    /// Bumped when a profile's teams change.
    let changed = Observable<Int>(0)
    private let lock = AsyncLock()
    private let armedLock = NSLock()
    private var armed = [String: TeamMatch]()

    init(db: AppDB, profiles: Profiles) { self.db = db; self.profiles = profiles }

    private func key(_ pid: Int64) -> String { "teams.\(pid)" }

    func load(_ pid: Int64) -> [Team] {
        guard pid > 0, let raw = db.meta(key(pid)) else { return [] }
        return J.parse(raw).array.compactMap { o in
            guard let n = o["n"].stringOrNil, let c = o["c"].stringOrNil else { return nil }
            return Team(name: n, crest: c)
        }
    }
    func followed() -> [Team] { load(profiles.id) }

    private func save(_ pid: Int64, _ list: [Team]) {
        db.setMeta(key(pid), jsonString(list.map { ["n": $0.name, "c": $0.crest] }))
        changed.value += 1
    }

    /// Follow / stop following; true when the team is now followed. Re-arms the alerts.
    @discardableResult
    func toggle(_ t: Team, pid: Int64? = nil) async -> Bool {
        let p = pid ?? profiles.id
        if p <= 0 { return false }
        let now = load(p)
        let on = !now.contains { $0.crest == t.crest }
        save(p, on ? now + [t] : now.filter { $0.crest != t.crest })
        if on { scheduler?.requestPermission() }
        await scheduleAlerts()
        return on
    }

    /// Adds teams copied from another device; returns how many were new.
    func merge(_ pid: Int64, _ incoming: [Team]) async -> Int {
        if pid <= 0 || incoming.isEmpty { return 0 }
        let now = load(pid)
        let add = incoming.filter { t in !now.contains { $0.crest == t.crest } }.distinct { $0.crest }
        if !add.isEmpty { save(pid, now + add); await scheduleAlerts() }
        return add.count
    }

    /// "nexstream://open/follow/<name>": follow a team by the name a guide would use ("juventus", "italia").
    func followByName(_ name: String, pid: Int64) async -> Bool {
        guard let crest = Crests.identity(name) else { return false }
        if load(pid).contains(where: { $0.crest == crest }) { return true }
        let pick = Crests.catalog().first { $0.crest == crest }
        return await toggle(Team(name: pick?.name ?? name.capitalizedFirst, crest: crest), pid: pid)
    }

    /// What to search the guide for: the team's name and its single distinctive words ("bayern monaco" → "bayern", "monaco").
    private func terms(_ t: Team) -> Set<String> {
        let n = MetaText.norm(t.name)
        let words = n.split(separator: " ").map(String.init).filter { $0.count >= 4 && !Teams.weakWords.contains($0) }
        return words.isEmpty ? [n] : Set(words)
    }

    private struct Cand { let s: Showing; let pair: String; let mine: [Team]; let start: Millis; let stop: Millis; let bare: Bool }

    /// The matches of `teams` between `from` and `to`, one per fixture, on the best channel. The guides repeat a match
    /// many times (replays, highlights, placeholders), so only real live broadcasts count: Sky and DAZN flag them, Rai
    /// and Mediaset do not replay football. The kick-off is the guide's bare "Home - Away" line when there is one (DAZN
    /// opens its coverage an hour earlier); the alert goes off 10 minutes before it.
    func matches(_ teams: [Team], from: Millis, to: Millis, channels: [ChannelEntity]) -> [TeamMatch] {
        if teams.isEmpty { return [] }
        let crests = Dictionary(teams.map { ($0.crest, $0) }, uniquingKeysWith: { a, _ in a })
        var byEpg = [String: [ChannelEntity]]()
        for c in channels where c.shiftMin == 0 { if let e = c.epgId { byEpg[e, default: []].append(c) } }
        var found = [Int64: ProgrammeEntity]()
        for t in teams { for term in terms(t) { for p in db.sportNaming("%\(term)%", from: from, to: to) { found[p.id] = p } } }

        func cand(_ s: Showing, _ start: Millis, _ stop: Millis) -> Cand? {
            guard let m = s.match else { return nil }
            // the competition says it too ("Serie A Women Athora" in the subtitle, "Primavera 1" on an event channel)
            let context = [m.home, m.away, s.programme?.title, s.programme?.subtitle, s.programme?.show, s.channel.event, s.channel.eventSub].compactMap { $0 }.joined(separator: " | ")
            if Teams.reserves.contains(context) { return nil }
            let h = Crests.identity(m.home), a = Crests.identity(m.away)
            let mine = [h.flatMap { crests[$0] }, a.flatMap { crests[$0] }].compactMap { $0 }.distinct
            if mine.isEmpty { return nil }
            let pair = [h ?? MetaText.norm(m.home), a ?? MetaText.norm(m.away)].sorted().joined(separator: "|")
            let title = s.programme?.title ?? ""
            return Cand(s: s, pair: pair, mine: mine, start: start, stop: stop, bare: !title.contains("|") && Match.parse(title) != nil)
        }
        var all = [Cand](), live = [Cand]()
        for p in found.values {
            if Teams.notAMatch.contains("\(p.title) \(p.subtitle ?? "")") { continue }
            guard let chs = byEpg[p.epgId], let c = chs.first, let x = cand(Showing(channel: c, programme: p), p.start, p.stop) else { continue }
            all.append(x)
            let len = p.stop - p.start
            if (p.live || p.src == "rai" || p.src == "mediaset") && len >= 80 * Clock.minute && len <= 5 * Clock.hour {
                for ch in chs { live.append(Cand(s: Showing(channel: ch, programme: p), pair: x.pair, mine: x.mine, start: p.start, stop: p.stop, bare: x.bare)) }
            }
        }
        // event channels (PPV / DAZN events) carry the match in their name: live by definition
        for c in channels {
            guard let at = c.eventStart, c.event != nil, at + 2 * Clock.hour >= from, at <= to else { continue }
            if let x = cand(Showing(channel: c, programme: nil), at, at + 2 * Clock.hour) { live.append(x); all.append(x) }
        }
        var out = [TeamMatch]()
        for (pair, list) in live.grouped(by: { $0.pair }) {
            // the first live airing of the fixture and the channels showing it at the same time
            let first = list.map { $0.start }.min() ?? 0
            let same = list.filter { $0.start - first < 45 * Clock.minute }
            func rank(_ c: Cand) -> (Int, Int, Int) {
                ((c.s.programme?.live == true || c.s.programme == nil) ? 0 : 1, c.s.channel.quality == "UHD" ? 1 : 0, c.s.channel.num > 0 ? c.s.channel.num : 9999)
            }
            guard let best = same.min(by: { rank($0) < rank($1) }) else { continue }
            let kickoff = all.filter { $0.pair == pair && $0.bare && $0.start >= first && $0.start - first <= 2 * Clock.hour }.map { $0.start }.max() ?? best.start
            // cards show the kick-off, not the start of the channel's coverage
            var shown = best.s
            if var p = best.s.programme { p.start = kickoff; shown = Showing(channel: best.s.channel, programme: p, meta: best.s.meta) }
            out.append(TeamMatch(showing: shown, teams: same.flatMap { $0.mine }.distinct, start: kickoff, stop: best.stop, kickoff: kickoff))
        }
        return out.sortedBy { $0.start }
    }

    /// Matches of the current profile's teams from 3 h ago (still on air) to `days` ahead.
    func upcomingForCurrent(days: Int = 7) -> [TeamMatch] {
        let teams = load(profiles.id)
        if teams.isEmpty { return [] }
        let now = Clock.now
        return matches(teams, from: now - 3 * Clock.hour, to: now + Millis(days) * Clock.day, channels: db.channels()).filter { $0.stop > now }
    }

    // ------------------------------------------------------------------------------------------------ alerts

    private func alertKey(_ m: TeamMatch) -> String { "\(m.showing.channel.streamId)@\(m.kickoff / Clock.minute)" }

    /// Arm an alert 10 minutes before each match of the next 2 days, for every profile following one of its teams.
    /// Called at start, after each guide update and when a team is followed / dropped.
    func scheduleAlerts() async {
        await lock.lock()
        let now = Clock.now
        let chans = db.channels()
        var byMatch = [String: TeamMatch]()
        for p in profiles.all() {
            let teams = load(p.id)
            if teams.isEmpty { continue }
            for m in matches(teams, from: now, to: now + 2 * Clock.day, channels: chans) {
                if m.kickoff - Teams.leadMs < now - Clock.minute { continue }
                let k = alertKey(m)
                var merged = m
                if let prev = byMatch[k] { merged = TeamMatch(showing: m.showing, teams: (prev.teams + m.teams).distinct, start: m.start, stop: m.stop, profileIds: prev.profileIds, kickoff: m.kickoff) }
                merged.profileIds.insert(p.id)
                byMatch[k] = merged
            }
        }
        let old = (db.meta(Teams.armedKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isBlank }
        for k in old where byMatch[k] == nil { scheduler?.cancel(id: "team-\(k)") }
        for (k, m) in byMatch {
            let pid = m.profileIds.contains(profiles.id) ? profiles.id : (m.profileIds.first ?? 0)
            let sub = [m.showing.competition, m.showing.channel.name].compactMap { $0 }.distinct.joined(separator: " · ")
            scheduler?.schedule(id: "team-\(k)", at: max(m.kickoff - Teams.leadMs, now + 1000), title: "Tra 10 minuti: \(m.title)", body: sub.isEmpty ? "La tua squadra" : sub,
                                url: "nexstream://open/live/\(m.showing.channel.streamId)?profile=\(pid)")
        }
        db.setMeta(Teams.armedKey, byMatch.keys.joined(separator: ","))
        armedLock.lock(); armed = byMatch; armedLock.unlock()
        NxLog.i("NxTeams", "\(byMatch.count) match alerts armed")
        await lock.unlock()
    }

    /// Match alerts whose moment has come, for the in-app "Sta per iniziare" (createdAt = 0 marks a team alert).
    func takeDue(currentProfile: Int64) -> [ReminderEntity] {
        let now = Clock.now
        armedLock.lock(); defer { armedLock.unlock() }
        var out = [ReminderEntity]()
        for (k, m) in armed where m.kickoff - Teams.leadMs <= now {
            armed[k] = nil
            if m.kickoff > now - 5 * Clock.minute && m.profileIds.contains(currentProfile) {
                let sub = [m.showing.competition, m.showing.channel.name].compactMap { $0 }.distinct.joined(separator: " · ")
                out.append(ReminderEntity(profileId: currentProfile, streamId: m.showing.channel.streamId, at: m.kickoff, title: m.title, sub: sub, createdAt: 0))
            }
        }
        return out
    }
}
