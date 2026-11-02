// AppKit/ScreenSaver -> persistent hardware JPEG. No display registration,
// screen capture, network access or USB. stdout uses the existing JPEG bridge.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <VideoToolbox/VideoToolbox.h>
#include <signal.h>
#include <sys/time.h>
#include <math.h>

static volatile sig_atomic_t stopping;
static void stop(int signum) { (void)signum; stopping=1; }
static void fail(NSString *message) {
    fprintf(stderr,"NativeKiosk: %s\n",message.UTF8String); exit(2);
}
static uint64_t nowUS(void) {
    struct timeval stamp; gettimeofday(&stamp,NULL);
    return (uint64_t)stamp.tv_sec*1000000+(uint64_t)stamp.tv_usec;
}
static void text(NSString *string,NSRect rect,NSFont *font,NSColor *color) {
    [string drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color}];
}
static NSColor *rgb(CGFloat r,CGFloat g,CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
}

@interface XpanderClockSaver : ScreenSaverView
@property(nonatomic) NSTimeInterval phase;
@end
@implementation XpanderClockSaver
- (void)animateOneFrame { self.phase=NSDate.timeIntervalSinceReferenceDate; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    [[NSColor blackColor] setFill]; NSRectFill(self.bounds);
    NSDateFormatter *format=[NSDateFormatter new];
    NSString *language=NSProcessInfo.processInfo.environment[@"MSI_UI_LANGUAGE"];
    if(language)format.locale=[NSLocale localeWithLocaleIdentifier:[language hasPrefix:@"zh"]?@"zh_TW":@"en_US"];
    format.dateFormat=@"HH:mm:ss";
    CGFloat x=140+110*(1+sin(self.phase/37)),y=210+85*(1+cos(self.phase/43));
    text([format stringFromDate:NSDate.date],NSMakeRect(x,y,1450,180),
         [NSFont monospacedDigitSystemFontOfSize:160 weight:NSFontWeightLight],rgb(.88,.94,1));
    format.dateStyle=NSDateFormatterFullStyle; format.timeStyle=NSDateFormatterNoStyle;
    text([format stringFromDate:NSDate.date],NSMakeRect(x+8,y-48,1400,50),
         [NSFont systemFontOfSize:31 weight:NSFontWeightRegular],rgb(.45,.6,.74));
}
@end

static void card(NSRect rect) {
    [rgb(.065,.08,.105) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:30 yRadius:30] fill];
}
static void dashboard(void) {
    [rgb(.025,.035,.05) setFill]; NSRectFill(NSMakeRect(0,0,1920,720));
    card(NSMakeRect(40,40,1120,640)); card(NSMakeRect(1190,40,690,640));
    NSDate *date=NSDate.date;
    NSDateFormatter *format=[NSDateFormatter new];
    NSString *language=NSProcessInfo.processInfo.environment[@"MSI_UI_LANGUAGE"];
    if(language)format.locale=[NSLocale localeWithLocaleIdentifier:[language hasPrefix:@"zh"]?@"zh_TW":@"en_US"];
    format.dateFormat=@"HH:mm:ss";
    text([format stringFromDate:date],NSMakeRect(90,418,1030,190),
         [NSFont monospacedDigitSystemFontOfSize:154 weight:NSFontWeightLight],rgb(.94,.96,1));
    format.dateStyle=NSDateFormatterFullStyle; format.timeStyle=NSDateFormatterNoStyle;
    text([format stringFromDate:date],NSMakeRect(100,365,1000,60),[NSFont systemFontOfSize:34],rgb(.55,.7,.86));
    NSProcessInfo *process=NSProcessInfo.processInfo;
    double load[3]={0}; getloadavg(load,3);
    text(@"MAC SYSTEM",NSMakeRect(100,270,950,40),[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],rgb(.4,.65,.85));
    text(process.hostName,NSMakeRect(100,205,1000,55),[NSFont systemFontOfSize:36 weight:NSFontWeightMedium],rgb(.88,.92,.97));
    NSString *stats=[NSString stringWithFormat:@"%lu cores    %.0f GB memory    Load %.2f",
        (unsigned long)process.processorCount,process.physicalMemory/(1024.*1024*1024),load[0]];
    text(stats,NSMakeRect(100,145,1000,45),[NSFont monospacedSystemFontOfSize:25 weight:NSFontWeightRegular],rgb(.6,.7,.8));
    text([NSString stringWithFormat:@"Uptime %.1f hours",process.systemUptime/3600],NSMakeRect(100,91,1000,40),
         [NSFont systemFontOfSize:24],rgb(.45,.56,.68));
    NSCalendar *calendar=NSCalendar.currentCalendar;
    format.dateFormat=@"LLLL yyyy";
    text([format stringFromDate:date],NSMakeRect(1240,576,590,60),[NSFont systemFontOfSize:36 weight:NSFontWeightMedium],rgb(.9,.95,1));
    NSDateComponents *components=[calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];
    NSInteger today=components.day; components.day=1;
    NSDate *first=[calendar dateFromComponents:components];
    NSInteger offset=([calendar component:NSCalendarUnitWeekday fromDate:first]-calendar.firstWeekday+7)%7;
    NSArray *days=format.veryShortStandaloneWeekdaySymbols;
    for (NSInteger column=0;column<7;column++) {
        text(days[(column+calendar.firstWeekday-1)%7],NSMakeRect(1247+column*84,506,80,40),
             [NSFont systemFontOfSize:24],rgb(.5,.65,.8));
    }
    NSUInteger count=[calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:date].length;
    for (NSUInteger day=1;day<=count;day++) {
        NSInteger cell=offset+(NSInteger)day-1, column=cell%7, row=cell/7;
        NSRect rect=NSMakeRect(1238+column*84,432-row*69,65,57);
        if ((NSInteger)day==today) { [rgb(.12,.4,.68) setFill]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:15 yRadius:15] fill]; }
        text([NSString stringWithFormat:@"%2lu",(unsigned long)day],NSInsetRect(rect,9,6),
             [NSFont monospacedDigitSystemFontOfSize:29 weight:NSFontWeightMedium],rgb(.9,.93,.98));
    }
}

static NSData *encoded;
static void encodedFrame(void *refcon,void *source,OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
    (void)refcon;(void)source;(void)flags;
    if (status || !sample) return;
    CMBlockBufferRef buffer=CMSampleBufferGetDataBuffer(sample);
    size_t size=buffer?CMBlockBufferGetDataLength(buffer):0;
    if (!size) return;
    NSMutableData *bytes=[NSMutableData dataWithLength:size];
    if (!CMBlockBufferCopyDataBytes(buffer,0,size,bytes.mutableBytes)) encoded=bytes;
}
static NSString *hardwareEncoder(void) {
    CFArrayRef array=NULL;
    if (VTCopyVideoEncoderList(NULL,&array) || !array) return nil;
    NSString *result=nil;
    for (NSDictionary *entry in (__bridge NSArray *)array)
        if ([entry[(__bridge id)kVTVideoEncoderList_CodecType] unsignedIntValue]==kCMVideoCodecType_JPEG &&
            [entry[(__bridge id)kVTVideoEncoderList_IsHardwareAccelerated] boolValue]) {
            result=entry[(__bridge id)kVTVideoEncoderList_EncoderID]; break;
        }
    CFRelease(array); return result;
}
static void verifyEncoder(VTCompressionSessionRef session,NSString *selected) {
    CFTypeRef actual=NULL;
    OSStatus status=VTSessionCopyProperty(session,kVTCompressionPropertyKey_EncoderID,NULL,&actual);
    BOOL valid=!status && actual && CFGetTypeID(actual)==CFStringGetTypeID() && [selected isEqual:(__bridge id)actual];
    if (actual) CFRelease(actual);
    if (!valid) fail(@"Session did not select the registered hardware JPEG encoder");
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSApplication *application=NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
        BOOL saver=[NSProcessInfo.processInfo.environment[@"MSI_NATIVE_KIOSK_STYLE"] isEqualToString:@"screensaver"];
        NSString *preview=nil;
        NSUInteger limit=0;
        for (int i=1;i<argc;i++) {
            if (!strcmp(argv[i],"--preview") && i+1<argc) preview=[NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i],"--frames") && i+1<argc) limit=(NSUInteger)strtoul(argv[++i],NULL,10);
            else fail(@"Usage: NativeKioskRenderer [--preview image.png] [--frames N]");
        }
        double quality=1.0;
        NSString *setting=NSProcessInfo.processInfo.environment[@"MSI_VT_QUALITY"];
        if (setting) {
            const char *start=setting.UTF8String; char *end=NULL; quality=strtod(start,&end);
            if (end==start || *end || !isfinite(quality) || quality<0 || quality>1) fail(@"Invalid JPEG quality");
        }
        NSString *identifier=hardwareEncoder(); if (!identifier) fail(@"Hardware JPEG unavailable");
        VTCompressionSessionRef session=NULL;
        NSDictionary *spec=@{(__bridge id)kVTVideoEncoderSpecification_EncoderID:identifier};
        if (VTCompressionSessionCreate(NULL,1920,720,kCMVideoCodecType_JPEG,(__bridge CFDictionaryRef)spec,NULL,NULL,encodedFrame,NULL,&session)) fail(@"Cannot create hardware JPEG session");
        if (VTSessionSetProperty(session,kVTCompressionPropertyKey_Quality,(__bridge CFNumberRef)@(quality)) ||
            VTCompressionSessionPrepareToEncodeFrames(session)) fail(@"Cannot prepare hardware JPEG session");
        verifyEncoder(session,identifier);
        fprintf(stderr,"NativeKiosk: style=%s EncoderID=%s registry_hardware=true quality=%.2f; no virtual display or screen capture\n",
                saver?"screensaver":"dashboard",identifier.UTF8String,quality);
        XpanderClockSaver *view=[[XpanderClockSaver alloc] initWithFrame:NSMakeRect(0,0,1920,720) isPreview:NO];
        // A private, never-ordered window supplies normal ScreenSaverView
        // hosting without registering a display or recording any screen.
        NSWindow *host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1920,720)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        host.contentView=view;
        if (saver) [view startAnimation];
        signal(SIGINT,stop); signal(SIGTERM,stop); signal(SIGPIPE,SIG_IGN);
        NSUInteger frame=0;
        int frequency=saver?30:1;
        while (!stopping && (!limit || frame<limit)) {
            @autoreleasepool {
                uint64_t captured=nowUS();
                CVPixelBufferRef pixels=NULL;
                NSDictionary *attributes=@{(__bridge id)kCVPixelBufferCGImageCompatibilityKey:@YES,
                    (__bridge id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
                if (CVPixelBufferCreate(NULL,1920,720,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&pixels)) fail(@"Cannot allocate pixels");
                CVPixelBufferLockBaseAddress(pixels,0);
                CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGContextRef bitmap=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),1920,720,8,CVPixelBufferGetBytesPerRow(pixels),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
                CGColorSpaceRelease(color); if (!bitmap) fail(@"Cannot create bitmap");
                NSGraphicsContext *previous=NSGraphicsContext.currentContext;
                NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
                if (saver) { [view animateOneFrame]; [view drawRect:view.bounds]; } else dashboard();
                [NSGraphicsContext.currentContext flushGraphics]; NSGraphicsContext.currentContext=previous;
                if (preview) {
                    CGImageRef image=CGBitmapContextCreateImage(bitmap);
                    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
                    if (![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:preview atomically:YES]) fail(@"Cannot write preview");
                    CGImageRelease(image);
                }
                CGContextRelease(bitmap);
                CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVAttachmentMode_ShouldPropagate);
                CVPixelBufferUnlockBaseAddress(pixels,0);
                encoded=nil;
                uint64_t started=nowUS();
                OSStatus status=VTCompressionSessionEncodeFrame(session,pixels,CMTimeMake((int64_t)frame,frequency),CMTimeMake(1,frequency),NULL,NULL,NULL);
                if (!status) status=VTCompressionSessionCompleteFrames(session,kCMTimeInvalid);
                CVPixelBufferRelease(pixels);
                if (status || !encoded) fail(@"Hardware JPEG produced no frame");
                verifyEncoder(session,identifier);
                uint64_t encodeUS=nowUS()-started;
                uint32_t length=CFSwapInt32HostToLittle((uint32_t)(36+encoded.length));
                uint32_t width=CFSwapInt32HostToLittle(1920),height=CFSwapInt32HostToLittle(720);
                uint64_t stamp=CFSwapInt64HostToLittle(captured),epoch=0,encode=CFSwapInt64HostToLittle(encodeUS);
                BOOL ok=fwrite(&length,4,1,stdout)==1 && fwrite("JPEG",4,1,stdout)==1 &&
                    fwrite(&width,4,1,stdout)==1 && fwrite(&height,4,1,stdout)==1 &&
                    fwrite(&stamp,8,1,stdout)==1 && fwrite(&epoch,8,1,stdout)==1 && fwrite(&encode,8,1,stdout)==1 &&
                    fwrite(encoded.bytes,1,encoded.length,stdout)==encoded.length && !fflush(stdout);
                if (!ok) break;
                frame++;
                if (preview) break;
                NSTimeInterval delay=MAX(0,1.0/frequency-(nowUS()-captured)/1000000.0);
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
            }
        }
        if (saver) [view stopAnimation];
        VTCompressionSessionInvalidate(session); CFRelease(session);
        return 0;
    }
}
