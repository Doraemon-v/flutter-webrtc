#import "MLVirtualBackgroundProcessor.h"

#import <CoreImage/CoreImage.h>
#import <CoreImage/CIFilterBuiltins.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Vision/Vision.h>
#import <os/lock.h>

#import "FlutterRTCFrameCapturer.h"

typedef NS_ENUM(NSInteger, MLVirtualBackgroundMode) {
  MLVirtualBackgroundModeOff = 0,
  MLVirtualBackgroundModeBlur = 1,
  MLVirtualBackgroundModeImage = 2,
};
@class MLVirtualBackgroundProcessor;

@interface MLVirtualBackgroundFrameContext : NSObject
@property(nonatomic) MLVirtualBackgroundMode mode;
@property(nonatomic) CGFloat blurRadius;
@property(nonatomic, strong) CIImage* backgroundImage;
@end

@protocol MLVirtualBackgroundEngineBackend <NSObject>
@property(nonatomic, readonly) NSString* backendName;
- (RTC_OBJC_TYPE(RTCVideoFrame)*)processFrame:(RTC_OBJC_TYPE(RTCVideoFrame)*)frame
                                      context:(MLVirtualBackgroundFrameContext*)context
                                    processor:(MLVirtualBackgroundProcessor*)processor API_AVAILABLE(macos(12.0));
- (void)reset;
@end

@interface MLVirtualBackgroundProcessor (AppleVisionFallbackEngine)
- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame)*)frame;
- (CVPixelBufferRef)copyMaskBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   timeStampNs:(int64_t)timeStampNs API_AVAILABLE(macos(12.0));
- (CGSize)realtimeCompositeSizeForWidth:(size_t)width height:(size_t)height;
- (CIImage*)sourceImageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                            outputSize:(CGSize)outputSize API_AVAILABLE(macos(12.0));
- (CIImage*)preparedMaskImageFromPixelBuffer:(CVPixelBufferRef)maskBuffer
                                      extent:(CGRect)extent API_AVAILABLE(macos(12.0));
- (CIImage*)stabilizedMaskImage:(CIImage*)maskImage
                         extent:(CGRect)extent
                   timeStampNs:(int64_t)timeStampNs API_AVAILABLE(macos(12.0));
- (CIImage*)backgroundImageForMode:(MLVirtualBackgroundMode)mode
                       sourceImage:(CIImage*)sourceImage
                        blurRadius:(CGFloat)blurRadius
                   backgroundImage:(CIImage*)backgroundImage API_AVAILABLE(macos(12.0));
- (CIImage*)sourceImageBySuppressingEdgeContamination:(CIImage*)sourceImage
                                      backgroundImage:(CIImage*)backgroundImage
                                          subjectMask:(CIImage*)subjectMask
                                               extent:(CGRect)extent API_AVAILABLE(macos(12.0));
- (CIImage*)compositeImageByProtectingForegroundEdges:(CIImage*)compositeImage
                                          sourceImage:(CIImage*)sourceImage
                                          subjectMask:(CIImage*)subjectMask
                                               extent:(CGRect)extent API_AVAILABLE(macos(12.0));
- (CVPixelBufferRef)newOutputBufferWithWidth:(size_t)width height:(size_t)height;
- (BOOL)renderImage:(CIImage*)image
      toPixelBuffer:(CVPixelBufferRef)pixelBuffer
             bounds:(CGRect)bounds API_AVAILABLE(macos(12.0));
@end

@implementation MLVirtualBackgroundFrameContext
@end

@interface MLAppleVisionFallbackVirtualBackgroundEngine : NSObject <MLVirtualBackgroundEngineBackend>
@end

@implementation MLAppleVisionFallbackVirtualBackgroundEngine

- (NSString*)backendName {
  return @"AppleVisionFallback";
}

- (RTC_OBJC_TYPE(RTCVideoFrame)*)processFrame:(RTC_OBJC_TYPE(RTCVideoFrame)*)frame
                                      context:(MLVirtualBackgroundFrameContext*)context
                                    processor:(MLVirtualBackgroundProcessor*)processor API_AVAILABLE(macos(12.0)) {
  CVPixelBufferRef inputBuffer = [processor copyPixelBufferFromFrame:frame];
  if (inputBuffer == nil) {
    return frame;
  }

  CVPixelBufferRef maskBuffer = [processor copyMaskBufferForPixelBuffer:inputBuffer
                                                            timeStampNs:frame.timeStampNs];
  if (maskBuffer == nil) {
    CVPixelBufferRelease(inputBuffer);
    return frame;
  }

  CGSize outputSize = [processor realtimeCompositeSizeForWidth:CVPixelBufferGetWidth(inputBuffer)
                                                        height:CVPixelBufferGetHeight(inputBuffer)];
  CIImage* sourceImage = [processor sourceImageFromPixelBuffer:inputBuffer
                                                    outputSize:outputSize];
  CIImage* preparedMask = [processor preparedMaskImageFromPixelBuffer:maskBuffer
                                                               extent:sourceImage.extent];
  CIImage* stabilizedMask = [processor stabilizedMaskImage:preparedMask
                                                    extent:sourceImage.extent
                                               timeStampNs:frame.timeStampNs];
  CIImage* replacementBackground = [processor backgroundImageForMode:context.mode
                                                         sourceImage:sourceImage
                                                          blurRadius:context.blurRadius
                                                     backgroundImage:context.backgroundImage];
  if (stabilizedMask == nil || replacementBackground == nil) {
    CVPixelBufferRelease(maskBuffer);
    CVPixelBufferRelease(inputBuffer);
    return frame;
  }

  CIImage* decontaminatedSourceImage = [processor sourceImageBySuppressingEdgeContamination:sourceImage
                                                                            backgroundImage:replacementBackground
                                                                                subjectMask:stabilizedMask
                                                                                     extent:sourceImage.extent];
  CIFilter<CIBlendWithMask>* blendFilter = [CIFilter blendWithMaskFilter];
  blendFilter.inputImage = decontaminatedSourceImage ?: sourceImage;
  blendFilter.backgroundImage = replacementBackground;
  blendFilter.maskImage = stabilizedMask;
  CIImage* outputImage = [blendFilter.outputImage imageByCroppingToRect:sourceImage.extent];
  outputImage = [processor compositeImageByProtectingForegroundEdges:outputImage
                                                         sourceImage:sourceImage
                                                         subjectMask:stabilizedMask
                                                              extent:sourceImage.extent];
  if (outputImage == nil) {
    CVPixelBufferRelease(maskBuffer);
    CVPixelBufferRelease(inputBuffer);
    return frame;
  }

  CVPixelBufferRef outputBuffer = [processor newOutputBufferWithWidth:(size_t)outputSize.width
                                                               height:(size_t)outputSize.height];
  if (outputBuffer == nil) {
    CVPixelBufferRelease(maskBuffer);
    CVPixelBufferRelease(inputBuffer);
    return frame;
  }

  if (![processor renderImage:outputImage
                toPixelBuffer:outputBuffer
                       bounds:sourceImage.extent]) {
    CVPixelBufferRelease(outputBuffer);
    CVPixelBufferRelease(maskBuffer);
    CVPixelBufferRelease(inputBuffer);
    return frame;
  }

  RTCCVPixelBuffer* rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:outputBuffer];
  RTC_OBJC_TYPE(RTCVideoFrame)* processedFrame =
      [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                   rotation:frame.rotation
                                timeStampNs:frame.timeStampNs];
  CVPixelBufferRelease(outputBuffer);
  CVPixelBufferRelease(maskBuffer);
  CVPixelBufferRelease(inputBuffer);
  return processedFrame;
}

- (void)reset {}

@end


static const int64_t MLVirtualBackgroundEnterpriseLiveSegmentationIntervalNs = 16666667;
static const int64_t MLVirtualBackgroundMaskHoldWindowNs = 180000000;
static const int64_t MLVirtualBackgroundMaximumMaskAgeNs = 220000000;
static const CGFloat MLVirtualBackgroundMinimumSubjectCoverage = 0.014;
static const CGFloat MLVirtualBackgroundMaximumCoverageDropRatio = 0.55;
static const size_t MLVirtualBackgroundMaximumSegmentationPixels = 518400;
static const size_t MLVirtualBackgroundMaximumCompositePixels = 518400;
static const CGFloat MLVirtualBackgroundHaloTrimRadius = 1.20;
static const CGFloat MLVirtualBackgroundEdgeRestoreRadius = 0.30;
static const CGFloat MLVirtualBackgroundEdgeFeatherRadius = 0.34;
static const CGFloat MLVirtualBackgroundSolidCoreErodeRadius = 1.70;
static const CGFloat MLVirtualBackgroundForegroundCoreErodeRadius = 3.45;
static const CGFloat MLVirtualBackgroundFringeSuppressionRadius = 2.85;
static const CGFloat MLVirtualBackgroundFringeSuppressionWeight = 0.98;
static const CGFloat MLVirtualBackgroundEdgeDecontaminationRadius = 3.60;
static const CGFloat MLVirtualBackgroundEdgeDecontaminationWeight = 0.96;

@implementation MLVirtualBackgroundProcessor {
  os_unfair_lock _lock;
  CIContext* _ciContext;
  MLVirtualBackgroundMode _mode;
  CGFloat _blurRadius;
  CIImage* _backgroundImage;
  dispatch_queue_t _segmentationQueue;
  BOOL _segmentationInFlight;
  int64_t _lastSegmentationRequestTimestampNs;
  NSUInteger _processingGeneration;
  CVPixelBufferRef _lastMaskBuffer;
  int64_t _lastMaskTimestampNs;
  CGFloat _lastMaskCoverage;
  CIImage* _lastPreparedMaskImage;
  int64_t _lastPreparedMaskTimestampNs;
  CVPixelBufferPoolRef _outputPixelBufferPool;
  size_t _outputPixelBufferPoolWidth;
  size_t _outputPixelBufferPoolHeight;
  id<MLVirtualBackgroundEngineBackend> _engineBackend;
}

+ (NSDictionary*)capabilities {
  if (@available(macOS 12.0, *)) {
    return @{
      @"available" : @YES,
      @"supportsBlur" : @YES,
      @"supportsImage" : @YES,
      @"platformLabel" : @"macOS",
      @"engineBackend" : @"AppleVisionFallback",
      @"enginePipeline" : @"Vision/CoreImage fallback"
    };
  }

  return @{
    @"available" : @NO,
    @"supportsBlur" : @NO,
    @"supportsImage" : @NO,
    @"platformLabel" : @"macOS",
    @"reason" : @"需要 macOS 12 或更高版本"
  };
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _mode = MLVirtualBackgroundModeOff;
    _blurRadius = 18.0;
    _segmentationQueue = dispatch_queue_create("top.musiclive.classroom.virtual-background.segmentation", DISPATCH_QUEUE_SERIAL);
    _segmentationInFlight = NO;
    _lastSegmentationRequestTimestampNs = 0;
    _processingGeneration = 0;
    _lastMaskBuffer = nil;
    _lastMaskTimestampNs = 0;
    _lastMaskCoverage = 0.0;
    _lastPreparedMaskImage = nil;
    _lastPreparedMaskTimestampNs = 0;
    _outputPixelBufferPool = nil;
    _outputPixelBufferPoolWidth = 0;
    _outputPixelBufferPoolHeight = 0;
    _engineBackend = [MLAppleVisionFallbackVirtualBackgroundEngine new];
    _ciContext = [CIContext contextWithOptions:@{
      kCIContextUseSoftwareRenderer : @NO,
      kCIContextPriorityRequestLow : @YES
    }];
  }
  return self;
}

- (void)dealloc {
  if (_lastMaskBuffer != nil) {
    CVPixelBufferRelease(_lastMaskBuffer);
    _lastMaskBuffer = nil;
  }
  if (_outputPixelBufferPool != nil) {
    CVPixelBufferPoolRelease(_outputPixelBufferPool);
    _outputPixelBufferPool = nil;
  }
  _lastPreparedMaskImage = nil;
}

- (BOOL)updateWithOptions:(NSDictionary*)options error:(NSError**)error {
  NSDictionary* capabilities = [MLVirtualBackgroundProcessor capabilities];
  if ([capabilities[@"available"] boolValue] == NO) {
    if (error != nil) {
      *error = [NSError errorWithDomain:@"MusicLiveVirtualBackground"
                                   code:-1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : capabilities[@"reason"] ?: @"当前系统不支持虚拟背景"
                               }];
    }
    return NO;
  }

  NSString* mode = [options[@"mode"] isKindOfClass:[NSString class]] ? options[@"mode"] : @"off";
  CIImage* nextBackgroundImage = nil;
  MLVirtualBackgroundMode nextMode = MLVirtualBackgroundModeOff;

  if ([mode isEqualToString:@"blur"]) {
    nextMode = MLVirtualBackgroundModeBlur;
  } else if ([mode isEqualToString:@"image"]) {
    nextMode = MLVirtualBackgroundModeImage;
    NSString* imagePath = [options[@"imagePath"] isKindOfClass:[NSString class]] ? options[@"imagePath"] : nil;
    if (imagePath.length == 0) {
      if (error != nil) {
        *error = [NSError errorWithDomain:@"MusicLiveVirtualBackground"
                                     code:-2
                                 userInfo:@{
                                   NSLocalizedDescriptionKey : @"未找到背景图片文件"
                                 }];
      }
      return NO;
    }

    NSURL* imageUrl = [NSURL fileURLWithPath:imagePath];
    nextBackgroundImage = [CIImage imageWithContentsOfURL:imageUrl];
    if (nextBackgroundImage == nil) {
      if (error != nil) {
        *error = [NSError errorWithDomain:@"MusicLiveVirtualBackground"
                                     code:-3
                                 userInfo:@{
                                   NSLocalizedDescriptionKey : @"背景图片解码失败"
                                 }];
      }
      return NO;
    }
  }

  os_unfair_lock_lock(&_lock);
  _processingGeneration += 1;
  _mode = nextMode;
  _blurRadius = [options[@"blurRadius"] respondsToSelector:@selector(doubleValue)]
      ? MAX(8.0, [options[@"blurRadius"] doubleValue])
      : 18.0;
  _backgroundImage = nextBackgroundImage;
  _segmentationInFlight = NO;
  _lastSegmentationRequestTimestampNs = 0;
  if (_mode == MLVirtualBackgroundModeOff && _lastMaskBuffer != nil) {
    CVPixelBufferRelease(_lastMaskBuffer);
    _lastMaskBuffer = nil;
    _lastMaskTimestampNs = 0;
    _lastMaskCoverage = 0.0;
  }
  if (_mode == MLVirtualBackgroundModeOff) {
    _lastPreparedMaskImage = nil;
    _lastPreparedMaskTimestampNs = 0;
    [_engineBackend reset];
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (RTC_OBJC_TYPE(RTCVideoFrame)*)onFrame:(RTC_OBJC_TYPE(RTCVideoFrame)*)frame {
  if (@available(macOS 12.0, *)) {
    os_unfair_lock_lock(&_lock);
    MLVirtualBackgroundMode mode = _mode;
    CGFloat blurRadius = _blurRadius;
    CIImage* backgroundImage = _backgroundImage;
    os_unfair_lock_unlock(&_lock);

    if (mode == MLVirtualBackgroundModeOff) {
      return frame;
    }

    MLVirtualBackgroundFrameContext* context = [MLVirtualBackgroundFrameContext new];
    context.mode = mode;
    context.blurRadius = blurRadius;
    context.backgroundImage = backgroundImage;
    return [_engineBackend processFrame:frame
                                context:context
                              processor:self] ?: frame;
  }

  return frame;
}

- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame)*)frame {
  id<RTCVideoFrameBuffer> buffer = frame.buffer;
  if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    CVPixelBufferRef pixelBuffer = ((RTCCVPixelBuffer*)buffer).pixelBuffer;
    CVPixelBufferRetain(pixelBuffer);
    return pixelBuffer;
  }

  return [FlutterRTCFrameCapturer convertToCVPixelBuffer:frame];
}

- (CGSize)realtimeCompositeSizeForWidth:(size_t)width height:(size_t)height {
  if (width == 0 || height == 0) {
    return CGSizeMake(0, 0);
  }

  size_t pixelCount = width * height;
  if (pixelCount <= MLVirtualBackgroundMaximumCompositePixels) {
    return CGSizeMake((CGFloat)width, (CGFloat)height);
  }

  CGFloat scale = sqrt((CGFloat)MLVirtualBackgroundMaximumCompositePixels / (CGFloat)pixelCount);
  size_t outputWidth = MAX((size_t)2, ((size_t)floor((CGFloat)width * scale) / 2) * 2);
  size_t outputHeight = MAX((size_t)2, ((size_t)floor((CGFloat)height * scale) / 2) * 2);
  return CGSizeMake((CGFloat)outputWidth, (CGFloat)outputHeight);
}

- (CIImage*)sourceImageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                            outputSize:(CGSize)outputSize API_AVAILABLE(macos(12.0)) {
  CIImage* sourceImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
  if (sourceImage == nil || outputSize.width <= 0 || outputSize.height <= 0) {
    return sourceImage;
  }

  CGFloat scaleX = outputSize.width / CGRectGetWidth(sourceImage.extent);
  CGFloat scaleY = outputSize.height / CGRectGetHeight(sourceImage.extent);
  if (scaleX >= 0.999 && scaleY >= 0.999) {
    return sourceImage;
  }

  CIImage* scaledImage = [sourceImage imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];
  return [scaledImage imageByCroppingToRect:CGRectMake(0, 0, outputSize.width, outputSize.height)];
}

- (CGSize)realtimeSegmentationSizeForWidth:(size_t)width height:(size_t)height {
  if (width == 0 || height == 0) {
    return CGSizeMake(0, 0);
  }

  size_t pixelCount = width * height;
  if (pixelCount <= MLVirtualBackgroundMaximumSegmentationPixels) {
    return CGSizeMake((CGFloat)width, (CGFloat)height);
  }

  CGFloat scale = sqrt((CGFloat)MLVirtualBackgroundMaximumSegmentationPixels / (CGFloat)pixelCount);
  size_t outputWidth = MAX((size_t)2, ((size_t)floor((CGFloat)width * scale) / 2) * 2);
  size_t outputHeight = MAX((size_t)2, ((size_t)floor((CGFloat)height * scale) / 2) * 2);
  return CGSizeMake((CGFloat)outputWidth, (CGFloat)outputHeight);
}

- (CVPixelBufferRef)newSegmentationInputBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer API_AVAILABLE(macos(12.0)) {
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  CGSize segmentationSize = [self realtimeSegmentationSizeForWidth:width height:height];
  if (segmentationSize.width <= 0 || segmentationSize.height <= 0) {
    return nil;
  }

  if ((size_t)segmentationSize.width == width && (size_t)segmentationSize.height == height) {
    CVPixelBufferRetain(pixelBuffer);
    return pixelBuffer;
  }

  NSDictionary* attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
  };
  CVPixelBufferRef scaledBuffer = nil;
  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        (size_t)segmentationSize.width,
                                        (size_t)segmentationSize.height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes,
                                        &scaledBuffer);
  if (status != kCVReturnSuccess || scaledBuffer == nil) {
    return nil;
  }

  CIImage* scaledImage = [self sourceImageFromPixelBuffer:pixelBuffer outputSize:segmentationSize];
  if (scaledImage == nil) {
    CVPixelBufferRelease(scaledBuffer);
    return nil;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  [_ciContext render:scaledImage
     toCVPixelBuffer:scaledBuffer
              bounds:CGRectMake(0, 0, segmentationSize.width, segmentationSize.height)
          colorSpace:colorSpace];
  CGColorSpaceRelease(colorSpace);
  return scaledBuffer;
}

- (CVPixelBufferRef)copyMaskBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   timeStampNs:(int64_t)timeStampNs API_AVAILABLE(macos(12.0)) {
  __block CVPixelBufferRef segmentationInputBuffer = nil;
  __block NSUInteger processingGeneration = 0;

  os_unfair_lock_lock(&_lock);
  CVPixelBufferRef reusableMaskBuffer = nil;
  BOOL hasReusableMask = _lastMaskBuffer != nil && (timeStampNs - _lastMaskTimestampNs) < MLVirtualBackgroundMaximumMaskAgeNs;
  if (hasReusableMask) {
    reusableMaskBuffer = _lastMaskBuffer;
    CVPixelBufferRetain(reusableMaskBuffer);
  }

  BOOL shouldScheduleSegmentation = !_segmentationInFlight
      && _mode != MLVirtualBackgroundModeOff
      && (_lastSegmentationRequestTimestampNs == 0
          || (timeStampNs - _lastSegmentationRequestTimestampNs) >= MLVirtualBackgroundEnterpriseLiveSegmentationIntervalNs);
  if (shouldScheduleSegmentation) {
    _segmentationInFlight = YES;
    _lastSegmentationRequestTimestampNs = timeStampNs;
    processingGeneration = _processingGeneration;
    segmentationInputBuffer = pixelBuffer;
    CVPixelBufferRetain(segmentationInputBuffer);
  }
  os_unfair_lock_unlock(&_lock);

  if (segmentationInputBuffer != nil) {
    dispatch_async(_segmentationQueue, ^{
      [self updateMaskInBackgroundForPixelBuffer:segmentationInputBuffer
                                     timeStampNs:timeStampNs
                                      generation:processingGeneration];
      CVPixelBufferRelease(segmentationInputBuffer);
    });
  }

  return reusableMaskBuffer;
}

- (void)updateMaskInBackgroundForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                 timeStampNs:(int64_t)timeStampNs
                                  generation:(NSUInteger)generation API_AVAILABLE(macos(12.0)) {
  CVPixelBufferRef nextMaskBuffer = [self newMaskBufferForPixelBuffer:pixelBuffer];
  if (nextMaskBuffer == nil) {
    os_unfair_lock_lock(&_lock);
    if (generation == _processingGeneration) {
      _segmentationInFlight = NO;
    }
    os_unfair_lock_unlock(&_lock);
    return;
  }

  CGFloat nextMaskCoverage = [self subjectCoverageForMaskBuffer:nextMaskBuffer];

  os_unfair_lock_lock(&_lock);
  BOOL generationMatches = generation == _processingGeneration && _mode != MLVirtualBackgroundModeOff;
  BOOL hasStableMask = _lastMaskBuffer != nil && (timeStampNs - _lastMaskTimestampNs) < MLVirtualBackgroundMaskHoldWindowNs;
  BOOL maskLooksEmpty = nextMaskCoverage < MLVirtualBackgroundMinimumSubjectCoverage;
  BOOL maskDropped = hasStableMask
      && _lastMaskCoverage > MLVirtualBackgroundMinimumSubjectCoverage
      && nextMaskCoverage < (_lastMaskCoverage * MLVirtualBackgroundMaximumCoverageDropRatio);

  if (!generationMatches || ((maskLooksEmpty || maskDropped) && hasStableMask) || maskLooksEmpty) {
    if (generationMatches) {
      _segmentationInFlight = NO;
    }
    os_unfair_lock_unlock(&_lock);
    CVPixelBufferRelease(nextMaskBuffer);
    return;
  }

  if (_lastMaskBuffer != nil) {
    CVPixelBufferRelease(_lastMaskBuffer);
  }
  _lastMaskBuffer = nextMaskBuffer;
  _lastMaskTimestampNs = timeStampNs;
  _lastMaskCoverage = nextMaskCoverage;
  _segmentationInFlight = NO;
  os_unfair_lock_unlock(&_lock);
}

- (CVPixelBufferRef)newMaskBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer API_AVAILABLE(macos(12.0)) {
  CVPixelBufferRef segmentationInputBuffer = [self newSegmentationInputBufferForPixelBuffer:pixelBuffer];
  if (segmentationInputBuffer == nil) {
    return nil;
  }

  VNGeneratePersonSegmentationRequest* request = [VNGeneratePersonSegmentationRequest new];
  request.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
  request.outputPixelFormat = kCVPixelFormatType_OneComponent8;
  VNImageRequestHandler* handler =
      [[VNImageRequestHandler alloc] initWithCVPixelBuffer:segmentationInputBuffer options:@{}];
  NSError* requestError = nil;
  if (![handler performRequests:@[ request ] error:&requestError]) {
    CVPixelBufferRelease(segmentationInputBuffer);
    return nil;
  }

  VNPixelBufferObservation* observation = (VNPixelBufferObservation*)request.results.firstObject;
  if (![observation isKindOfClass:[VNPixelBufferObservation class]]) {
    CVPixelBufferRelease(segmentationInputBuffer);
    return nil;
  }

  CVPixelBufferRef nextMaskBuffer = observation.pixelBuffer;
  CVPixelBufferRetain(nextMaskBuffer);
  CVPixelBufferRelease(segmentationInputBuffer);
  return nextMaskBuffer;
}

- (CGFloat)subjectCoverageForMaskBuffer:(CVPixelBufferRef)maskBuffer API_AVAILABLE(macos(12.0)) {
  if (maskBuffer == nil) {
    return 0.0;
  }

  CVPixelBufferLockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* baseAddress = (const uint8_t*)CVPixelBufferGetBaseAddress(maskBuffer);
  if (baseAddress == NULL) {
    CVPixelBufferUnlockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);
    return 0.0;
  }

  size_t width = CVPixelBufferGetWidth(maskBuffer);
  size_t height = CVPixelBufferGetHeight(maskBuffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer);
  size_t stepX = MAX((size_t)1, width / 96);
  size_t stepY = MAX((size_t)1, height / 54);
  double coverageSum = 0.0;
  size_t sampleCount = 0;

  for (size_t y = 0; y < height; y += stepY) {
    const uint8_t* row = baseAddress + (y * bytesPerRow);
    for (size_t x = 0; x < width; x += stepX) {
      coverageSum += row[x];
      sampleCount += 1;
    }
  }

  CVPixelBufferUnlockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);
  if (sampleCount == 0) {
    return 0.0;
  }
  return (CGFloat)(coverageSum / ((double)sampleCount * 255.0));
}

- (CIImage*)preparedMaskImageFromPixelBuffer:(CVPixelBufferRef)maskBuffer
                                      extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  CIImage* maskImage = [CIImage imageWithCVPixelBuffer:maskBuffer];
  if (maskImage == nil) {
    return nil;
  }

  CGRect maskExtent = maskImage.extent;
  if (CGRectIsEmpty(maskExtent)) {
    return nil;
  }

  CGFloat scaleX = CGRectGetWidth(extent) / CGRectGetWidth(maskExtent);
  CGFloat scaleY = CGRectGetHeight(extent) / CGRectGetHeight(maskExtent);
  CGAffineTransform scaleTransform = CGAffineTransformMakeScale(scaleX, scaleY);
  CIImage* scaledMask = [maskImage imageByApplyingTransform:scaleTransform];
  CGRect scaledExtent = scaledMask.extent;
  CGAffineTransform translate = CGAffineTransformMakeTranslation(
      CGRectGetMinX(extent) - CGRectGetMinX(scaledExtent),
      CGRectGetMinY(extent) - CGRectGetMinY(scaledExtent));
  CIImage* alignedMask =
      [[scaledMask imageByApplyingTransform:translate] imageByCroppingToRect:extent];
  CIImage* haloReducedMask = [alignedMask
      imageByApplyingFilter:@"CIMorphologyMinimum"
       withInputParameters:@{
         @"inputRadius" : @(MLVirtualBackgroundHaloTrimRadius)
       }];
  CIImage* zoomGradeSubjectMask = [haloReducedMask
      imageByApplyingFilter:@"CIMorphologyMaximum"
       withInputParameters:@{
         @"inputRadius" : @(MLVirtualBackgroundEdgeRestoreRadius)
       }];
  CIFilter<CIGaussianBlur>* blurFilter = [CIFilter gaussianBlurFilter];
  blurFilter.inputImage = zoomGradeSubjectMask;
  blurFilter.radius = MLVirtualBackgroundEdgeFeatherRadius;
  zoomGradeSubjectMask = [blurFilter.outputImage imageByCroppingToRect:extent];
  CIFilter* contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
  [contrastFilter setValue:zoomGradeSubjectMask forKey:kCIInputImageKey];
  [contrastFilter setValue:@0 forKey:kCIInputSaturationKey];
  [contrastFilter setValue:@0.018 forKey:kCIInputBrightnessKey];
  [contrastFilter setValue:@1.62 forKey:kCIInputContrastKey];
  CIImage* softSubjectMask =
      [self clampedMaskImage:[contrastFilter.outputImage imageByCroppingToRect:extent]
                      extent:extent];
  softSubjectMask = [self maskBySuppressingOuterFringe:softSubjectMask extent:extent];

  CIFilter* solidCoreFilter = [CIFilter filterWithName:@"CIColorControls"];
  [solidCoreFilter setValue:alignedMask forKey:kCIInputImageKey];
  [solidCoreFilter setValue:@0 forKey:kCIInputSaturationKey];
  [solidCoreFilter setValue:@0.052 forKey:kCIInputBrightnessKey];
  [solidCoreFilter setValue:@3.15 forKey:kCIInputContrastKey];
  CIImage* solidCoreMask = [[solidCoreFilter.outputImage imageByApplyingFilter:@"CIMorphologyMinimum"
                                                            withInputParameters:@{
                                                              @"inputRadius" : @(MLVirtualBackgroundSolidCoreErodeRadius)
                                                            }] imageByCroppingToRect:extent];
  solidCoreMask = [self clampedMaskImage:solidCoreMask extent:extent];
  return [self maximumMaskImage:softSubjectMask
                      otherMask:solidCoreMask
                         extent:extent];
}

- (CIImage*)backgroundImageForMode:(MLVirtualBackgroundMode)mode
                       sourceImage:(CIImage*)sourceImage
                        blurRadius:(CGFloat)blurRadius
                   backgroundImage:(CIImage*)backgroundImage API_AVAILABLE(macos(12.0)) {
  if (mode == MLVirtualBackgroundModeBlur) {
    CIFilter<CIGaussianBlur>* blurFilter = [CIFilter gaussianBlurFilter];
    blurFilter.inputImage = [sourceImage imageByClampingToExtent];
    blurFilter.radius = blurRadius;
    return [blurFilter.outputImage imageByCroppingToRect:sourceImage.extent];
  }

  if (mode == MLVirtualBackgroundModeImage && backgroundImage != nil) {
    CGRect targetExtent = sourceImage.extent;
    CGRect imageExtent = backgroundImage.extent;
    if (CGRectIsEmpty(imageExtent)) {
      return sourceImage;
    }
    CGFloat scale = MAX(CGRectGetWidth(targetExtent) / CGRectGetWidth(imageExtent),
                        CGRectGetHeight(targetExtent) / CGRectGetHeight(imageExtent));
    CIImage* scaledImage =
        [backgroundImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaledImage.extent;
    CGFloat translateX = CGRectGetMidX(targetExtent) - CGRectGetMidX(scaledExtent);
    CGFloat translateY = CGRectGetMidY(targetExtent) - CGRectGetMidY(scaledExtent);
    return [[scaledImage imageByApplyingTransform:CGAffineTransformMakeTranslation(translateX, translateY)]
        imageByCroppingToRect:targetExtent];
  }

  return sourceImage;
}

- (CIImage*)stabilizedMaskImage:(CIImage*)maskImage
                         extent:(CGRect)extent
                   timeStampNs:(int64_t)timeStampNs API_AVAILABLE(macos(12.0)) {
  if (maskImage == nil) {
    return nil;
  }

  os_unfair_lock_lock(&_lock);
  _lastPreparedMaskImage = maskImage;
  _lastPreparedMaskTimestampNs = timeStampNs;
  os_unfair_lock_unlock(&_lock);
  return maskImage;
}

- (CIImage*)compositeImageByProtectingForegroundEdges:(CIImage*)compositeImage
                                          sourceImage:(CIImage*)sourceImage
                                          subjectMask:(CIImage*)subjectMask
                                               extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (compositeImage == nil || sourceImage == nil || subjectMask == nil) {
    return compositeImage;
  }

  CIImage* foregroundProtectionMask = [self foregroundProtectionMaskForSubjectMask:subjectMask
                                                                            extent:extent];
  if (foregroundProtectionMask == nil) {
    return compositeImage;
  }

  CIFilter<CIBlendWithMask>* edgeProtectionBlendFilter =
      [CIFilter blendWithMaskFilter];
  edgeProtectionBlendFilter.inputImage = sourceImage;
  edgeProtectionBlendFilter.backgroundImage = compositeImage;
  edgeProtectionBlendFilter.maskImage = foregroundProtectionMask;
  return [edgeProtectionBlendFilter.outputImage imageByCroppingToRect:extent];
}

- (CIImage*)foregroundProtectionMaskForSubjectMask:(CIImage*)subjectMask
                                           extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (subjectMask == nil) {
    return nil;
  }

  CIFilter* solidForegroundFilter = [CIFilter filterWithName:@"CIColorControls"];
  CIImage* coreForegroundMask = [subjectMask
      imageByApplyingFilter:@"CIMorphologyMinimum"
       withInputParameters:@{
         @"inputRadius" : @(MLVirtualBackgroundForegroundCoreErodeRadius)
       }];
  [solidForegroundFilter setValue:coreForegroundMask forKey:kCIInputImageKey];
  [solidForegroundFilter setValue:@0 forKey:kCIInputSaturationKey];
  [solidForegroundFilter setValue:@0.04 forKey:kCIInputBrightnessKey];
  [solidForegroundFilter setValue:@2.9 forKey:kCIInputContrastKey];
  return [self clampedMaskImage:[solidForegroundFilter.outputImage imageByCroppingToRect:extent]
                         extent:extent];
}

- (CIImage*)edgeProtectionMaskForSubjectMask:(CIImage*)subjectMask
                                      extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (subjectMask == nil) {
    return nil;
  }

  CIImage* expandedEdgeMask = [subjectMask
      imageByApplyingFilter:@"CIMorphologyMaximum"
       withInputParameters:@{
         @"inputRadius" : @1.95
       }];
  CIImage* contractedEdgeMask = [subjectMask
      imageByApplyingFilter:@"CIMorphologyMinimum"
       withInputParameters:@{
         @"inputRadius" : @1.05
       }];
  CIFilter* edgeBandFilter = [CIFilter filterWithName:@"CIDifferenceBlendMode"];
  [edgeBandFilter setValue:expandedEdgeMask forKey:kCIInputImageKey];
  [edgeBandFilter setValue:contractedEdgeMask
                    forKey:kCIInputBackgroundImageKey];
  CIImage* edgeBandMask =
      [[edgeBandFilter valueForKey:kCIOutputImageKey] imageByCroppingToRect:extent];
  CIFilter<CIGaussianBlur>* edgeBlurFilter = [CIFilter gaussianBlurFilter];
  edgeBlurFilter.inputImage = edgeBandMask;
  edgeBlurFilter.radius = 1.2;
  CIImage* softenedEdgeBandMask =
      [edgeBlurFilter.outputImage imageByCroppingToRect:extent];
  return [self clampedMaskImage:[self imageByScalingMaskIntensity:softenedEdgeBandMask
                                                           weight:0.64
                                                            extent:extent]
                         extent:extent];
}

- (CIImage*)maximumMaskImage:(CIImage*)maskImage
                    otherMask:(CIImage*)otherMask
                       extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (maskImage == nil) {
    return otherMask == nil ? nil : [self clampedMaskImage:otherMask extent:extent];
  }
  if (otherMask == nil) {
    return [self clampedMaskImage:maskImage extent:extent];
  }

  CIFilter* maximumFilter = [CIFilter filterWithName:@"CIMaximumCompositing"];
  [maximumFilter setValue:maskImage forKey:kCIInputImageKey];
  [maximumFilter setValue:otherMask forKey:kCIInputBackgroundImageKey];
  return [self clampedMaskImage:[[maximumFilter valueForKey:kCIOutputImageKey] imageByCroppingToRect:extent]
                         extent:extent];
}

- (CIImage*)imageByScalingMaskIntensity:(CIImage*)maskImage
                                 weight:(CGFloat)weight
                                  extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (maskImage == nil) {
    return nil;
  }

  CGFloat clampedWeight = MIN(MAX(weight, 0.0), 1.0);
  CIFilter* colorMatrixFilter = [CIFilter filterWithName:@"CIColorMatrix"];
  [colorMatrixFilter setValue:maskImage forKey:kCIInputImageKey];
  [colorMatrixFilter setValue:[CIVector vectorWithX:clampedWeight Y:0 Z:0 W:0]
                       forKey:@"inputRVector"];
  [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:clampedWeight Z:0 W:0]
                       forKey:@"inputGVector"];
  [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:0 Z:clampedWeight W:0]
                       forKey:@"inputBVector"];
  [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1]
                       forKey:@"inputAVector"];
  return [[colorMatrixFilter valueForKey:kCIOutputImageKey]
      imageByCroppingToRect:extent];
}

- (CIImage*)clampedMaskImage:(CIImage*)maskImage
                      extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (maskImage == nil) {
    return nil;
  }

  CIFilter* clampFilter = [CIFilter filterWithName:@"CIColorClamp"];
  [clampFilter setValue:maskImage forKey:kCIInputImageKey];
  [clampFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
                 forKey:@"inputMinComponents"];
  [clampFilter setValue:[CIVector vectorWithX:1 Y:1 Z:1 W:1]
                 forKey:@"inputMaxComponents"];
  return [[clampFilter valueForKey:kCIOutputImageKey]
      imageByCroppingToRect:extent];
}

- (CIImage*)maskBySuppressingOuterFringe:(CIImage*)maskImage
                                  extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (maskImage == nil) {
    return nil;
  }

  CIImage* innerMask = [maskImage
      imageByApplyingFilter:@"CIMorphologyMinimum"
       withInputParameters:@{
         @"inputRadius" : @(MLVirtualBackgroundFringeSuppressionRadius)
       }];
  CIFilter* fringeBandFilter = [CIFilter filterWithName:@"CIDifferenceBlendMode"];
  [fringeBandFilter setValue:maskImage forKey:kCIInputImageKey];
  [fringeBandFilter setValue:innerMask forKey:kCIInputBackgroundImageKey];
  CIImage* fringeBand = [[fringeBandFilter valueForKey:kCIOutputImageKey] imageByCroppingToRect:extent];
  CIImage* weightedFringeBand = [self imageByScalingMaskIntensity:fringeBand
                                                           weight:MLVirtualBackgroundFringeSuppressionWeight
                                                            extent:extent];
  CIFilter* subtractFilter = [CIFilter filterWithName:@"CISubtractBlendMode"];
  [subtractFilter setValue:weightedFringeBand forKey:kCIInputImageKey];
  [subtractFilter setValue:maskImage forKey:kCIInputBackgroundImageKey];
  return [self clampedMaskImage:[[subtractFilter valueForKey:kCIOutputImageKey] imageByCroppingToRect:extent]
                         extent:extent];
}

- (CIImage*)sourceImageBySuppressingEdgeContamination:(CIImage*)sourceImage
                                      backgroundImage:(CIImage*)backgroundImage
                                          subjectMask:(CIImage*)subjectMask
                                               extent:(CGRect)extent API_AVAILABLE(macos(12.0)) {
  if (sourceImage == nil || backgroundImage == nil || subjectMask == nil) {
    return sourceImage;
  }

  CIImage* innerMask = [subjectMask
      imageByApplyingFilter:@"CIMorphologyMinimum"
       withInputParameters:@{
         @"inputRadius" : @(MLVirtualBackgroundEdgeDecontaminationRadius)
       }];
  CIFilter* edgeBandFilter = [CIFilter filterWithName:@"CIDifferenceBlendMode"];
  [edgeBandFilter setValue:subjectMask forKey:kCIInputImageKey];
  [edgeBandFilter setValue:innerMask forKey:kCIInputBackgroundImageKey];
  CIImage* edgeBand = [[edgeBandFilter valueForKey:kCIOutputImageKey] imageByCroppingToRect:extent];
  CIImage* weightedEdgeBand = [self imageByScalingMaskIntensity:edgeBand
                                                         weight:MLVirtualBackgroundEdgeDecontaminationWeight
                                                          extent:extent];
  weightedEdgeBand = [self clampedMaskImage:weightedEdgeBand extent:extent];

  CIFilter<CIBlendWithMask>* decontaminationBlendFilter = [CIFilter blendWithMaskFilter];
  decontaminationBlendFilter.inputImage = backgroundImage;
  decontaminationBlendFilter.backgroundImage = sourceImage;
  decontaminationBlendFilter.maskImage = weightedEdgeBand;
  return [decontaminationBlendFilter.outputImage imageByCroppingToRect:extent];
}

- (BOOL)renderImage:(CIImage*)image
      toPixelBuffer:(CVPixelBufferRef)pixelBuffer
             bounds:(CGRect)bounds API_AVAILABLE(macos(12.0)) {
  if (image == nil || pixelBuffer == nil) {
    return NO;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  [_ciContext render:image
     toCVPixelBuffer:pixelBuffer
              bounds:bounds
          colorSpace:colorSpace];
  CGColorSpaceRelease(colorSpace);
  return YES;
}

- (CVPixelBufferRef)newOutputBufferWithWidth:(size_t)width
                                      height:(size_t)height {
  CVPixelBufferPoolRef outputPool = [self outputPixelBufferPoolWithWidth:width
                                                                  height:height];
  if (outputPool != nil) {
    CVPixelBufferRef pooledBuffer = nil;
    CVReturn poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                             outputPool,
                                                             &pooledBuffer);
    CVPixelBufferPoolRelease(outputPool);
    if (poolStatus == kCVReturnSuccess) {
      return pooledBuffer;
    }
  }

  NSDictionary* attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
  };
  CVPixelBufferRef pixelBuffer = nil;
  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width,
                                        height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes,
                                        &pixelBuffer);
  return status == kCVReturnSuccess ? pixelBuffer : nil;
}

- (CVPixelBufferPoolRef)outputPixelBufferPoolWithWidth:(size_t)width
                                                height:(size_t)height {
  os_unfair_lock_lock(&_lock);
  BOOL canReusePool = _outputPixelBufferPool != nil
      && _outputPixelBufferPoolWidth == width
      && _outputPixelBufferPoolHeight == height;
  if (canReusePool) {
    CVPixelBufferPoolRef reusablePool = _outputPixelBufferPool;
    CVPixelBufferPoolRetain(reusablePool);
    os_unfair_lock_unlock(&_lock);
    return reusablePool;
  }

  if (_outputPixelBufferPool != nil) {
    CVPixelBufferPoolRelease(_outputPixelBufferPool);
    _outputPixelBufferPool = nil;
  }

  NSDictionary* poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey : @4
  };
  NSDictionary* pixelBufferAttributes = @{
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
  };
  CVPixelBufferPoolRef nextPool = nil;
  CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                            (__bridge CFDictionaryRef)poolAttributes,
                                            (__bridge CFDictionaryRef)pixelBufferAttributes,
                                            &nextPool);
  if (status != kCVReturnSuccess) {
    _outputPixelBufferPoolWidth = 0;
    _outputPixelBufferPoolHeight = 0;
    os_unfair_lock_unlock(&_lock);
    return nil;
  }

  _outputPixelBufferPool = nextPool;
  _outputPixelBufferPoolWidth = width;
  _outputPixelBufferPoolHeight = height;
  CVPixelBufferPoolRetain(nextPool);
  os_unfair_lock_unlock(&_lock);
  return nextPool;
}

@end
