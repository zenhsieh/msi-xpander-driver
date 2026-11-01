#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

// Runtime-only CoreGraphics virtual-display API (also used in Chromium's
// ui/display/mac/test/virtual_display_util_mac.mm). Not a public Apple API.
@interface NSObject (VirtualDisplayRuntime)
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

static id virtualDisplay;
static NSWindow *testWindow;
static SCContentFilter *filter;
static SCStreamConfiguration *configuration;
static BOOL busy;
static uint64_t frames;
static CGDirectDisplayID captureDisplayID;
static size_t sourceWidth, sourceHeight, sourcePixelWidth, sourcePixelHeight;
static BOOL useContinuousStream;
static SCStream *liveStream;
static dispatch_queue_t captureQueue;
static BOOL systemSleeping, screensSleeping;
static NSTimeInterval captureRetryAfter;
static NSUInteger captureEpoch;
static BOOL colorCaptureDiagnostic;
static NSArray<NSDictionary *> *physicalHDRBaseline;
static Boolean (*readHDR)(CGDirectDisplayID);
static int (*setHDR)(CGDirectDisplayID,bool);
static id performanceActivity;
static BOOL useVTJPEG;
static double vtQuality = 0.75;
// Encoder state is owned by the serial SCK capture queue, never the main queue.
static VTCompressionSessionRef vtSession;
static NSString *vtEncoderID;
static NSUInteger vtGeneration;
static uint64_t vtSequence;
static BOOL vtVerifiedOutput;
static void capture(void);
static void invalidateVTEncoder(void);

static void recordPhysicalHDR(void) {
    void *framework=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    readHDR=framework?dlsym(framework,"SLSDisplayIsHDRModeEnabled"):NULL;
    setHDR=framework?dlsym(framework,"SLSDisplaySetHDRModeEnabled"):NULL;
    NSMutableArray *baseline=[NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
        if (!uuid) continue;
        NSString *identity=CFBridgingRelease(CFUUIDCreateString(NULL,uuid)); CFRelease(uuid);
        if (readHDR) {
            BOOL enabled=readHDR(display);
            [baseline addObject:@{@"uuid":identity,@"vendor":@(CGDisplayVendorNumber(display)),@"product":@(CGDisplayModelNumber(display)),@"hdr":@(enabled),@"name":screen.localizedName}];
            fprintf(stderr,"Physical HDR baseline: %s id=%u enabled=%d\n",screen.localizedName.UTF8String,display,enabled);
        }
    }
    physicalHDRBaseline=baseline;
}

// Only restore the pre-existing HDR preference after our own display/capture
// reconfiguration. Never infer HDR from EDR headroom or force a global default.
static void preservePhysicalHDR(NSString *stage) {
    if (!readHDR || !setHDR) return;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (display==captureDisplayID) continue;
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display); if (!uuid) continue;
        NSString *identity=CFBridgingRelease(CFUUIDCreateString(NULL,uuid)); CFRelease(uuid);
        for (NSDictionary *saved in physicalHDRBaseline) {
            if (![saved[@"uuid"] isEqual:identity] || [saved[@"vendor"] unsignedIntValue]!=CGDisplayVendorNumber(display) || [saved[@"product"] unsignedIntValue]!=CGDisplayModelNumber(display)) continue;
            BOOL expected=[saved[@"hdr"] boolValue],actual=readHDR(display);
            int result=0;
            if (expected!=actual) result=setHDR(display,expected);
            fprintf(stderr,"Physical HDR check [%s]: %s expected=%d before=%d after=%d result=%d\n",stage.UTF8String,[saved[@"name"] UTF8String],expected,actual,readHDR(display),result);
        }
    }
}

@interface DesktopStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@end
static DesktopStreamOutput *streamOutput;

static BOOL currentGeometry(size_t *w, size_t *h, size_t *pw, size_t *ph) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(captureDisplayID);
    if (!mode) return NO;
    *w=CGDisplayModeGetWidth(mode); *h=CGDisplayModeGetHeight(mode);
    *pw=CGDisplayModeGetPixelWidth(mode); *ph=CGDisplayModeGetPixelHeight(mode);
    CGDisplayModeRelease(mode);
    return *w>0 && *h>0 && *pw>0 && *ph>0;
}

static void fail(NSString *message) {
    fprintf(stderr, "Desktop bridge: %s\n", message.UTF8String);
    exit(1);
}

// Run on the main queue. Preserve virtualDisplay across stream interruptions.
static void resetCapture(NSString *reason) {
    fprintf(stderr,"Capture reset (virtual display retained): %s\n",reason.UTF8String);
    captureEpoch++;
    if (useVTJPEG && captureQueue) dispatch_async(captureQueue, ^{ invalidateVTEncoder(); });
    SCStream *previous=liveStream;
    liveStream=nil;
    busy=NO;
    sourceWidth=sourceHeight=sourcePixelWidth=sourcePixelHeight=0;
    captureRetryAfter=NSDate.timeIntervalSinceReferenceDate+1.0;
    if (previous) [previous stopCaptureWithCompletionHandler:^(NSError *error) {}];
}

static void recoverStream(SCStream *expected,NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (expected && expected!=liveStream) return;
        resetCapture(reason);
    });
}

static void writeRawFrame(NSData *data,size_t width,size_t height,const char *magic,uint64_t capturedAt,uint64_t generation) {
    if (colorCaptureDiagnostic) { frames++; return; }
    uint32_t header[]={CFSwapInt32HostToLittle((uint32_t)(28+data.length)),0,CFSwapInt32HostToLittle((uint32_t)width),CFSwapInt32HostToLittle((uint32_t)height)};
    memcpy(&header[1],strcmp(magic,"BGRA")==0?"BGR2":"RGB2",4);
    uint64_t stamp=CFSwapInt64HostToLittle(capturedAt);
    uint64_t epoch=CFSwapInt64HostToLittle(generation);
    if (fwrite(header,1,sizeof(header),stdout)!=sizeof(header) || fwrite(&stamp,1,8,stdout)!=8 || fwrite(&epoch,1,8,stdout)!=8 || fwrite(data.bytes,1,data.length,stdout)!=data.length || fflush(stdout)) exit(0);
    frames++;
    if (frames==1 || frames%120==0) fprintf(stderr,"Captured virtual desktop: %llu frames (%s)\n",frames,magic);
}

@interface VTDesktopFrame : NSObject
@property(nonatomic) size_t width, height;
@property(nonatomic) uint64_t capturedAt, generation, startedAt, encodeMicroseconds;
@property(nonatomic) OSStatus status;
@property(nonatomic) BOOL dropped;
@property(nonatomic, strong) NSData *jpeg;
@end
@implementation VTDesktopFrame
@end

static uint64_t monotonicMicroseconds(void) {
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC,&stamp)) fail(@"Cannot read encoder clock");
    return (uint64_t)stamp.tv_sec*1000000 + (uint64_t)stamp.tv_nsec/1000;
}

static void invalidateVTEncoder(void) {
    if (vtSession) {
        VTCompressionSessionInvalidate(vtSession);
        CFRelease(vtSession);
        vtSession=NULL;
    }
    vtEncoderID=nil;
    vtVerifiedOutput=NO;
    vtSequence=0;
}

static NSString *hardwareJPEGEncoder(void) {
    CFArrayRef list=NULL;
    OSStatus status=VTCopyVideoEncoderList(NULL,&list);
    if (status!=noErr || !list) fail([NSString stringWithFormat:@"Cannot list VT encoders: %d",status]);
    NSMutableArray<NSString *> *candidates=[NSMutableArray array];
    for (NSDictionary *entry in (__bridge NSArray *)list) {
        NSNumber *codec=entry[(__bridge id)kVTVideoEncoderList_CodecType];
        id hardware=entry[(__bridge id)kVTVideoEncoderList_IsHardwareAccelerated];
        NSString *identifier=entry[(__bridge id)kVTVideoEncoderList_EncoderID];
        if (codec.unsignedIntValue==kCMVideoCodecType_JPEG && [identifier isKindOfClass:NSString.class] &&
            hardware && CFEqual((__bridge CFTypeRef)hardware,kCFBooleanTrue)) [candidates addObject:identifier];
    }
    CFRelease(list);
    [candidates sortUsingSelector:@selector(compare:)];
    if (!candidates.count) fail(@"No hardware JPEG encoder is listed by VideoToolbox; use MSI_BRIDGE_ENCODER=raw");
    return candidates.firstObject;
}

static void verifyVTEncoder(NSString *stage) {
    CFTypeRef identifier=NULL;
    OSStatus status=VTSessionCopyProperty(vtSession,kVTCompressionPropertyKey_EncoderID,kCFAllocatorDefault,&identifier);
    NSString *actual=status==noErr && identifier && CFGetTypeID(identifier)==CFStringGetTypeID()
        ? [(__bridge NSString *)identifier copy] : nil;
    if (identifier) CFRelease(identifier);
    CFArrayRef list=NULL;
    OSStatus listStatus=VTCopyVideoEncoderList(NULL,&list);
    BOOL hardware=NO;
    if (listStatus==noErr && list && [actual isEqualToString:vtEncoderID]) {
        for (NSDictionary *entry in (__bridge NSArray *)list) {
            id flag=entry[(__bridge id)kVTVideoEncoderList_IsHardwareAccelerated];
            if ([entry[(__bridge id)kVTVideoEncoderList_EncoderID] isEqual:actual] &&
                [entry[(__bridge id)kVTVideoEncoderList_CodecType] unsignedIntValue]==kCMVideoCodecType_JPEG &&
                flag && CFEqual((__bridge CFTypeRef)flag,kCFBooleanTrue)) hardware=YES;
        }
    }
    if (list) CFRelease(list);
    if (!hardware) fail([NSString stringWithFormat:@"VT JPEG hardware verification failed [%@]: actual=%@ expected=%@ property=%d registry=%d",
                         stage,actual ?: @"unavailable",vtEncoderID,status,listStatus]);
    fprintf(stderr,"VT JPEG hardware confirmed [%s]: EncoderID=%s registry_hardware=true quality=%.2f\n",
            stage.UTF8String,actual.UTF8String,vtQuality);
}

static void ensureVTEncoder(NSUInteger generation) {
    if (vtSession && vtGeneration==generation) return;
    invalidateVTEncoder();
    vtEncoderID=hardwareJPEGEncoder();
    NSDictionary *spec=@{(__bridge id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES,
                          (__bridge id)kVTVideoEncoderSpecification_EncoderID:vtEncoderID};
    NSDictionary *source=@{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
    OSStatus status=VTCompressionSessionCreate(kCFAllocatorDefault,1920,720,kCMVideoCodecType_JPEG,
        (__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)source,NULL,NULL,NULL,&vtSession);
    if (status!=noErr || !vtSession) fail([NSString stringWithFormat:@"Cannot create required-hardware VT JPEG session: %d",status]);
    status=VTSessionSetProperty(vtSession,kVTCompressionPropertyKey_Quality,(__bridge CFNumberRef)@(vtQuality));
    if (status!=noErr) fail([NSString stringWithFormat:@"VT JPEG quality configuration failed: %d",status]);
    status=VTCompressionSessionPrepareToEncodeFrames(vtSession);
    if (status!=noErr) fail([NSString stringWithFormat:@"VT JPEG prepare failed: %d",status]);
    vtGeneration=generation;
    verifyVTEncoder(@"before encode");
}

static void writeJPEGFrame(VTDesktopFrame *frame) {
    if (colorCaptureDiagnostic) { frames++; return; }
    if (!frame.jpeg.length || frame.jpeg.length>16*1024*1024-36) fail(@"Invalid VT JPEG frame size");
    // Prefix length excludes itself: JPEG(4), dimensions(8), timestamps(16),
    // bridge encode microseconds(8), followed by the compressed JPEG.
    uint32_t header[]={CFSwapInt32HostToLittle((uint32_t)(36+frame.jpeg.length)),0,
        CFSwapInt32HostToLittle((uint32_t)frame.width),CFSwapInt32HostToLittle((uint32_t)frame.height)};
    memcpy(&header[1],"JPEG",4);
    uint64_t stamp=CFSwapInt64HostToLittle(frame.capturedAt);
    uint64_t epoch=CFSwapInt64HostToLittle(frame.generation);
    uint64_t encode=CFSwapInt64HostToLittle(frame.encodeMicroseconds);
    if (fwrite(header,1,sizeof(header),stdout)!=sizeof(header) || fwrite(&stamp,1,8,stdout)!=8 ||
        fwrite(&epoch,1,8,stdout)!=8 || fwrite(&encode,1,8,stdout)!=8 ||
        fwrite(frame.jpeg.bytes,1,frame.jpeg.length,stdout)!=frame.jpeg.length || fflush(stdout)) exit(0);
    frames++;
    if (frames==1 || frames%120==0) fprintf(stderr,"Captured virtual desktop: %llu frames (JPEG); %zu bytes; VT encode %.3fms\n",
                                           frames,frame.jpeg.length,frame.encodeMicroseconds/1000.0);
}

static void encodeVTFrame(SCStream *stream,CVPixelBufferRef pixels,uint64_t capturedAt,NSUInteger generation,
                          size_t w,size_t h,size_t pw,size_t ph) {
    if (CVPixelBufferGetWidth(pixels)!=1920 || CVPixelBufferGetHeight(pixels)!=720)
        fail(@"VT JPEG requires 1920x720 stream output; use native output or MSI_BRIDGE_ENCODER=raw");
    ensureVTEncoder(generation);
    VTDesktopFrame *frame=[VTDesktopFrame new];
    frame.width=CVPixelBufferGetWidth(pixels); frame.height=CVPixelBufferGetHeight(pixels);
    frame.capturedAt=capturedAt; frame.generation=generation;
    frame.startedAt=monotonicMicroseconds();
    // SCK's pixel buffer goes straight to VT: no lock, packed-BGRA allocation or
    // application pixel copy. The output block owns its frame context safely.
    OSStatus status=VTCompressionSessionEncodeFrameWithOutputHandler(vtSession,pixels,
        CMTimeMake((int64_t)++vtSequence,60),kCMTimeInvalid,NULL,NULL,
        ^(OSStatus callbackStatus,VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
            frame.encodeMicroseconds=monotonicMicroseconds()-frame.startedAt;
            frame.status=callbackStatus;
            frame.dropped=(flags & kVTEncodeInfo_FrameDropped)!=0;
            if (callbackStatus!=noErr || frame.dropped || !sample) return;
            CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
            size_t count=block?CMBlockBufferGetDataLength(block):0;
            if (!count || count>16*1024*1024-36) { frame.status=paramErr; return; }
            NSMutableData *jpeg=[NSMutableData dataWithLength:count];
            frame.status=CMBlockBufferCopyDataBytes(block,0,count,jpeg.mutableBytes);
            if (frame.status==noErr) frame.jpeg=jpeg;
        });
    // One frame in flight bounds the encoder queue. CompleteFrames drains all
    // output blocks before this callback can accept the next SCK sample.
    if (status==noErr) status=VTCompressionSessionCompleteFrames(vtSession,kCMTimeInvalid);
    if (status!=noErr || frame.status!=noErr) {
        recoverStream(stream,[NSString stringWithFormat:@"VT JPEG encode failed: submission=%d callback=%d",status,frame.status]);
        return;
    }
    if (frame.dropped) return;
    if (!frame.jpeg) { recoverStream(stream,@"VT JPEG encoder returned no image"); return; }
    if (!vtVerifiedOutput) { verifyVTEncoder(@"after first encode"); vtVerifiedOutput=YES; }
    __block BOOL current;
    dispatch_sync(dispatch_get_main_queue(), ^{
        size_t cw,ch,cpw,cph;
        current=stream==liveStream && generation==captureEpoch && !systemSleeping && !screensSleeping &&
            currentGeometry(&cw,&ch,&cpw,&cph) && cw==w && ch==h && cpw==pw && cph==ph &&
            sourceWidth==w && sourceHeight==h && sourcePixelWidth==pw && sourcePixelHeight==ph;
    });
    if (current) writeJPEGFrame(frame);
}

@implementation DesktopStreamOutput
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    recoverStream(stream,[NSString stringWithFormat:@"Continuous capture stopped: %@",error.localizedDescription]);
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    @autoreleasepool {
        if (type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
        __block BOOL active; __block NSUInteger generation;
        dispatch_sync(dispatch_get_main_queue(), ^{
            active=stream==liveStream && !systemSleeping && !screensSleeping;
            generation=captureEpoch;
        });
        if (!active) return;
        CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);
        if (!pixels) return;
        CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
        if (attachments && CFArrayGetCount(attachments)>0) {
            NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments,0);
            NSNumber *status=info[SCStreamFrameInfoStatus];
            if (status && status.integerValue!=SCFrameStatusComplete) return;
        }
        size_t w,h,pw,ph;
        if (!currentGeometry(&w,&h,&pw,&ph) || w!=sourceWidth || h!=sourceHeight || pw!=sourcePixelWidth || ph!=sourcePixelHeight) return;
        uint64_t timestamp=(uint64_t)(NSDate.date.timeIntervalSince1970*1000000.0);
        size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
        if (!width || !height || width>3840 || height>1440) fail(@"Invalid stream frame dimensions");
        if (CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_32BGRA) fail(@"Unexpected stream pixel format");
        if (useVTJPEG) {
            encodeVTFrame(stream,pixels,timestamp,generation,w,h,pw,ph);
            return;
        }
        if (CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) fail(@"Cannot lock stream pixels");
        NSMutableData *data=[NSMutableData dataWithLength:width*height*4];
        size_t stride=CVPixelBufferGetBytesPerRow(pixels);
        const uint8_t *src=CVPixelBufferGetBaseAddress(pixels);
        for (size_t row=0;row<height;row++) memcpy((uint8_t *)data.mutableBytes+row*width*4,src+row*stride,width*4);
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
        writeRawFrame(data,width,height,"BGRA",timestamp,generation);
    }
}
@end

static void capture(void) {
    if (busy || systemSleeping || screensSleeping || NSDate.timeIntervalSinceReferenceDate<captureRetryAfter) return;
    busy = YES;
    NSUInteger epoch=captureEpoch;
    size_t w,h,pw,ph;
    if (!currentGeometry(&w,&h,&pw,&ph)) { busy=NO; return; }
    if (w!=sourceWidth || h!=sourceHeight || pw!=sourcePixelWidth || ph!=sourcePixelHeight) {
        // SCDisplay/SCContentFilter describe a snapshot. Rebuild them after a
        // mode change instead of capturing the old rectangle with black padding.
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) { recoverStream(nil,error.localizedDescription); return; }
            SCDisplay *target=nil;
            for (SCDisplay *display in content.displays) if (display.displayID==captureDisplayID) target=display;
            if (!target) { dispatch_async(dispatch_get_main_queue(), ^{ busy=NO; }); return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (epoch!=captureEpoch || systemSleeping || screensSleeping) return;
                size_t cw,ch,cpw,cph;
                if (!currentGeometry(&cw,&ch,&cpw,&cph) || cw!=w || ch!=h || cpw!=pw || cph!=ph) { busy=NO; return; }
                filter=[[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
                configuration.sourceRect=CGRectMake(0,0,w,h);
                configuration.destinationRect=CGRectMake(0,0,configuration.width,configuration.height);
                configuration.scalesToFit=YES;
                configuration.preservesAspectRatio=NO;
                sourceWidth=w; sourceHeight=h; sourcePixelWidth=pw; sourcePixelHeight=ph;
                fprintf(stderr,"Capture geometry refreshed: %zux%zu logical, %zux%zu pixels -> %zux%zu output, stretch to fill\n",w,h,pw,ph,configuration.width,configuration.height);
                if (useContinuousStream) {
                    if (!liveStream) {
                        streamOutput=[DesktopStreamOutput new];
                        if (!captureQueue) captureQueue=dispatch_queue_create("com.digiter.msixpander.capture",DISPATCH_QUEUE_SERIAL);
                        liveStream=[[SCStream alloc] initWithFilter:filter configuration:configuration delegate:streamOutput];
                        NSError *error=nil;
                        SCStream *starting=liveStream;
                        if (![liveStream addStreamOutput:streamOutput type:SCStreamOutputTypeScreen sampleHandlerQueue:captureQueue error:&error]) {
                            resetCapture(error.localizedDescription ?: @"Cannot add continuous capture output"); return;
                        }
                        [starting startCaptureWithCompletionHandler:^(NSError *error) {
                            if (error) { recoverStream(starting,error.localizedDescription); return; }
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (starting!=liveStream) return;
                                fprintf(stderr,"Continuous capture running on retained virtual display %u\n",captureDisplayID);
                                preservePhysicalHDR(@"capture started/recovered");
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(), ^{preservePhysicalHDR(@"capture settled");});
                                busy=NO;
                            });
                        }];
                    } else {
                        SCStream *updating=liveStream;
                        [updating updateContentFilter:filter completionHandler:^(NSError *error) {
                            if (error) { recoverStream(updating,error.localizedDescription); return; }
                            [updating updateConfiguration:configuration completionHandler:^(NSError *error) {
                                if (error) { recoverStream(updating,error.localizedDescription); return; }
                                dispatch_async(dispatch_get_main_queue(), ^{ if (updating==liveStream) busy=NO; });
                            }];
                        }];
                    }
                    return;
                }
                busy=NO;
                capture();
            });
        }];
        return;
    }
    if (useContinuousStream) { busy=NO; return; }
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
        completionHandler:^(CGImageRef image, NSError *error) {
        if (epoch!=captureEpoch || systemSleeping || screensSleeping) return;
        size_t cw,ch,cpw,cph;
        // Discard an in-flight frame from the previous mode; refresh next tick.
        if (!currentGeometry(&cw,&ch,&cpw,&cph) || cw!=w || ch!=h || cpw!=pw || cph!=ph) {
            dispatch_async(dispatch_get_main_queue(), ^{ busy=NO; }); return;
        }
        if (!image || error) { recoverStream(nil,error.localizedDescription ?: @"No captured image"); return; }
        uint64_t capturedAt=(uint64_t)(NSDate.date.timeIntervalSince1970*1000000.0);
        size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
        if (!width || !height || width>3840 || height>1440) fail(@"Invalid captured dimensions");
        NSMutableData *rgba=[NSMutableData dataWithLength:width*height*4];
        CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(rgba.mutableBytes,width,height,8,width*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(color);
        if (!context) fail(@"Cannot allocate raw capture surface");
        CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
        CGContextRelease(context);
        // Bounded frame protocol: length, RGBA magic, dimensions, timestamp,
        // then tightly packed pixels. No intermediate PNG compression.
        writeRawFrame(rgba,width,height,"RGBA",capturedAt,epoch);
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    }];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *encoder=NSProcessInfo.processInfo.environment[@"MSI_BRIDGE_ENCODER"] ?: @"raw";
        if (![encoder isEqualToString:@"raw"] && ![encoder isEqualToString:@"vt"])
            fail(@"MSI_BRIDGE_ENCODER must be raw or vt");
        useVTJPEG=[encoder isEqualToString:@"vt"];
        if (useVTJPEG) {
            NSString *backend=NSProcessInfo.processInfo.environment[@"MSI_CAPTURE_BACKEND"] ?: @"stream";
            if (![backend isEqualToString:@"stream"]) fail(@"MSI_BRIDGE_ENCODER=vt requires MSI_CAPTURE_BACKEND=stream");
            const char *setting=getenv("MSI_VT_QUALITY");
            if (setting) {
                char *end=NULL;
                vtQuality=strtod(setting,&end);
                if (end==setting || *end || !isfinite(vtQuality) || vtQuality<0 || vtQuality>1)
                    fail(@"MSI_VT_QUALITY must be a number from 0 to 1");
            }
            if ([NSProcessInfo.processInfo.environment[@"MSI_DESKTOP_MODE"] isEqualToString:@"legacy"])
                fail(@"VT JPEG requires 1920x720 output; MSI_DESKTOP_MODE=legacy is unsupported");
        }
        fprintf(stderr,"Bridge encoder: %s%s\n",encoder.UTF8String,useVTJPEG?" (required hardware JPEG)":" (raw BGRA/RGBA)");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSNotificationCenter *workspace=NSWorkspace.sharedWorkspace.notificationCenter;
        [workspace addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            systemSleeping=YES; resetCapture(@"System entering sleep");
        }];
        [workspace addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            screensSleeping=YES; resetCapture(@"Displays entering sleep");
        }];
        [workspace addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            systemSleeping=NO; resetCapture(@"System woke; waiting for displays and capture services");
        }];
        [workspace addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            screensSleeping=NO; resetCapture(@"Displays woke; rebuilding capture");
        }];
        // Fault injection uses the same reset path without sleeping the Mac.
        double testRecovery=[NSProcessInfo.processInfo.environment[@"MSI_TEST_RECOVERY_AFTER_SECONDS"] doubleValue];
        if (testRecovery>0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(testRecovery*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
            systemSleeping=YES; resetCapture(@"TEST: simulated sleep");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                systemSleeping=NO; resetCapture(@"TEST: simulated wake");
            });
        });
        if (argc > 1 && strcmp(argv[1], "--check") == 0) {
            fprintf(stderr, "Virtual display API: %s; Screen recording: %s\n",
                NSClassFromString(@"CGVirtualDisplay") ? "available" : "unavailable",
                CGPreflightScreenCaptureAccess() ? "allowed" : "not authorized");
            return 0;
        }
        if (!CGPreflightScreenCaptureAccess()) {
            CGRequestScreenCaptureAccess();
            fprintf(stderr, "SCREEN_RECORDING_REQUIRED: Enable MSI Xpander Desktop in System Settings > Privacy & Security > Screen & System Audio Recording, then run again.\n");
            return 77;
        }
        recordPhysicalHDR();
        performanceActivity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep|NSActivityLatencyCritical reason:@"Low-latency local Xpander display streaming"];
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        if (!descriptorClass || !displayClass || !settingsClass || !modeClass) fail(@"Virtual display API unavailable on this macOS");
        CGDirectDisplayID originalDisplays[32]; uint32_t originalCount=0;
        if (CGGetOnlineDisplayList(32,originalDisplays,&originalCount)!=kCGErrorSuccess) fail(@"Cannot inventory existing displays safely");
        NSString *desktopMode = NSProcessInfo.processInfo.environment[@"MSI_DESKTOP_MODE"] ?: @"native";
        BOOL legacy = [desktopMode isEqualToString:@"legacy"];
        BOOL largeHiDPI = [desktopMode isEqualToString:@"hidpi-large"];
        BOOL hiDPI = [desktopMode isEqualToString:@"hidpi"] || largeHiDPI;
        if (!legacy && !hiDPI && ![desktopMode isEqualToString:@"native"]) fail(@"MSI_DESKTOP_MODE must be hidpi, native, or legacy");
        unsigned int pixelWidth = legacy ? 1440 : 1920, pixelHeight = legacy ? 540 : 720;
        // Native 2x Retina: 960x360 points map to 1920x720 panel pixels.
        unsigned int renderWidth = largeHiDPI ? pixelWidth*2 : pixelWidth;
        unsigned int renderHeight = largeHiDPI ? pixelHeight*2 : pixelHeight;
        unsigned int logicalWidth = hiDPI && !largeHiDPI ? pixelWidth/2 : pixelWidth;
        unsigned int logicalHeight = hiDPI && !largeHiDPI ? pixelHeight/2 : pixelHeight;
        id descriptor = [descriptorClass new];
        [descriptor setValue:@"MSI Xpander Desktop" forKey:@"name"];
        [descriptor setValue:@(hiDPI ? 3840 : renderWidth) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(hiDPI ? 1440 : renderHeight) forKey:@"maxPixelsHigh"];
        [descriptor setValue:@3504 forKey:@"vendorID"];
        [descriptor setValue:@31008 forKey:@"productID"];
        [descriptor setValue:@20261030 forKey:@"serialNum"];
        [descriptor setValue:@20261030 forKey:@"serialNumber"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(290,109)] forKey:@"sizeInMillimeters"];
        NSString *virtualColorMode=NSProcessInfo.processInfo.environment[@"MSI_VIRTUAL_COLOR_MODE"] ?: @"system-default";
        BOOL systemColor=[virtualColorMode isEqualToString:@"system-default"];
        if (!systemColor) {
            [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.64,0.33)] forKey:@"redPrimary"];
            [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.30,0.60)] forKey:@"greenPrimary"];
            [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.15,0.06)] forKey:@"bluePrimary"];
            [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127,0.3290)] forKey:@"whitePoint"];
        }
        fprintf(stderr,"Virtual color descriptor: %s\n",systemColor?"system defaults":"explicit sRGB primaries");
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        virtualDisplay = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!virtualDisplay) fail(@"Could not create virtual display");
        id settings = [settingsClass new];
        [settings setValue:@(hiDPI) forKey:@"hiDPI"];
        id mode = [[modeClass alloc] initWithWidth:logicalWidth height:logicalHeight refreshRate:60];
        NSMutableArray *offeredModes=[NSMutableArray arrayWithObject:mode];
        if (hiDPI) {
            for (NSArray<NSNumber *> *size in @[@[@1280,@480],@[@1600,@600],@[@1920,@720]]) {
                [offeredModes addObject:[[modeClass alloc] initWithWidth:size[0].unsignedIntValue height:size[1].unsignedIntValue refreshRate:60]];
            }
        }
        [settings setValue:offeredModes forKey:@"modes"];
        if (![virtualDisplay applySettings:settings]) fail(@"Could not apply virtual display mode");
        CGDirectDisplayID displayID = [virtualDisplay displayID];
        captureDisplayID=displayID;
        // A name containing MSI is not an identity check: the user also has a
        // physical MSI ultrawide. Only the newly allocated virtual ID may change.
        for (uint32_t i=0;i<originalCount;i++) {
            if (displayID==originalDisplays[i]) fail(@"Refusing to configure an existing physical display ID");
        }
        if (!displayID || displayID==CGMainDisplayID()) fail(@"Refusing to configure the main display");
        fprintf(stderr,"Owned virtual display ID %u; existing display IDs excluded from configuration\n",displayID);
        BOOL allocationOnly=[NSProcessInfo.processInfo.environment[@"MSI_COLOR_DIAGNOSTIC"] isEqualToString:@"allocation-only"];
        if (allocationOnly) {
            fprintf(stderr,"COLOR DIAGNOSTIC: allocate/apply virtual display only; no layout transaction, explicit mode selection, capture, or USB. Exit in 20 seconds.\n");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(), ^{exit(0);});
        }
        if (!allocationOnly) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Only the new display is moved; the existing display layout is preserved.
            CGDirectDisplayID displays[32]; uint32_t count = 0; int right = 0;
            if (CGGetActiveDisplayList(32, displays, &count) != kCGErrorSuccess) fail(@"Cannot read display layout");
            for (uint32_t i=0; i<count; i++) if (displays[i] != displayID) right = MAX(right, CGRectGetMaxX(CGDisplayBounds(displays[i])));
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) fail(@"Cannot configure display");
            CGError e = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
            if (e == kCGErrorSuccess) e = CGConfigureDisplayOrigin(config, displayID, right, 0);
            if (e == kCGErrorSuccess) e = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            else CGCancelDisplayConfiguration(config);
            if (e != kCGErrorSuccess) fail(@"Cannot place virtual desktop to the right");
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES});
            BOOL selected = NO;
            for (CFIndex i=0; modes && i<CFArrayGetCount(modes); i++) {
                CGDisplayModeRef candidate = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
                fprintf(stderr,"Available mode: %zux%zu logical, %zux%zu pixels\n",CGDisplayModeGetWidth(candidate),CGDisplayModeGetHeight(candidate),CGDisplayModeGetPixelWidth(candidate),CGDisplayModeGetPixelHeight(candidate));
                if (!selected && CGDisplayModeGetWidth(candidate)==logicalWidth && CGDisplayModeGetHeight(candidate)==logicalHeight && CGDisplayModeGetPixelWidth(candidate)==renderWidth && CGDisplayModeGetPixelHeight(candidate)==renderHeight) {
                    selected = CGDisplaySetDisplayMode(displayID,candidate,NULL)==kCGErrorSuccess;
                }
            }
            if (modes) CFRelease(modes);
            if (!selected) fail(@"Requested Retina/native mode not offered or could not be selected");
            CGDisplayModeRef activeMode = CGDisplayCopyDisplayMode(displayID);
            if (!activeMode) fail(@"Cannot inspect active display mode");
            fprintf(stderr, "Virtual desktop %u: %zux%zu logical, %zux%zu pixels, HiDPI=%s; right edge at x=%d\n", displayID,
                CGDisplayModeGetWidth(activeMode), CGDisplayModeGetHeight(activeMode),
                CGDisplayModeGetPixelWidth(activeMode), CGDisplayModeGetPixelHeight(activeMode),hiDPI?"yes":"no",right);
            BOOL correct = CGDisplayModeGetPixelWidth(activeMode)==renderWidth && CGDisplayModeGetPixelHeight(activeMode)==renderHeight;
            CGDisplayModeRelease(activeMode);
            if (!correct) fail(@"Active display pixel dimensions differ from requested output");
            preservePhysicalHDR(@"virtual display configured");
            if ([NSProcessInfo.processInfo.environment[@"MSI_COLOR_DIAGNOSTIC"] isEqualToString:@"virtual-only"]) {
                fprintf(stderr,"COLOR DIAGNOSTIC: virtual display only, no screen capture or USB writes. Automatically exiting in 20 seconds.\n");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(), ^{exit(0);});
                return;
            }
            colorCaptureDiagnostic=[NSProcessInfo.processInfo.environment[@"MSI_COLOR_DIAGNOSTIC"] isEqualToString:@"capture-staged"];
            void (^startContentCapture)(void)=^{
            fprintf(stderr,"COLOR DIAGNOSTIC / CAPTURE: starting screen capture\n");
            [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
                if (error) { fail(error.localizedDescription); return; }
                SCDisplay *target = nil;
                for (SCDisplay *d in content.displays) if (d.displayID == displayID) target = d;
                if (!target) fail(@"Virtual display not found by ScreenCaptureKit");
                filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
                configuration = [SCStreamConfiguration new];
                configuration.width = pixelWidth; configuration.height = pixelHeight;
                configuration.showsCursor = YES;
                NSString *backend=NSProcessInfo.processInfo.environment[@"MSI_CAPTURE_BACKEND"] ?: @"stream";
                useContinuousStream=[backend isEqualToString:@"stream"];
                double targetFPS=[NSProcessInfo.processInfo.environment[@"MSI_DESKTOP_FPS"] ?: @"60" doubleValue];
                if (targetFPS<1 || targetFPS>60) fail(@"MSI_DESKTOP_FPS must be between 1 and 60");
                configuration.minimumFrameInterval=CMTimeMake(1,(int32_t)targetFPS);
                configuration.queueDepth=3;
                configuration.pixelFormat=kCVPixelFormatType_32BGRA;
                NSString *captureColor=NSProcessInfo.processInfo.environment[@"MSI_CAPTURE_COLOR_MODE"] ?: @"display";
                if ([captureColor isEqualToString:@"srgb"]) configuration.colorSpaceName=kCGColorSpaceSRGB;
                fprintf(stderr,"Capture color conversion: %s\n",[captureColor isEqualToString:@"srgb"]?"forced sRGB":"source display default");
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL showTestWindow=[NSProcessInfo.processInfo.environment[@"MSI_DESKTOP_TEST_WINDOW"] isEqualToString:@"1"];
                    fprintf(stderr,"Desktop test window: %s\n",showTestWindow?"enabled":"disabled");
                    if (showTestWindow) {
                    for (NSScreen *screen in NSScreen.screens) {
                        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] != displayID) continue;
                        testWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(20,30,650,250)
                            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
                            backing:NSBackingStoreBuffered defer:NO screen:screen];
                        testWindow.title = @"MSI Xpander — Live Extended Desktop";
                        NSTextField *label = [NSTextField labelWithString:@"Live extended desktop"];
                        label.frame = NSMakeRect(25,50,600,140); label.font = [NSFont systemFontOfSize:28];
                        label.maximumNumberOfLines = 4;
                        [testWindow.contentView addSubview:label];
                        // AppKit can initially constrain a new window to the main
                        // screen. Place it in global Cocoa coordinates *after*
                        // creation, and recheck once display reconfiguration settles.
                        void (^placeWindow)(void) = ^{
                            for (NSScreen *current in NSScreen.screens) {
                                if ([current.deviceDescription[@"NSScreenNumber"] unsignedIntValue] != displayID) continue;
                                NSRect rect = NSMakeRect(current.frame.origin.x+20,current.frame.origin.y+30,650,280);
                                [testWindow setFrame:rect display:YES];
                                [testWindow orderFront:nil];
                                fprintf(stderr, "Clock window target display %u, actual display %u, frame %s\n", displayID,
                                    [testWindow.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue], NSStringFromRect(testWindow.frame).UTF8String);
                            }
                        };
                        placeWindow();
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), placeWindow);
                        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
                            label.stringValue = [NSString stringWithFormat:@"MSI Xpander — Live Desktop\n%@\nDrag a window onto this screen", [NSDate date]];
                        }];
                    }
                    }
                    NSString *fpsText=NSProcessInfo.processInfo.environment[@"MSI_DESKTOP_FPS"];
                    double fps=fpsText?fpsText.doubleValue:60;
                    if (fps<1 || fps>60) fail(@"MSI_DESKTOP_FPS must be between 1 and 60");
                    fprintf(stderr,"Capture target: %.0f fps; backend=%s\n",fps,useContinuousStream?"continuous SCStream":"screenshots");
                    [NSTimer scheduledTimerWithTimeInterval:useContinuousStream?0.1:1.0/fps repeats:YES block:^(NSTimer *timer) { capture(); }];
                    capture();
                });
            }];
            };
            if (colorCaptureDiagnostic) {
                fprintf(stderr,"COLOR DIAGNOSTIC: virtual-only 5 seconds, capture 10 seconds, capture stopped with virtual retained 10 seconds; no USB writes.\n");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),startContentCapture);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                    screensSleeping=YES; resetCapture(@"COLOR DIAGNOSTIC: capture OFF, virtual display still retained");
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(), ^{exit(0);});
            } else startContentCapture();
        });
        [NSApp run];
    }
    return 0;
}
