#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    CGDirectDisplayID target=0; unsigned count=0;
    for (NSScreen *s in NSScreen.screens) {
        CGDirectDisplayID d=[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if ([s.localizedName isEqualToString:@"MSI Xpander Desktop"] && CGDisplayVendorNumber(d)==3504 && CGDisplayModelNumber(d)==31008 && CGDisplaySerialNumber(d)==20261030 && d!=CGMainDisplayID()) { target=d; count++; }
    }
    if (count!=1) { fprintf(stderr,"Refusing: expected one owned virtual Xpander display\n"); return 1; }
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(target,(__bridge CFDictionaryRef)@{(__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes:@YES});
    CGError result=kCGErrorFailure;
    for (CFIndex i=0;modes && i<CFArrayGetCount(modes);i++) {
        CGDisplayModeRef m=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
        if (CGDisplayModeGetWidth(m)==960 && CGDisplayModeGetHeight(m)==360 && CGDisplayModeGetPixelWidth(m)==1920 && CGDisplayModeGetPixelHeight(m)==720) {
            result=CGDisplaySetDisplayMode(target,m,NULL);
            fprintf(stderr,"960x360 candidate id=%d flags=%x usable=%d set result=%d\n",CGDisplayModeGetIODisplayModeID(m),CGDisplayModeGetIOFlags(m),CGDisplayModeIsUsableForDesktopGUI(m),result);
            if (result==kCGErrorSuccess) break;
        }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRef active=CGDisplayCopyDisplayMode(target);
    BOOL correct=active && CGDisplayModeGetWidth(active)==960 && CGDisplayModeGetHeight(active)==360 && CGDisplayModeGetPixelWidth(active)==1920 && CGDisplayModeGetPixelHeight(active)==720;
    if (active) CGDisplayModeRelease(active);
    fprintf(stderr,"Owned virtual display %u: 960x360 Retina (1920x720 pixels): %s\n",target,result==kCGErrorSuccess&&correct?"selected":"failed");
    return result==kCGErrorSuccess&&correct?0:1;
} }
