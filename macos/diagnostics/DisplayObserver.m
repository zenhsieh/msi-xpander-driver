// Read-only mode/connection observation. No HDR getter, setter, capture or USB.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <signal.h>
#include <time.h>
static volatile sig_atomic_t stopped;
static double start;
static NSMutableArray<NSNumber *> *entries;
static NSMutableDictionary<NSString *,id> *previous;
static double clockSeconds(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void stop(int signalNumber) {(void)signalNumber;stopped=1;}
static void emit(NSString *kind,id state) {
 NSDictionary *row=@{@"t":@(clockSeconds()-start),@"kind":kind,@"state":state};
 NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
 if(data){flockfile(stdout);fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);funlockfile(stdout);}
}
static void changed(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void *context) {
 (void)context;emit(@"cg-event",@{@"display":@(display),@"flags":@(flags)});
}
static void record(NSString *key,id state) {
 @synchronized(previous) {if(![previous[key] isEqual:state]){previous[key]=state;emit(key,state);}}
}
static void inventory(void) {
 io_iterator_t iterator=0;
 if(IORegistryCreateIterator(kIOMainPortDefault,kIOServicePlane,kIORegistryIterateRecursively,&iterator))return;
 io_registry_entry_t entry;
 while((entry=IOIteratorNext(iterator))) {
  io_name_t name;BOOL retain=NO;
  if(!IOObjectGetClass(entry,name))retain=!strcmp(name,"IOPortTransportStateDisplayPort")||!strcmp(name,"IOMobileFramebufferShim");
  if(retain)[entries addObject:@(entry)];else IOObjectRelease(entry);
 }
 IOObjectRelease(iterator);
 emit(@"observer",@{@"cached_connection_and_framebuffer_nodes":@(entries.count),@"physical_writes":@NO,@"hdr_flag_used":@NO});
}
static void registrySnapshot(void) {
 for(NSNumber *number in entries) {
  io_registry_entry_t entry=number.unsignedIntValue;CFMutableDictionaryRef raw=NULL;
  if(IORegistryEntryCreateCFProperties(entry,&raw,kCFAllocatorDefault,0))continue;
  NSDictionary *props=CFBridgingRelease(raw);uint64_t identifier=0;IORegistryEntryGetRegistryEntryID(entry,&identifier);
  NSMutableDictionary *row=[NSMutableDictionary dictionary];
  NSArray *keys=@[@"ProductName",@"ManufacturerName",@"Active",@"HPD_StateDescription",@"HPD_State",@"AuthenticationStatusDescription",@"AuthorizationStatusDescription",@"HashStatusDescription",@"EDIDChanged",@"SinkCount",@"DriverStatusDescription",@"LaneCount",@"LinkRate",@"LinkRateDescription",@"ParentPortTypeDescription",@"TransportDescription",@"DisplayWidth",@"DisplayHeight",@"PixelClock",@"DPTimingModeId",@"DisplayClock",@"VideoClock",@"Transport"];
  for(NSString *key in keys)if(props[key])row[key]=props[key];
  NSString *product=props[@"DisplayAttributes"][@"ProductAttributes"][@"ProductName"];
  if(product)row[@"ProductName"]=product;
  // Never export EDID, serial numbers, UUIDs or arbitrary registry properties.
  record([NSString stringWithFormat:@"registry-%llu",(unsigned long long)identifier],row);
 }
}
static void displaySnapshot(void) {
 CGDirectDisplayID ids[32];uint32_t count=0;
 if(CGGetOnlineDisplayList(32,ids,&count))return;
 NSMutableArray *list=[NSMutableArray array];
 for(uint32_t i=0;i<count;i++) {
  CGDirectDisplayID display=ids[i];[list addObject:@(display)];
  NSMutableDictionary *state=[@{@"display":@(display),@"vendor":@(CGDisplayVendorNumber(display)),@"product":@(CGDisplayModelNumber(display)),@"online":@(CGDisplayIsOnline(display)),@"active":@(CGDisplayIsActive(display)),@"asleep":@(CGDisplayIsAsleep(display)),@"rotation":@(CGDisplayRotation(display)),@"mirror_target":@(CGDisplayMirrorsDisplay(display))} mutableCopy];
  CGRect bounds=CGDisplayBounds(display);state[@"bounds"]=@[@(bounds.origin.x),@(bounds.origin.y),@(bounds.size.width),@(bounds.size.height)];
  CGDisplayModeRef mode=CGDisplayCopyDisplayMode(display);
  if(mode){state[@"mode_id"]=@(CGDisplayModeGetIODisplayModeID(mode));state[@"pixels"]=@[@(CGDisplayModeGetPixelWidth(mode)),@(CGDisplayModeGetPixelHeight(mode))];state[@"logical"]=@[@(CGDisplayModeGetWidth(mode)),@(CGDisplayModeGetHeight(mode))];state[@"refresh_hz"]=@(CGDisplayModeGetRefreshRate(mode));CGDisplayModeRelease(mode);}
  CGColorSpaceRef color=CGDisplayCopyColorSpace(display);
  if(color){CFStringRef name=CGColorSpaceCopyName(color);if(name)state[@"color_space"]=CFBridgingRelease(name);CGColorSpaceRelease(color);}
  record([NSString stringWithFormat:@"display-%u",display],state);
 }
 record(@"online",list);
}
int main(void) { @autoreleasepool {
 start=clockSeconds();entries=[NSMutableArray array];previous=[NSMutableDictionary dictionary];
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 inventory();CGError callback=CGDisplayRegisterReconfigurationCallback(changed,NULL);emit(@"callback-registration",@(callback));
 signal(SIGINT,stop);signal(SIGTERM,stop);
 dispatch_group_t worker=dispatch_group_create();
 dispatch_group_async(worker,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  while(!stopped){@autoreleasepool {registrySnapshot();usleep(100000);}}
 });
 __block double lastPoll=clockSeconds(),maxGap=0;
 NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer *tick){
  (void)tick;
  if(stopped){
   [NSApp stop:nil];
   [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
   return;
  }
  double now=clockSeconds();maxGap=MAX(maxGap,now-lastPoll);lastPoll=now;
  displaySnapshot();
 }];
 [NSApp run];[timer invalidate];
 displaySnapshot();
 BOOL registryStopped=dispatch_group_wait(worker,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
 emit(@"complete",@{@"max_poll_gap_ms":@(maxGap*1000),@"registry_worker_stopped":@(registryStopped)});
 if(callback==kCGErrorSuccess)CGDisplayRemoveReconfigurationCallback(changed,NULL);
 if(registryStopped)for(NSNumber *entry in entries)IOObjectRelease(entry.unsignedIntValue);
 return 0;
}}
