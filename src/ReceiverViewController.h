#import <Cocoa/Cocoa.h>
#include "cast.h"

@interface ReceiverViewController : NSViewController
- (instancetype)initWithRuntime:(ASCastRuntime *)runtime;
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end
