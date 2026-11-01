// Interactive allocation/apply/release probe; no capture, USB or HDR writes.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <unistd.h>
@interface NSObject (VirtualDisplayProbe)
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
static id display;
static BOOL done;
static unsigned int modeWidth=1920,modeHeight=720;
static void command(NSString *word) {
 if([@[@"create",@"create-srgb",@"create-720p",@"create-480"] containsObject:word]) {
  if(display){fprintf(stdout,"ERROR already allocated\n");fflush(stdout);return;}
  modeWidth=([word isEqual:@"create-720p"]||[word isEqual:@"create-480"])?1280:1920;
  modeHeight=[word isEqual:@"create-480"]?480:720;
  Class descriptorClass=NSClassFromString(@"CGVirtualDisplayDescriptor");Class displayClass=NSClassFromString(@"CGVirtualDisplay");
  if(!descriptorClass||!displayClass){fprintf(stdout,"ERROR API unavailable\n");fflush(stdout);return;}
  id descriptor=[descriptorClass new];
  [descriptor setValue:@"MSI Xpander Desktop" forKey:@"name"];
  [descriptor setValue:@1920 forKey:@"maxPixelsWide"];[descriptor setValue:@720 forKey:@"maxPixelsHigh"];
  [descriptor setValue:@3504 forKey:@"vendorID"];[descriptor setValue:@31008 forKey:@"productID"];
  [descriptor setValue:@20261030 forKey:@"serialNum"];[descriptor setValue:@20261030 forKey:@"serialNumber"];
  [descriptor setValue:[NSValue valueWithSize:NSMakeSize(290,109)] forKey:@"sizeInMillimeters"];
  if([word isEqual:@"create-srgb"]) {
   [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(.64,.33)] forKey:@"redPrimary"];
   [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(.30,.60)] forKey:@"greenPrimary"];
   [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(.15,.06)] forKey:@"bluePrimary"];
   [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(.3127,.3290)] forKey:@"whitePoint"];
  }
  [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
  display=[[displayClass alloc] initWithDescriptor:descriptor];
  fprintf(stdout,"CREATED display=%u settings_not_applied=1 descriptor=%s\n",display?[display displayID]:0,[word isEqual:@"create-srgb"]?"explicit-srgb":"system-default");
 }else if([@[@"apply",@"apply-native",@"apply-720p",@"apply-480"] containsObject:word]) {
  if([word isEqual:@"apply-native"]){modeWidth=1920;modeHeight=720;}
  if([word isEqual:@"apply-720p"]){modeWidth=1280;modeHeight=720;}
  if([word isEqual:@"apply-480"]){modeWidth=1280;modeHeight=480;}
  if(!display){fprintf(stdout,"ERROR no allocation\n");fflush(stdout);return;}
  id settings=[NSClassFromString(@"CGVirtualDisplaySettings") new];[settings setValue:@NO forKey:@"hiDPI"];
  id mode=[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:modeWidth height:modeHeight refreshRate:60];
  [settings setValue:@[mode] forKey:@"modes"];
  fprintf(stdout,"APPLIED ok=%d display=%u width=%u height=%u hz=60\n",[display applySettings:settings],[display displayID],modeWidth,modeHeight);
 }else if([word isEqual:@"release"]) {
  display=nil;fprintf(stdout,"RELEASED\n");
 }else if([word isEqual:@"quit"]) {
  display=nil;done=YES;fprintf(stdout,"QUIT\n");
 }else fprintf(stdout,"ERROR commands: create create-srgb create-720p create-480 apply apply-native apply-720p apply-480 release quit\n");
 fflush(stdout);
}
int main(void) { @autoreleasepool {
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 signal(SIGPIPE,SIG_IGN);
 fprintf(stdout,"READY no virtual display allocated; commands: create create-srgb create-720p create-480 apply apply-native apply-720p apply-480 release quit\n");fflush(stdout);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  char *line=NULL;size_t length=0;
  while(getline(&line,&length,stdin)>0){NSString *word=[[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];dispatch_async(dispatch_get_main_queue(),^{command(word);});}
  free(line);dispatch_async(dispatch_get_main_queue(),^{display=nil;done=YES;});
 });
 while(!done)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);
 return 0;
}}
