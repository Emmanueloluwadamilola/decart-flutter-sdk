#
# CocoaPods manifest for decart_vton_flutter.
#
# READ THIS BEFORE FILING A BUILD BUG.
#
# This plugin cannot be built through CocoaPods. The Decart iOS SDK
# (github.com/DecartAI/decart-ios) is distributed exclusively through Swift
# Package Manager — it publishes no podspec, and its transitive dependency
# shareup/websocket-apple has no CocoaPods presence either. There is no
# podspec that could honestly declare `DecartSDK` as a dependency.
#
# This file exists only so that `pod install` in a CocoaPods-based Flutter iOS
# project does not fail with a confusing "no podspec found" error before it can
# tell you the real problem.
#
# The fix is one command:
#
#     flutter config --enable-swift-package-manager
#
# then delete ios/Podfile.lock and ios/Pods, and rebuild. Flutter will use
# ios/decart_vton_flutter/Package.swift instead of this file.
#
Pod::Spec.new do |s|
  s.name             = 'decart_vton_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Realtime virtual try-on for Flutter (Decart Lucy VTON).'
  s.description      = <<-DESC
Flutter plugin wrapping the native Decart realtime SDKs for virtual try-on.
The iOS side requires Flutter's Swift Package Manager integration; see the
comments at the top of this podspec.
                       DESC
  s.homepage         = 'https://github.com/dextercyberlabs/decart_vton_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dextercyberlabs' => 'devs@dextercyberlabs.com' }
  s.source           = { :path => '.' }

  # No source_files: the Swift lives under decart_vton_flutter/Sources and is
  # compiled by SwiftPM. Listing it here would produce a target that fails with
  # "no such module 'DecartSDK'", which is a worse error than the explicit one
  # printed below.
  s.source_files     = []
  s.dependency 'Flutter'
  s.platform         = :ios, '17.0'
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }

  s.prepare_command = <<-CMD
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo " decart_vton_flutter: Swift Package Manager is REQUIRED on iOS."
    echo ""
    echo " The Decart iOS SDK is SPM-only and cannot be resolved by CocoaPods."
    echo " Run:  flutter config --enable-swift-package-manager"
    echo " then: rm -rf ios/Pods ios/Podfile.lock && flutter clean"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
  CMD
end
