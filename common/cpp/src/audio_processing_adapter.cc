#include "audio_processing_adapter.h"

#include <algorithm>

namespace flutter_webrtc_plugin {

void AudioProcessingAdapter::AddProcessing(ExternalAudioProcessor* processor) {
  std::lock_guard<std::mutex> lock(mutex_);
  processors_.push_back(processor);
  if (sample_rate_hz_ > 0) {
    processor->AudioProcessingInitialize(sample_rate_hz_, num_channels_);
  }
}

void AudioProcessingAdapter::RemoveProcessing(ExternalAudioProcessor* processor) {
  std::lock_guard<std::mutex> lock(mutex_);
  processors_.erase(
      std::remove(processors_.begin(), processors_.end(), processor),
      processors_.end());
}

void AudioProcessingAdapter::Initialize(int sample_rate_hz, int num_channels) {
  std::lock_guard<std::mutex> lock(mutex_);
  sample_rate_hz_ = sample_rate_hz;
  num_channels_ = num_channels;
  for (auto* p : processors_) {
    p->AudioProcessingInitialize(sample_rate_hz, num_channels);
  }
}

void AudioProcessingAdapter::Process(int num_bands,
                                     int num_frames,
                                     int buffer_size,
                                     float* buffer) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto* p : processors_) {
    p->AudioProcessingProcess(num_bands, num_frames, buffer_size, buffer);
  }
}

void AudioProcessingAdapter::Reset(int new_rate) {
  std::lock_guard<std::mutex> lock(mutex_);
  sample_rate_hz_ = new_rate;
  for (auto* p : processors_) {
    p->AudioProcessingInitialize(new_rate, num_channels_);
  }
}

void AudioProcessingAdapter::Release() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto* p : processors_) {
    p->AudioProcessingRelease();
  }
  processors_.clear();
}

}  // namespace flutter_webrtc_plugin
