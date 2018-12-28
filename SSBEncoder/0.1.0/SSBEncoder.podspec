#
# Be sure to run `pod lib lint SSBEncoder.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'SSBEncoder'
  s.version          = '0.1.0'
  s.summary          = '直播编解码相关'

  s.description      = <<-DESC
  直播音视频编解码
                       DESC

  s.homepage         = 'https://github.com/AmatsuZero/SSBEncoder'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AmatsuZero' => 'jiangzhenhua@baidu.com' }
  s.source           = { :git => 'https://github.com/AmatsuZero/SSBEncoder.git', :tag => s.version.to_s}
  s.swift_version = '4.0'
  s.ios.deployment_target = '8.0'
  s.source_files = 'SSBEncoder/Classes/**/*'
  s.frameworks = 'UIKit', 'AVFoundation', 'CoreMedia', 'VideoToolbox'
 
end
