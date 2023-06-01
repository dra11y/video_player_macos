import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'video_player_macos_platform_interface.dart';

/// An implementation of [VideoPlayerMacosPlatform] that uses method channels.
class MethodChannelVideoPlayerMacos extends VideoPlayerMacosPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('video_player_macos');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
