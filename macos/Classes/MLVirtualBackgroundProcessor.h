#import <Foundation/Foundation.h>
#import "VideoProcessingAdapter.h"

@interface MLVirtualBackgroundProcessor : NSObject <ExternalVideoProcessingDelegate>

+ (NSDictionary* _Nonnull)capabilities;

- (BOOL)updateWithOptions:(NSDictionary* _Nonnull)options
                    error:(NSError* _Nullable* _Nullable)error;

@end
