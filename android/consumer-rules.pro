# Consumer ProGuard/R8 rules for decart_vton_flutter.
#
# The Decart SDK ships its own consumer-rules.pro with equivalent keeps. These
# are duplicated here deliberately: the SDK is resolved through JitPack, and a
# JitPack-built AAR does not always carry its consumer rules through intact. A
# duplicate keep rule is free; a missing one produces a release-only crash deep
# inside WebRTC that is miserable to diagnose.

# Decart SDK — reflection over model/serializer classes.
-keep class ai.decart.sdk.** { *; }

# WebRTC (both the plain and LiveKit-shaded package names) — JNI bound.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
-keep class livekit.org.webrtc.** { *; }
-dontwarn livekit.org.webrtc.**

# LiveKit.
-keep class io.livekit.** { *; }
-dontwarn io.livekit.**

# kotlinx.serialization — the signalling protocol is @Serializable.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class ai.decart.sdk.**$$serializer { *; }
-keepclassmembers class ai.decart.sdk.** {
    *** Companion;
}
-keepclasseswithmembers class ai.decart.sdk.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# This plugin's own entry point, referenced by name from the Flutter embedding.
-keep class ai.decart.vton.flutter.DecartVtonPlugin { *; }
