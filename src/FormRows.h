#import <Cocoa/Cocoa.h>

// Small shared Cocoa layout helpers; controllers retain their own behavior.
NSStackView *ASForm(NSArray<NSView *> *rows);
NSStackView *ASFieldRow(NSString *title, NSView *field);
NSStackView *ASButtons(NSArray<NSView *> *buttons);
NSTextField *ASPathField(NSString *placeholder);
NSPopUpButton *ASInterfacePicker(id target, SEL action);
NSString *ASSelectedInterface(NSPopUpButton *picker);
void ASChooseFile(NSWindow *window, NSTextField *field, NSArray<NSString *> *extensions);
void ASInvokeCompletion(void *context);
void *ASCompletionContext(dispatch_block_t completion);
