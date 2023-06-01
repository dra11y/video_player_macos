import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_player_macos_method_channel.dart';

abstract class VideoPlayerMacosPlatform extends PlatformInterface {
  /// Constructs a VideoPlayerMacosPlatform.
  VideoPlayerMacosPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoPlayerMacosPlatform _instance = MethodChannelVideoPlayerMacos();

  /// The default instance of [VideoPlayerMacosPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoPlayerMacos].
  static VideoPlayerMacosPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoPlayerMacosPlatform] when
  /// they register themselves.
  static set instance(VideoPlayerMacosPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
