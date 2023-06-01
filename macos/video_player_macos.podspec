#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint video_player_macos.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'video_player_macos'
  s.version          = '0.0.1'
  s.summary          = 'A Flutter video_player implementation for macOS.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'https://github.com/dra11y/video_player_macos'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dr. Accessibility' => 'tom@dra11y.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
