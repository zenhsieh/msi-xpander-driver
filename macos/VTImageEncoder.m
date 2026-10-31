// PNG -> required-hardware JPEG. No virtual display, screen capture or USB.
// stdout is exclusively JPEG bytes; diagnostics are exclusively stderr.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <stdio.h>
#include <time.h>

static void diagnostic(NSString *message) {
    fprintf(stderr,"VTImageEncoder: %s\n",message.UTF8String);
}

static uint64_t microseconds(void) {
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC,&stamp)) return 0;
    return (uint64_t)stamp.tv_sec*1000000+(uint64_t)stamp.tv_nsec/1000;
}

static CVPixelBufferRef loadPNG(const char *path) {
    NSData *input=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!input) { diagnostic(@"Cannot read input PNG"); return NULL; }
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)input,NULL);
    if (!source) { diagnostic(@"Cannot decode image source"); return NULL; }
    CFStringRef type=CGImageSourceGetType(source);
    if (!type || !CFEqual(type,CFSTR("public.png"))) {
        diagnostic(@"Input must be a PNG image"); CFRelease(source); return NULL;
    }
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL);
    CFRelease(source);
    if (!image) { diagnostic(@"Cannot decode PNG pixels"); return NULL; }
    if (CGImageGetWidth(image)!=1920 || CGImageGetHeight(image)!=720) {
        diagnostic(@"Input PNG must be exactly 1920x720"); CGImageRelease(image); return NULL;
    }
    CVPixelBufferRef pixels=NULL;
    NSDictionary *attributes=@{(__bridge id)kCVPixelBufferCGImageCompatibilityKey:@YES,
                               (__bridge id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,
                               (__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    CVReturn status=CVPixelBufferCreate(kCFAllocatorDefault,1920,720,kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes,&pixels);
    if (status!=kCVReturnSuccess || !pixels) {
        diagnostic([NSString stringWithFormat:@"CVPixelBuffer allocation failed: %d",status]);
        CGImageRelease(image); return NULL;
    }
    if (CVPixelBufferLockBaseAddress(pixels,0)!=kCVReturnSuccess) {
        diagnostic(@"Cannot lock PNG destination pixels");
        CGImageRelease(image); CVPixelBufferRelease(pixels); return NULL;
    }
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),1920,720,8,
        CVPixelBufferGetBytesPerRow(pixels),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    if (context) {
        // Flatten any transparency onto black; the panel consumes opaque JPEG.
        CGContextSetRGBFillColor(context,0,0,0,1);
        CGContextFillRect(context,CGRectMake(0,0,1920,720));
        CGContextDrawImage(context,CGRectMake(0,0,1920,720),image);
        CVBufferSetAttachment(pixels,kCVImageBufferCGColorSpaceKey,color,kCVAttachmentMode_ShouldPropagate);
        // JPEG decoders use the full-range BT.601 YCbCr matrix. Without this
        // attachment the hardware encoder may choose BT.709 and tint RGB input.
        CVBufferSetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVAttachmentMode_ShouldPropagate);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(color);
    CVPixelBufferUnlockBaseAddress(pixels,0);
    CGImageRelease(image);
    if (!context) { diagnostic(@"Cannot create PNG bitmap context"); CVPixelBufferRelease(pixels); return NULL; }
    return pixels;
}

static NSString *hardwareJPEGEncoder(void) {
    CFArrayRef list=NULL;
    OSStatus status=VTCopyVideoEncoderList(NULL,&list);
    if (status!=noErr || !list) {
        diagnostic([NSString stringWithFormat:@"Cannot list video encoders: %d",status]); return nil;
    }
    NSMutableArray<NSString *> *candidates=[NSMutableArray array];
    for (NSDictionary *entry in (__bridge NSArray *)list) {
        NSString *identifier=entry[(__bridge id)kVTVideoEncoderList_EncoderID];
        id flag=entry[(__bridge id)kVTVideoEncoderList_IsHardwareAccelerated];
        if ([entry[(__bridge id)kVTVideoEncoderList_CodecType] unsignedIntValue]==kCMVideoCodecType_JPEG &&
            [identifier isKindOfClass:NSString.class] && flag && CFEqual((__bridge CFTypeRef)flag,kCFBooleanTrue))
            [candidates addObject:identifier];
    }
    CFRelease(list);
    [candidates sortUsingSelector:@selector(compare:)];
    if (!candidates.count) { diagnostic(@"No registered hardware JPEG encoder"); return nil; }
    return candidates.firstObject;
}

static BOOL verifyHardware(VTCompressionSessionRef session,NSString *selected,const char *stage) {
    CFTypeRef identifier=NULL;
    OSStatus status=VTSessionCopyProperty(session,kVTCompressionPropertyKey_EncoderID,kCFAllocatorDefault,&identifier);
    NSString *actual=status==noErr && identifier && CFGetTypeID(identifier)==CFStringGetTypeID()
        ? [(__bridge NSString *)identifier copy] : nil;
    if (identifier) CFRelease(identifier);
    CFArrayRef list=NULL;
    OSStatus listStatus=VTCopyVideoEncoderList(NULL,&list);
    BOOL hardware=NO;
    if ([actual isEqualToString:selected] && listStatus==noErr && list) {
        for (NSDictionary *entry in (__bridge NSArray *)list) {
            id flag=entry[(__bridge id)kVTVideoEncoderList_IsHardwareAccelerated];
            if ([entry[(__bridge id)kVTVideoEncoderList_EncoderID] isEqual:actual] &&
                [entry[(__bridge id)kVTVideoEncoderList_CodecType] unsignedIntValue]==kCMVideoCodecType_JPEG &&
                flag && CFEqual((__bridge CFTypeRef)flag,kCFBooleanTrue)) hardware=YES;
        }
    }
    if (list) CFRelease(list);
    fprintf(stderr,"VTImageEncoder: %s EncoderID=%s registry_hardware=%s property_status=%d\n",
            stage,(actual ?: @"unavailable").UTF8String,hardware?"true":"false",status);
    return hardware;
}

static NSData *failedSession(VTCompressionSessionRef session,NSString *message) {
    diagnostic(message);
    if (session) { VTCompressionSessionInvalidate(session); CFRelease(session); }
    return nil;
}

static NSData *encode(CVPixelBufferRef pixels,double quality) {
    NSString *selected=hardwareJPEGEncoder();
    if (!selected) return nil;
    NSDictionary *spec=@{(__bridge id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES,
                          (__bridge id)kVTVideoEncoderSpecification_EncoderID:selected};
    NSDictionary *source=@{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
    VTCompressionSessionRef session=NULL;
    OSStatus status=VTCompressionSessionCreate(kCFAllocatorDefault,1920,720,kCMVideoCodecType_JPEG,
        (__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)source,NULL,NULL,NULL,&session);
    if (status!=noErr || !session) return failedSession(session,[NSString stringWithFormat:@"Required-hardware session creation failed: %d",status]);
    status=VTSessionSetProperty(session,kVTCompressionPropertyKey_Quality,(__bridge CFNumberRef)@(quality));
    if (status!=noErr) return failedSession(session,[NSString stringWithFormat:@"Quality configuration failed: %d",status]);
    status=VTCompressionSessionPrepareToEncodeFrames(session);
    if (status!=noErr) return failedSession(session,[NSString stringWithFormat:@"Encoder preparation failed: %d",status]);
    if (!verifyHardware(session,selected,"before encode")) return failedSession(session,@"Actual hardware encoder could not be verified");
    __block NSData *jpeg=nil;
    __block OSStatus callbackStatus=noErr;
    __block BOOL dropped=NO;
    __block uint64_t duration=0;
    uint64_t started=microseconds();
    status=VTCompressionSessionEncodeFrameWithOutputHandler(session,pixels,CMTimeMake(0,1),kCMTimeInvalid,NULL,NULL,
        ^(OSStatus result,VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
            duration=microseconds()-started;
            callbackStatus=result; dropped=(flags & kVTEncodeInfo_FrameDropped)!=0;
            if (result!=noErr || dropped || !sample) return;
            CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
            size_t count=block?CMBlockBufferGetDataLength(block):0;
            if (!count || count>16*1024*1024) { callbackStatus=paramErr; return; }
            NSMutableData *output=[NSMutableData dataWithLength:count];
            callbackStatus=CMBlockBufferCopyDataBytes(block,0,count,output.mutableBytes);
            if (callbackStatus==noErr) jpeg=output;
        });
    if (status==noErr) status=VTCompressionSessionCompleteFrames(session,kCMTimeInvalid);
    if (status!=noErr || callbackStatus!=noErr || dropped || !jpeg)
        return failedSession(session,[NSString stringWithFormat:@"JPEG encoding failed: submission=%d callback=%d dropped=%d",status,callbackStatus,dropped]);
    if (!verifyHardware(session,selected,"after encode")) return failedSession(session,@"Post-encode hardware verification failed");
    VTCompressionSessionInvalidate(session); CFRelease(session);
    fprintf(stderr,"VTImageEncoder: quality=%.3f dimensions=1920x720 jpeg_bytes=%zu encode_ms=%.3f\n",
            quality,jpeg.length,duration/1000.0);
    return jpeg;
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc<2 || argc>3) { diagnostic(@"Usage: VTImageEncoder input.png [quality 0..1, default 0.75]"); return 2; }
        double quality=0.75;
        if (argc==3) {
            char *end=NULL;
            quality=strtod(argv[2],&end);
            if (end==argv[2] || *end || !isfinite(quality) || quality<0 || quality>1) {
                diagnostic(@"Quality must be a number from 0 to 1"); return 2;
            }
        }
        CVPixelBufferRef pixels=loadPNG(argv[1]);
        if (!pixels) return 2;
        NSData *jpeg=encode(pixels,quality);
        CVPixelBufferRelease(pixels);
        if (!jpeg) return 2;
        if (fwrite(jpeg.bytes,1,jpeg.length,stdout)!=jpeg.length || fflush(stdout)) {
            diagnostic(@"Cannot write JPEG to stdout"); return 2;
        }
        return 0;
    }
}
