// Which version of a video to play: the original file or the version the server converts.
//
// Pure rules, no Flutter and no player: the player asks here, and test/playback_rules_test.dart
// checks every case, so a change can't quietly break one of them.

/// Dolby Vision with no HDR10 or SDR picture inside (Profile 5). Jellyfin calls it "DOVI";
/// the kinds with a fallback picture are "DOVIWithHDR10", "DOVIWithSDR" and so on.
bool isDolbyVisionOnly(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? const [];
  for (final s in streams) {
    if (s is Map && s['Type'] == 'Video') return s['VideoRangeType'] == 'DOVI';
  }
  return false;
}

/// Disc images and disc folders (ISO, Blu-ray, DVD): they can't be streamed as one file.
bool isDisc(dynamic item) {
  final type = (item['VideoType'] ?? 'VideoFile').toString();
  final container = (item['Container'] ?? '').toString().toLowerCase();
  return type != 'VideoFile' || const ['iso', 'bluray', 'dvd'].contains(container);
}

/// The step of "adapting to this device" that means the server's version. Dolby Vision 5
/// has fewer steps before it, because lowering the original's quality doesn't fix its colours.
int serverStepFor(dynamic item) => isDolbyVisionOnly(item) ? 1 : 2;

/// True to start with the server's version, false for the original file.
///
/// - [downloaded]: the file is on this device. Always played from here, nothing else applies.
/// - [mode]: the Playback choice: 'auto', 'original' or 'server'.
/// - [phone]: iPhone, iPad or Android.
/// - [level]: how far "adapting to this device" has gone for this kind of file (0 = original
///   at full quality).
bool startWithServer({
  required dynamic item,
  required bool downloaded,
  required String mode,
  required bool phone,
  int level = 0,
}) {
  if (downloaded) return false;
  if (isDisc(item)) return true;
  if (mode == 'server') return true;
  if (mode == 'original') return false;
  // Automatic.
  if (level >= serverStepFor(item)) return true;
  // Phones can't fix Dolby Vision 5's colours (pink and green) like mpv on a PC can.
  if (phone && isDolbyVisionOnly(item)) return true;
  return false;
}

// ----- What this copy's video engine can play -----
//
// Some builds of the video engine leave codecs out to stay small. media_kit's Windows engine
// (the one Rollback ships on Windows) has no Dolby TrueHD decoder and no Blu-ray (PGS)
// subtitle decoder: the audio plays silent and the subtitles stay blank. Rollback's own LGPL
// engines (Linux, and Windows once it ships its own) have both.

/// The engine decoder a Jellyfin codec needs, for the codecs some builds leave out.
/// null: a codec every build has, nothing to check.
String? engineDecoderFor(String? codec) {
  switch ((codec ?? '').toLowerCase()) {
    case 'truehd':
      return 'truehd';
    case 'mlp':
      return 'mlp';
    case 'pgssub':
    case 'pgs':
    case 'hdmv_pgs_subtitle':
      return 'pgssub';
  }
  return null;
}

/// Whether the engine can play [stream] (one of Jellyfin's audio or subtitle streams).
///
/// [decoders]: the engine's decoder list (mpv's decoder-list). Empty means unknown: assume yes,
/// so an engine that can't tell us never loses a track.
/// mpv lists audio and video decoders only, not subtitle ones, so Blu-ray subtitles follow
/// TrueHD: the builds that leave out one leave out both.
bool engineCanPlay(dynamic stream, Set<String> decoders) {
  final need = engineDecoderFor(stream is Map ? stream['Codec']?.toString() : null);
  if (need == null || decoders.isEmpty) return true;
  if (need == 'pgssub') return decoders.contains('truehd');
  return decoders.contains(need);
}

bool _isCommentaryOrDescription(dynamic s) {
  final t = '${s['Title'] ?? ''} ${s['DisplayTitle'] ?? ''}'.toLowerCase();
  return t.contains('comment') || t.contains('descri') || RegExp(r'\bad\b').hasMatch(t);
}

/// Another audio stream the engine can play, in place of [chosen] (Blu-ray remuxes usually
/// carry an AC3, E-AC3 or DTS track next to TrueHD). Same language, same kind (a commentary
/// or audio description only replaces one of its own kind), then the most channels; the
/// earlier stream wins a tie. null: there is none.
dynamic playableAudioInstead(List streams, dynamic chosen, Set<String> decoders) {
  if (chosen is! Map) return null;
  final lang = (chosen['Language'] ?? '').toString().toLowerCase();
  final kind = _isCommentaryOrDescription(chosen);
  dynamic pick;
  var best = -1;
  for (final s in streams) {
    if (s is! Map || s['Type'] != 'Audio' || identical(s, chosen) || s['Index'] == chosen['Index']) continue;
    if ((s['Language'] ?? '').toString().toLowerCase() != lang) continue;
    if (_isCommentaryOrDescription(s) != kind) continue;
    if (!engineCanPlay(s, decoders)) continue;
    final channels = (s['Channels'] as int?) ?? 0;
    if (channels > best) {
      best = channels;
      pick = s;
    }
  }
  return pick;
}
