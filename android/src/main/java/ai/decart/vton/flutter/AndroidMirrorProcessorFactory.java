package ai.decart.vton.flutter;

import ai.decart.sdk.realtime.livekit.LiveKitMirrorVideoProcessor;
import livekit.org.webrtc.VideoProcessor;

/**
 * Bridges Decart's mirror processor into the Kotlin controller.
 *
 * <p>The processor is public JVM bytecode but is marked {@code internal} in
 * Kotlin metadata, so Kotlin callers cannot construct it. Java correctly sees
 * the public class. Keeping this tiny boundary lets camera switching reuse the
 * exact processor Decart uses instead of maintaining a second frame-flipping
 * implementation.</p>
 */
final class AndroidMirrorProcessorFactory {
    private AndroidMirrorProcessorFactory() {}

    static VideoProcessor create() {
        return new LiveKitMirrorVideoProcessor();
    }
}
