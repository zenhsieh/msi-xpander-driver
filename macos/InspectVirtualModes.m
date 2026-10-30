#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
// Runtime CGS mode description used by ResolutionMenu and other display tools.
typedef struct { uint32_t number,flags,width,height,depth; uint8_t unknown[170]; uint16_t frequency; uint8_t reserved[16]; float density; } ModeDescription;
int main(int argc,const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication]; CGDirectDisplayID target=0; unsigned matches=0;
    for(NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID d=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if([screen.localizedName isEqualToString:@"MSI Xpander Desktop"] && CGDisplayVendorNumber(d)==3504 && CGDisplayModelNumber(d)==31008 && CGDisplaySerialNumber(d)==20261030 && d!=CGMainDisplayID()) { target=d; matches++; }
    }
    if(matches!=1) return 1;
    CGError (*countFn)(CGDirectDisplayID,int*)=dlsym(RTLD_DEFAULT,"CGSGetNumberOfDisplayModes");
    CGError (*descFn)(CGDirectDisplayID,int,void*,int)=dlsym(RTLD_DEFAULT,"CGSGetDisplayModeDescriptionOfLength");
    CGError (*setFn)(CGDisplayConfigRef,CGDirectDisplayID,int)=dlsym(RTLD_DEFAULT,"CGSConfigureDisplayMode");
    if(!countFn || !descFn || !setFn) return 2;
    int count=0; if(countFn(target,&count) || count<1 || count>1000) return 3;
    for(int i=0;i<count;i++) {
        ModeDescription mode={0}; if(descFn(target,i,&mode,sizeof(mode))) continue;
        fprintf(stderr,"index=%d number=%u flags=%x dimensions=%ux%u density=%g\n",i,mode.number,mode.flags,mode.width,mode.height,mode.density);
        if(argc>1 && strcmp(argv[1],"--select-retina")==0 && mode.width==960 && mode.height==360 && mode.density==2.0f) {
            CGDisplayConfigRef config; CGError error=CGBeginDisplayConfiguration(&config);
            if(error) return 4;
            error=setFn(config,target,(int)mode.number);
            if(error) CGCancelDisplayConfiguration(config);
            else error=CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
            fprintf(stderr,"Private mode select: display %u, result=%d\n",target,error); return error?5:0;
        }
    }
    return argc>1?6:0;
} }
