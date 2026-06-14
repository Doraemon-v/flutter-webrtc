#ifndef FLUTTER_WEBRTC_AUDIO_PROCESSING_ADAPTER_H_
#define FLUTTER_WEBRTC_AUDIO_PROCESSING_ADAPTER_H_

#include <mutex>
#include <vector>

#include "rtc_audio_processing.h"

namespace flutter_webrtc_plugin {

// Interface for external audio processors (implemented in the runner).
class ExternalAudioProcessor {
 public:
  virtual void AudioProcessingInitialize(int sample_rate_hz,
                                         int num_channels) = 0;
  virtual void AudioProcessingProcess(int num_bands,
                                      int num_frames,
                                      int buffer_size,
                                      float* buffer) = 0;
  virtual void AudioProcessingRelease() = 0;
  virtual ~ExternalAudioProcessor() = default;
};

// Bridges multiple ExternalAudioProcessors to a single
// RTCAudioProcessing::CustomProcessing slot.
class AudioProcessingAdapter
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  AudioProcessingAdapter() = default;
  ~AudioProcessingAdapter() override = default;

  void AddProcessing(ExternalAudioProcessor* processor);
  void RemoveProcessing(ExternalAudioProcessor* processor);

  // RTCAudioProcessing::CustomProcessing overrides
  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(int num_bands,
               int num_frames,
               int buffer_size,
               float* buffer) override;
  void Reset(int new_rate) override;
  void Release() override;

 private:
  std::mutex mutex_;
  std::vector<ExternalAudioProcessor*> processors_;
  int sample_rate_hz_ = 0;
  int num_channels_ = 0;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_AUDIO_PROCESSING_ADAPTER_H_
