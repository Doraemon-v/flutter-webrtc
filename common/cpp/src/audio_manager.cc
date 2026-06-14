#include "audio_manager.h"

namespace flutter_webrtc_plugin {

AudioManager* AudioManager::sharedInstance() {
  static AudioManager instance;
  return &instance;
}

void AudioManager::AttachToAudioProcessing(
    libwebrtc::scoped_refptr<libwebrtc::RTCAudioProcessing> audio_processing) {
  if (!audio_processing.get() || attached_) {
    return;
  }
  audio_processing->SetCapturePostProcessing(&capture_adapter_);
  audio_processing->SetRenderPreProcessing(&render_adapter_);
  attached_ = true;
}

}  // namespace flutter_webrtc_plugin
