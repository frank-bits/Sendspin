import Foundation
import SendspinClientKit

/// The AirPlay speakers on the network, and which of them play in the group. A speaker that's
/// switched on is taken over when the music starts and let go soon after it stops.
public actor AirPlaySpeakers {
    public enum Status: Sendable, Equatable {
        case idle
        case connecting
        case playing
        case failed(String)
    }

    public struct Speaker: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var model: String?
        /// It plays with the group.
        public var enabled: Bool
        public var volume: Int
        public var muted: Bool
        /// It's on the network now.
        public var present: Bool
        public var status: Status
    }

    /// How far ahead of its play time a speaker gets its audio: the two seconds this form of
    /// AirPlay buffers, and a little for the way there.
    static let leadMs = 2_100

    /// The group a speaker plays with unless another called it in.
    private let home: PlaybackGroup
    /// The group each speaker was last called in to.
    private var groups: [String: PlaybackGroup] = [:]
    private let store: ServerStore
    private let onChange: @Sendable ([Speaker]) -> Void
    private var found: [String: AirPlaySpeaker] = [:]
    private var settings: [String: ServerStore.AirPlaySetting] = [:]
    private var outputs: [String: AirPlayOutput] = [:]
    private var statuses: [String: Status] = [:]
    private var browsing: Task<Void, Never>?

    init(group: PlaybackGroup, store: ServerStore, onChange: @escaping @Sendable ([Speaker]) -> Void) {
        home = group
        self.store = store
        self.onChange = onChange
    }

    func start() {
        settings = store.airPlaySettings
        browsing = Task { [weak self] in
            for await speakers in AirPlayBrowser.browse() { await self?.found(speakers) }
        }
    }

    func stop() async {
        browsing?.cancel()
        for id in Array(outputs.keys) { await detach(id) }
    }

    public var speakers: [Speaker] {
        Set(found.keys).union(settings.filter(\.value.enabled).keys).map { id in
            let setting = settings[id]
            return Speaker(id: id, name: found[id]?.name ?? setting?.name ?? id, model: found[id]?.model,
                           enabled: setting?.enabled ?? false, volume: setting?.volume ?? ServerStore.AirPlaySetting.startVolume,
                           muted: setting?.muted ?? false, present: found[id] != nil, status: statuses[id] ?? .idle)
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    private func found(_ speakers: [AirPlaySpeaker]) async {
        found = Dictionary(speakers.map { ($0.id, $0) }) { first, _ in first }
        for id in Array(outputs.keys) where found[id] == nil { await detach(id) }
        for id in found.keys where settings[id]?.enabled == true { await attach(id) }
        onChange(self.speakers)
    }

    /// Have a speaker play with the group, or not.
    public func setEnabled(_ id: String, _ enabled: Bool) async {
        change(id) { $0.enabled = enabled }
        if enabled { await attach(id) } else { await detach(id) }
        onChange(speakers)
    }

    public func setVolume(_ id: String, _ volume: Int) async {
        change(id) { $0.volume = max(0, min(100, volume)) }
        await apply(id)
    }

    public func setMuted(_ id: String, _ muted: Bool) async {
        change(id) { $0.muted = muted }
        await apply(id)
    }

    private func change(_ id: String, _ body: (inout ServerStore.AirPlaySetting) -> Void) {
        var setting = settings[id] ?? ServerStore.AirPlaySetting(name: found[id]?.name ?? id)
        if let name = found[id]?.name { setting.name = name }
        body(&setting)
        settings[id] = setting
        store.airPlaySettings = settings
    }

    private func apply(_ id: String) async {
        if let setting = settings[id] { await outputs[id]?.stream.setVolume(setting.volume, muted: setting.muted) }
        onChange(speakers)
        await (groups[id] ?? home).membersChanged()
    }

    /// Have a speaker play with `group` from now on.
    func move(_ id: String, to group: PlaybackGroup) async {
        guard (groups[id] ?? home) !== group else { return }
        await unhook(id)
        groups[id] = group
        await hook(id)
    }

    /// Put a speaker's output and its volume into its group.
    private func hook(_ id: String) async {
        guard let output = outputs[id] else { return }
        let group = groups[id] ?? home
        await group.add(output: output, leadMs: Self.leadMs)
        // Its volume counts in the group's, and the group's volume moves it.
        await group.setLocalMember(LocalMember(
            state: { [weak self] in await self?.member(id) },
            setVolume: { [weak self] in await self?.setVolume(id, $0) },
            setMuted: { [weak self] in await self?.setMuted(id, $0) }), id: Self.memberID(id))
    }

    private func unhook(_ id: String) async {
        guard let output = outputs[id] else { return }
        let group = groups[id] ?? home
        await group.remove(output: output)
        await group.setLocalMember(nil, id: Self.memberID(id))
    }

    private func attach(_ id: String) async {
        guard let speaker = found[id], outputs[id] == nil else { return }
        let setting = settings[id] ?? ServerStore.AirPlaySetting(name: speaker.name)
        let output = AirPlayOutput(speaker: speaker, volume: setting.volume, muted: setting.muted) { [weak self] status in
            Task { await self?.statusChanged(id, status) }
        }
        outputs[id] = output
        await hook(id)
    }

    private func detach(_ id: String) async {
        guard let output = outputs[id] else { return }
        await unhook(id)
        outputs[id] = nil
        await output.shutdown()
        statuses[id] = nil
    }

    public static func memberID(_ id: String) -> String { "airplay:\(id)" }

    private func member(_ id: String) -> ControllerMember? {
        guard outputs[id] != nil, let setting = settings[id] else { return nil }
        return ControllerMember(inGroup: true, volume: setting.volume, muted: setting.muted, canSetVolume: true, canMute: true)
    }

    private func statusChanged(_ id: String, _ status: AirPlayStream.Status) {
        guard outputs[id] != nil else { return }
        statuses[id] = switch status {
        case .idle: .idle
        case .connecting: .connecting
        case .playing: .playing
        case .failed(let reason): .failed(reason)
        }
        onChange(speakers)
    }
}
