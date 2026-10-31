// Standalone hardware-JPEG gate. It does not capture screens or open USB.
// Build/run instructions and measured results live in docs/evidence.
#import <AppKit/AppKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>

typedef struct {
    dispatch_semaphore_t ready;
    OSStatus status;
    CFAbsoluteTime started;
    double elapsedMs;
    size_t bytes;
    CFDataRef jpeg;
} FrameResult;

static void encoded(void *context, void *source, OSStatus status,
                    VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)context;
    FrameResult *result = source;
    result->status = status;
    result->elapsedMs = (CFAbsoluteTimeGetCurrent() - result->started) * 1000;
    if (status == noErr && sample && !(flags & kVTEncodeInfo_FrameDropped)) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t count = block ? CMBlockBufferGetDataLength(block) : 0;
        if (count) {
            NSMutableData *data = [NSMutableData dataWithLength:count];
            result->status = CMBlockBufferCopyDataBytes(block, 0, count, data.mutableBytes);
            if (result->status == noErr) {
                result->bytes = count;
                result->jpeg = CFDataCreateCopy(kCFAllocatorDefault, (__bridge CFDataRef)data);
            }
        }
    }
    dispatch_semaphore_signal(result->ready);
}

static CVPixelBufferRef gradient(void) {
    CVPixelBufferRef pixel = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                                  (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 1920, 720,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixel);
    if (status != kCVReturnSuccess) {
        printf("CVPixelBufferCreate status=%d\n", status);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pixel, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixel);
    size_t stride = CVPixelBufferGetBytesPerRow(pixel);
    for (size_t y = 0; y < 720; y++) {
        for (size_t x = 0; x < 1920; x++) {
            uint8_t *p = base + y * stride + x * 4;
            p[0] = (uint8_t)(255 * x / 1919);
            p[1] = (uint8_t)(255 * y / 719);
            p[2] = (uint8_t)(255 * (x + y) / (1919 + 719));
            p[3] = 255;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(base, 1920, 720, 8, stride, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (cg) {
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:NO];
        [@"1920 x 720 / VideoToolbox hardware JPEG probe" drawAtPoint:NSMakePoint(60, 350)
            withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:42 weight:NSFontWeightBold],
                             NSForegroundColorAttributeName:NSColor.whiteColor}];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(cg);
    }
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    return pixel;
}

static int probe(CVPixelBufferRef pixel, double quality, BOOL save) {
    VTCompressionSessionRef session = NULL;
    NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES};
    NSDictionary *source = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, 1920, 720,
        kCMVideoCodecType_JPEG, (__bridge CFDictionaryRef)spec,
        (__bridge CFDictionaryRef)source, NULL, encoded, NULL, &session);
    printf("quality=%.2f codec=jpeg dimensions=1920x720 input=32BGRA require_hardware=true\n", quality);
    printf("VTCompressionSessionCreate status=%d%s\n", status,
           status == kVTCouldNotFindVideoEncoderErr ? " (kVTCouldNotFindVideoEncoderErr)" : "");
    if (status != noErr || !session) {
        printf("RESULT: STOP; required hardware JPEG session unavailable; no output produced\n");
        if (session) { VTCompressionSessionInvalidate(session); CFRelease(session); }
        return 2;
    }
    int result = 2;
    CFTypeRef property = NULL;
    status = VTSessionSetProperty(session, kVTCompressionPropertyKey_Quality,
                                 (__bridge CFNumberRef)@(quality));
    printf("Set quality status=%d\n", status);
    if (status != noErr) goto done;
    status = VTCompressionSessionPrepareToEncodeFrames(session);
    printf("Prepare frames status=%d\n", status);
    if (status != noErr) goto done;
    status = VTSessionCopyProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  kCFAllocatorDefault, &property);
    BOOL hardware = status == noErr && property && CFEqual(property, kCFBooleanTrue);
    const char *hardwareValue = status != noErr || !property ? "unavailable" : hardware ? "true" : "false";
    printf("UsingHardwareAcceleratedVideoEncoder=%s property_status=%d\n", hardwareValue, status);
    if (property) { CFRelease(property); property = NULL; }
    if (status == noErr && !hardware) {
        printf("RESULT: STOP; hardware flag is not true\n");
        goto done;
    }
    if (!hardware) {
        // Retain RequireHardware=true. Collect format/performance evidence, but
        // do not claim that session creation proves hardware use when this
        // runtime cannot attest the hardware property.
        printf("Hardware attestation unavailable; collecting JPEG evidence with the unchanged required-hardware session\n");
    }
    double totalMs = 0;
    size_t totalBytes = 0, minimum = SIZE_MAX, maximum = 0;
    for (int i = 0; i < 100; i++) {
        FrameResult frame = {0};
        frame.ready = dispatch_semaphore_create(0);
        frame.started = CFAbsoluteTimeGetCurrent();
        status = VTCompressionSessionEncodeFrame(session, pixel, CMTimeMake(i, 30),
            CMTimeMake(1, 30), NULL, &frame, NULL);
        if (status == noErr) status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        if (status != noErr) {
            printf("Frame %d encode/complete status=%d\n", i, status);
            if (frame.jpeg) CFRelease(frame.jpeg);
            goto done;
        }
        // CompleteFrames has drained submitted callbacks before this wait.
        if (dispatch_semaphore_wait(frame.ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) ||
            frame.status != noErr || !frame.jpeg) {
            printf("Frame %d failed: callback_status=%d JPEG bytes=%zu\n", i, frame.status, frame.bytes);
            if (frame.jpeg) CFRelease(frame.jpeg);
            goto done;
        }
        totalMs += frame.elapsedMs;
        totalBytes += frame.bytes;
        minimum = MIN(minimum, frame.bytes); maximum = MAX(maximum, frame.bytes);
        if (i == 0 && save) {
            NSError *error = nil;
            if (![(__bridge NSData *)frame.jpeg writeToFile:@"/tmp/vt-probe.jpg" options:NSDataWritingAtomic error:&error]) {
                printf("Write probe JPEG failed: %s\n", error.localizedDescription.UTF8String);
                CFRelease(frame.jpeg); goto done;
            }
            printf("Saved /tmp/vt-probe.jpg at quality=%.2f\n", quality);
        }
        CFRelease(frame.jpeg);
    }
    printf("frames=100 mean_encode_ms=%.3f mean_bytes=%.1f min_bytes=%zu max_bytes=%zu quality=%.2f\n",
           totalMs/100, totalBytes/100.0, minimum, maximum, quality);
    result = hardware ? 0 : 3;
done:
    if (property) CFRelease(property);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    return result;
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        const char *setting = getenv("MSI_VT_QUALITY");
        double selected = 0.75;
        if (setting) {
            char *end = NULL;
            selected = strtod(setting, &end);
            if (end == setting || *end || !isfinite(selected) || selected < 0 || selected > 1) {
                fprintf(stderr, "MSI_VT_QUALITY must be a number from 0 to 1\n"); return 2;
            }
        }
        printf("VT hardware JPEG spike: default/selected quality=%.2f; 100 frames per quality\n", selected);
        CVPixelBufferRef pixel = gradient();
        if (!pixel) return 2;
        double qualities[] = {selected, 0.6, 0.75, 0.9};
        int result = 0;
        BOOL unverifiedHardware = NO;
        for (int i = 0; i < 4; i++) {
            BOOL duplicate = NO;
            for (int j = 0; j < i; j++) if (qualities[j] == qualities[i]) duplicate = YES;
            if (duplicate) continue;
            result = probe(pixel, qualities[i], i == 0);
            if (result == 3) { unverifiedHardware = YES; result = 0; }
            if (result) break;
        }
        CVPixelBufferRelease(pixel);
        if (!result && unverifiedHardware) {
            printf("RESULT: STOP integration; JPEG benchmarks complete but hardware flag remains unverified\n");
            return 2;
        }
        return result;
    }
}
