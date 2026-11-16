import Foundation
import SendspinClientKit

/// The places music can be sent to, each with a queue of its own: "Everywhere", the groups
/// the user made, and every speaker by itself.
///
/// A speaker plays with one of them at a time: the one that last started playing with it in
/// its members. Until one calls it in, it plays with Everywhere.
actor Zones {
    /// One place to play: its queue, and the Sendspin group that carries its sound.
    struct Zone: Sendable {
        let id: String
        let name: String
        let group: PlaybackGroup
        let engine: PlaybackEngine
    }

    /// Every speaker there is. The id is the one the single group had before there were more.
    static let everywhereID = "group"
    static let everywhereName = "Everywhere"
    static let groupPrefix = "syncgroup:"

    private let store: ServerStore
    private let speakers: AirPlaySpeakers
    private let home: PlaybackGroup
    private let onChange: @Sendable ([ServerStore.SyncGroup]) -> Void
    private var artworkURL: (@Sendable (LibraryTrack) -> String?)?
    private var zones: [String: Zone] = [:]
    private var syncGroups: [ServerStore.SyncGroup] = []
    /// The zone each speaker plays with, by member id; Everywhere for those not listed.
    private var location: [String: String] = [:]
    /// The connected Sendspin players, by client id.
    private var sessions: [String: PlayerSession] = [:]

    /// `home` carries Everywhere's sound: the group new players and speakers are put in.
    init(home: PlaybackGroup, store: ServerStore, speakers: AirPlaySpeakers,
         onChange: @escaping @Sendable ([ServerStore.SyncGroup]) -> Void) {
        self.home = home
        self.store = store
        self.speakers = speakers
        self.onChange = onChange
    }

    /// Make Everywhere and the saved groups ready to play.
    func start(artworkURL: @escaping @Sendable (LibraryTrack) -> String?) async {
        self.artworkURL = artworkURL
        syncGroups = store.syncGroups
        _ = await makeZone(id: Self.everywhereID, name: Self.everywhereName, group: home)
        for group in syncGroups { _ = await makeZone(id: group.id, name: group.name) }
        onChange(syncGroups)
    }

    func stop() async {
        for zone in zones.values {
            await zone.engine.stop()
            await zone.group.shutdown()
        }
        zones = [:]
        sessions = [:]
        location = [:]
    }

    private func makeZone(id: String, name: String, group: PlaybackGroup? = nil) async -> Zone {
        let group = group ?? PlaybackGroup(name: name, leadMs: PlaybackEngine.minimumLeadMs)
        let zone = Zone(id: id, name: name, group: group, engine: PlaybackEngine(group: group))
        zones[id] = zone
        let store = store
        await zone.engine.attach(artworkURL: artworkURL, onTrackStarted: { store.played(albumID: $0.albumID) },
                                 willStart: { [weak self] in await self?.gather(id) })
        // So that a player moved here shows this queue, not the one it came from.
        await zone.engine.publish()
        return zone
    }

    var everywhere: Zone? { zones[Self.everywhereID] }

    var all: [Zone] { Array(zones.values) }

    var groups: [ServerStore.SyncGroup] { syncGroups }

    /// The zone an id names: Everywhere for none, a group, or a speaker by itself. Nil for an
    /// id that names nothing here.
    func zone(_ id: String?) async -> Zone? {
        guard let id, id != Self.everywhereID else { return everywhere }
        if let zone = zones[id] { return zone }
        guard zones[Self.everywhereID] != nil, !id.hasPrefix(Self.groupPrefix), let name = await memberName(id)
        else { return nil }
        // Another request may have made it meanwhile.
        if let zone = zones[id] { return zone }
        return await makeZone(id: id, name: name)
    }

    /// The zone a speaker plays with now.
    func zoneID(of member: String) -> String {
        location[member].flatMap { zones[$0]?.id } ?? Self.everywhereID
    }

    // MARK: Sendspin players

    var players: [String: PlayerSession] { sessions }

    /// A player said who it is: put it where it last played.
    func place(_ session: PlayerSession, clientID: String) async {
        sessions[clientID] = session
        guard let zone = zones[zoneID(of: clientID)] else { return }
        await move(session, to: zone)
    }

    /// A player's connection is over.
    func gone(_ session: PlayerSession) {
        for (id, known) in sessions where known === session { sessions[id] = nil }
    }

    /// End a player's connection, whichever group it's in.
    func drop(_ session: PlayerSession) async {
        gone(session)
        await session.currentGroup?.remove(url: session.url)
    }

    private func move(_ session: PlayerSession, to zone: Zone) async {
        guard let from = await session.currentGroup, from !== zone.group,
              let membership = await from.release(url: session.url) else { return }
        await zone.group.adopt(membership)
    }

    /// A speaker's name: a connected player's, or a switched-on AirPlay speaker's.
    private func memberName(_ id: String) async -> String? {
        if let session = sessions[id] { return await session.currentStatus.name ?? "Player" }
        return await speakers.speakers.first { $0.enabled && AirPlaySpeakers.memberID($0.id) == id }?.name
    }

    // MARK: Who plays where

    /// The speakers a zone plays on once it starts.
    func members(of id: String) async -> [String] {
        if id == Self.everywhereID {
            return Array(sessions.keys) + (await speakers.speakers).filter(\.enabled).map { AirPlaySpeakers.memberID($0.id) }
        }
        if let group = syncGroups.first(where: { $0.id == id }) { return group.members.map(\.id) }
        return [id]
    }

    /// A zone starts playing: call in its speakers from wherever they play. A zone left with
    /// nobody to hear it pauses.
    func gather(_ id: String) async {
        guard let zone = zones[id] else { return }
        var left: Set<String> = []
        for member in await members(of: id) {
            let from = zoneID(of: member)
            guard from != id else { continue }
            left.insert(from)
            await send(member, to: zone)
        }
        await pauseUnheard(left)
    }

    private func send(_ member: String, to zone: Zone) async {
        location[member] = zone.id == Self.everywhereID ? nil : zone.id
        if member.hasPrefix("airplay:") {
            await speakers.move(String(member.dropFirst("airplay:".count)), to: zone.group)
        } else if let session = sessions[member] {
            await move(session, to: zone)
        }
    }

    private func pauseUnheard(_ ids: Set<String>) async {
        for id in ids {
            guard let zone = zones[id], !(await zone.group.hasListeners()) else { continue }
            await zone.engine.pause()
        }
    }

    // MARK: The user's groups

    func addGroup(name: String) async {
        let group = ServerStore.SyncGroup(id: Self.groupPrefix + UUID().uuidString.lowercased(), name: name, members: [])
        syncGroups.append(group)
        _ = await makeZone(id: group.id, name: name)
        save()
    }

    func deleteGroup(_ id: String) async {
        guard let index = syncGroups.firstIndex(where: { $0.id == id }) else { return }
        let members = syncGroups.remove(at: index).members
        if let zone = zones.removeValue(forKey: id) {
            await zone.engine.stop()
            if let everywhere {
                for member in members where location[member.id] == id { await send(member.id, to: everywhere) }
            }
        }
        save()
    }

    /// Put a speaker in a group, or take it out. A group that plays takes it in at once; one
    /// taken out goes back to Everywhere.
    func setMember(_ member: ServerStore.SyncGroup.Member, in id: String, included: Bool) async {
        guard let index = syncGroups.firstIndex(where: { $0.id == id }), let zone = zones[id] else { return }
        syncGroups[index].members.removeAll { $0.id == member.id }
        if included { syncGroups[index].members.append(member) }
        save()
        if included {
            let from = zoneID(of: member.id)
            if await zone.engine.snapshot().state == .playing, from != id {
                await send(member.id, to: zone)
                await pauseUnheard([from])
            }
        } else if location[member.id] == id, let everywhere {
            await send(member.id, to: everywhere)
            await pauseUnheard([id])
        }
    }

    private func save() {
        store.syncGroups = syncGroups
        onChange(syncGroups)
    }
}
