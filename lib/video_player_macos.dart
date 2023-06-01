
import 'video_player_macos_platform_interface.dart';

class VideoPlayerMacos {
  Future<String?> getPlatformVersion() {
    return VideoPlayerMacosPlatform.instance.getPlatformVersion();
  }
}
