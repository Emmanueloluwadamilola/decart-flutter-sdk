# Consumer ProGuard/R8 rules for decart_vton_flutter.
#
# The Decart and LiveKit AARs carry the JNI/reflection rules they require. Do
# not duplicate broad namespace keeps here: doing so prevents R8 from removing
# unused SDK code. The unshaded WebRTC dependency is intentionally excluded;
# Decart's AAR still contains one unused legacy helper with those signatures.
-dontwarn org.webrtc.**

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

# Flutter's generated plugin registrant directly references the entry point, so
# it does not require an additional keep rule.
