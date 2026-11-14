# Upstream code

Files under `Sources/SendspinClientKit/Upstream/` and `Sources/SendspinClientKit/Server/`, and
the tests named below, come from
[Sendspin/sendspin-mac](https://github.com/Sendspin/sendspin-mac), commit
`32444d6efbea3208b9b7b373091ea6c38447a4e9` (2026-11-03), licensed under Apache-2.0
(see `UPSTREAM-LICENSE`).

Copied unchanged from `Packages/SendspinServerKit/Sources/SendspinServerKit/`:

- `Noise/Noise.swift`, `Noise/SendspinKeys.swift`, `Noise/PairingToken.swift`,
  `Noise/DynamicPairingCode.swift`, `Noise/CPace.swift`
- `Transport/SecureChannel.swift`, `Transport/WebSocketConnection.swift`
- `Client/TimeFilter.swift`, `Clock.swift`, `Log.swift`
- `Discovery/MusicAssistantBrowser.swift`

Excerpted into `Upstream/Support.swift`: `MessageCoding`, `NoiseHandshakeMessage`,
`AudioCodec`, `AudioFormatSpec`, `SessionError`, `OnceFlag`, `String.truncated(toUTF8Bytes:)`.

Adapted (modified) from upstream, outside `Upstream/`:

- `ClientSession.swift`, `ClientSession+Pairing.swift`, `ClientSession+Clock.swift`
  from `Client/SourceSession.swift`
- `ClientCredentials.swift` from `Client/SourceCredentials.swift` and `Client/SourceClient.swift`
- `ClientMessages.swift` from `Client/ClientMessages.swift`

- `Audio/PlayoutBuffer.swift` from `SendspinAudio/PlayoutBuffer.swift` (re-anchoring on each
  write, `truncate(fromUs:)`)
- `Audio/AudioOutput.swift` from `SendspinAudio/LocalPlayer.swift`

Also copied unchanged: `Upstream/Audio/SourceDecoder.swift` from `Audio/SourceDecoder.swift`.

Tests copied with only the module name changed: `NoiseTests.swift`, `CPaceTests.swift`,
`DynamicPairingCodeTests.swift`, `PlayoutBufferTests.swift`.

## The server's side (`Sources/SendspinClientKit/Server/`)

Copied unchanged from `Packages/SendspinServerKit/Sources/SendspinServerKit/`:

- `Protocol/AudioFrame.swift`, `PlayerPairings.swift`, `Noise/ServerIdentity.swift`
- `Audio/PCM.swift`, `Audio/FLACEncoder.swift`, `Audio/PlayerAudioPipeline.swift`,
  `Audio/InputTimeline.swift`, `Audio/Visualizer.swift`

Adapted (modified) from upstream:

- `Messages.swift` from `Protocol/Messages.swift`: without the types `Upstream/Support.swift`
  and `ClientMessages.swift` already hold; `ControllerState` renamed `GroupControllerState` and
  `PlayerState` renamed `ReportedPlayerState`, which the client side names differently;
  `ControllerCommand` gained `position_ms` and `offset_ms`, `GroupControllerState` gained
  `seek_max_ms`, and `ServerState.metadata` carries a full `MetadataState`.
- `PlayerStatus.swift`, `PlayerSession.swift` and `PlayerSession+Connection.swift`,
  `+Messages.swift`, `+Streaming.swift`, `+Input.swift`, `+Pairing.swift` from
  `PlayerSession.swift`: one file split into several, its `private` members made internal for
  that. Added: pairing on a connection the player opened (`pair(_:)`, and such a player is held
  rather than turned away when it needs pairing), track details for the metadata role
  (`updateMetadata`), `stream/clear` (`clearStream`), and 43-character group identifiers.
- `PlaybackGroup.swift`: a queue's transport commands and track details (`setMedia`,
  `setMetadata`), `clear()`, `requiredLeadMs()`, the group's volume and mute as methods
  (`levels()`, `setVolume`, `setMuted`, `members()`), and a player that connected to us is
  dropped from the group when its connection ends.
- `GroupVolume.swift`: `GroupControllerState.init(group:media:)` takes the queue's commands.
- `ServiceListener.swift`: extra TXT keys; its `String` extension lives in `Upstream/Support.swift`.

New here, not from upstream: `ServerMedia.swift`.

Tests copied with the module name and the two renamed types changed: `ServerProtocolTests.swift`,
`ServerAudioPipelineTests.swift`, `ServerFLACEncoderTests.swift`, `ServerVisualizerTests.swift`,
`ServerInputTimelineTests.swift`, `ServerGroupVolumeTests.swift`.
