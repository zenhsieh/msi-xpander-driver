// Inspect public encoder identities and selection behavior without screen/USB access.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

static id key(CFStringRef value) { return (__bridge id)value; }

static void inspect(NSString *label, CMVideoCodecType codec, NSDictionary *spec) {
    printf("\nCASE %s\n", label.UTF8String);
    CFStringRef encoder = NULL;
    CFDictionaryRef properties = NULL;
    OSStatus status = VTCopySupportedPropertyDictionaryForEncoder(1920, 720, codec,
        (__bridge CFDictionaryRef)spec, &encoder, &properties);
    NSDictionary *supported = (__bridge NSDictionary *)properties;
    printf("selection_status=%d selected_encoder=%s supports_hardware_query=%s\n",
        status, encoder ? [(__bridge NSString *)encoder UTF8String] : "unavailable",
        supported[key(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)] ? "yes" : "no");
    if (encoder) CFRelease(encoder);
    if (properties) CFRelease(properties);

    VTCompressionSessionRef session = NULL;
    status = VTCompressionSessionCreate(kCFAllocatorDefault, 1920, 720, codec,
        (__bridge CFDictionaryRef)spec, NULL, NULL, NULL, NULL, &session);
    printf("session_create_status=%d\n", status);
    if (status || !session) return;
    printf("prepare_status=%d\n", VTCompressionSessionPrepareToEncodeFrames(session));
    CFStringRef names[] = {kVTCompressionPropertyKey_EncoderID,
                           kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder};
    for (int i = 0; i < 2; i++) {
        CFTypeRef value = NULL;
        status = VTSessionCopyProperty(session, names[i], kCFAllocatorDefault, &value);
        NSString *description = value ? [(__bridge id)value description] : @"unavailable";
        printf("%s status=%d value=%s\n", [(__bridge NSString *)names[i] UTF8String],
            status, description.UTF8String);
        if (value) CFRelease(value);
    }
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        CFArrayRef list = NULL;
        OSStatus status = VTCopyVideoEncoderList(NULL, &list);
        printf("VTCopyVideoEncoderList status=%d\n", status);
        if (status || !list) return 1;
        NSMutableArray *jpegEncoders = [NSMutableArray array];
        for (NSDictionary *entry in (__bridge NSArray *)list) {
            if ([entry[key(kVTVideoEncoderList_CodecType)] unsignedIntValue] != kCMVideoCodecType_JPEG) continue;
            [jpegEncoders addObject:entry];
            printf("JPEG encoder=%s name=%s hardware=%s\n",
                [entry[key(kVTVideoEncoderList_EncoderID)] UTF8String],
                [entry[key(kVTVideoEncoderList_EncoderName)] UTF8String],
                entry[key(kVTVideoEncoderList_IsHardwareAccelerated)] ?
                    [[entry[key(kVTVideoEncoderList_IsHardwareAccelerated)] description] UTF8String] : "not-listed");
        }
        inspect(@"JPEG default", kCMVideoCodecType_JPEG, @{});
        inspect(@"JPEG require hardware", kCMVideoCodecType_JPEG,
            @{key(kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder):@YES});
        inspect(@"JPEG disable hardware", kCMVideoCodecType_JPEG,
            @{key(kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder):@NO});
        for (NSDictionary *entry in jpegEncoders) {
            NSString *identifier = entry[key(kVTVideoEncoderList_EncoderID)];
            inspect([@"JPEG explicit ID " stringByAppendingString:identifier], kCMVideoCodecType_JPEG,
                @{key(kVTVideoEncoderSpecification_EncoderID):identifier,
                  key(kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder):@YES});
        }
        inspect(@"H264 require hardware (query control)", kCMVideoCodecType_H264,
            @{key(kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder):@YES});
        CFRelease(list);
    }
    return 0;
}
