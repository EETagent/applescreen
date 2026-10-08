#import <Cocoa/Cocoa.h>
#include "cast.h"

@interface SenderViewController : NSViewController
- (instancetype)initWithRuntime:(ASCastRuntime *)runtime;
// Stops source work before session teardown. The app keeps the runtime alive
// until this asynchronous barrier and its own final runtime barrier complete.
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end
