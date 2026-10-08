#import "FormRows.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <net/if.h>

NSStackView *ASButtons(NSArray<NSView *> *buttons) {
    NSStackView *row = [NSStackView stackViewWithViews:buttons];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    return row;
}
NSStackView *ASFieldRow(NSString *title, NSView *field) {
    NSTextField *label = [NSTextField labelWithString:title];
    [label.widthAnchor constraintEqualToConstant:112].active = YES;
    return ASButtons(@[label, field]);
}
NSStackView *ASForm(NSArray<NSView *> *rows) {
    NSStackView *form = [NSStackView stackViewWithViews:rows];
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 14;
    form.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    for (NSView *row in rows) [row.widthAnchor constraintEqualToAnchor:form.widthAnchor constant:-40].active = YES;
    return form;
}
NSTextField *ASPathField(NSString *placeholder) {
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = placeholder;
    field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [field.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    return field;
}
NSPopUpButton *ASInterfacePicker(id target, SEL action) {
    NSPopUpButton *picker = [[NSPopUpButton alloc] init];
    [picker addItemWithTitle:@"Automatic"];
    picker.lastItem.representedObject = @"";
    struct if_nameindex *interfaces = if_nameindex();
    if (interfaces) {
        for (struct if_nameindex *item = interfaces; item->if_index; ++item) {
            NSString *name = [NSString stringWithUTF8String:item->if_name];
            [picker addItemWithTitle:name];
            picker.lastItem.representedObject = name;
        }
        if_freenameindex(interfaces);
    }
    picker.target = target;
    picker.action = action;
    return picker;
}
NSString *ASSelectedInterface(NSPopUpButton *picker) {
    return picker.selectedItem.representedObject ?: @"";
}
void ASChooseFile(NSWindow *window, NSTextField *field, NSArray<NSString *> *extensions) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if (extensions.count) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *extension in extensions) {
            UTType *type = [UTType typeWithFilenameExtension:extension];
            if (type) [types addObject:type];
        }
        panel.allowedContentTypes = types;
        panel.allowsOtherFileTypes = YES;
    }
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) field.stringValue = panel.URL.path;
    }];
}
void ASInvokeCompletion(void *context) {
    dispatch_block_t completion = CFBridgingRelease(context);
    if (completion) completion();
}
void *ASCompletionContext(dispatch_block_t completion) {
    return (__bridge_retained void *)[completion copy];
}
