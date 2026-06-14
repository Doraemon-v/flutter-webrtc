#ifndef FLUTTER_WEBRTC_AUDIO_MANAGER_H_
#define FLUTTER_WEBRTC_AUDIO_MANAGER_H_

#include "audio_processing_adapter.h"
#include "rtc_audio_processing.h"

namespace flutter_webrtc_plugin {

// Singleton that owns the capture/render AudioProcessingAdapters and wires
// them to the underlying RTCAudioProcessing once the plugin is initialized.
class AudioManager {
 public:
  static AudioManager* sharedInstance();

  AudioProcessingAdapter* capturePostProcessingAdapter() {
    return &capture_adapter_;
  }
  AudioProcessingAdapter* renderPreProcessingAdapter() {
    return &render_adapter_;
  }

  // Called once by FlutterWebRTCBase after obtaining RTCAudioProcessing.
  void AttachToAudioProcessing(
      libwebrtc::scoped_refptr<libwebrtc::RTCAudioProcessing> audio_processing);

  bool attached() const { return attached_; }

 private:
  AudioManager() = default;
  ~AudioManager() = default;

  AudioProcessingAdapter capture_adapter_;
  AudioProcessingAdapter render_adapter_;
  bool attached_ = false;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_AUDIO_MANAGER_H_
