// AisiDump Tweak.mm
// Standalone RootHide/ElleKit tweak - no Theos/substrate dependency
// Logs ESP drawing calls and memory reads to /tmp/esp_dump.log

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_init.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <stdio.h>

// Declare mach_vm_read_overwrite ourselves (mach_vm.h is not available in SDK)
extern "C" kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t* outsize);

static FILE* logFile = NULL;
static uint64_t unityBase = 0;

static void logToFile(NSString* fmt, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(logFile, [fmt UTF8String], args);
    va_end(args);
    fprintf(logFile, "\n");
    fflush(logFile);
}

static uint64_t findUnityBase(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            return (uint64_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// Swizzle CALayer setPath:
static void (*orig_CAShapeLayer_setPath)(id, SEL, CGPathRef);
static void hook_CAShapeLayer_setPath(id self, SEL _cmd, CGPathRef path) {
    logToFile(@"[DRAW] CAShapeLayer.setPath called");
    orig_CAShapeLayer_setPath(self, _cmd, path);
}

// Swizzle UILabel setText:
static void (*orig_UILabel_setText)(id, SEL, NSString*);
static void hook_UILabel_setText(id self, SEL _cmd, NSString* text) {
    logToFile(@"[DRAW] UILabel.setText: %@", text);
    orig_UILabel_setText(self, _cmd, text);
}

// Swizzle UILabel setTextColor:
static void (*orig_UILabel_setTextColor)(id, SEL, UIColor*);
static void hook_UILabel_setTextColor(id self, SEL _cmd, UIColor* color) {
    logToFile(@"[DRAW] UILabel.setTextColor called");
    orig_UILabel_setTextColor(self, _cmd, color);
}

// Swizzle UIView setFrame:
static void (*orig_UIView_setFrame)(id, SEL, CGRect);
static void hook_UIView_setFrame(id self, SEL _cmd, CGRect frame) {
    if (frame.origin.y < 200 || frame.size.width < 100) {
        logToFile(@"[DRAW] UIView.setFrame: (%.0f,%.0f,%.0f,%.0f)",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    orig_UIView_setFrame(self, _cmd, frame);
}

// Swizzle UIColor colorWithRed:green:blue:alpha:
static id (*orig_colorWithRed)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
static id hook_colorWithRed(id self, SEL _cmd, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    logToFile(@"[DRAW] UIColor.colorWithRed: %.2f %.2f %.2f %.2f", r, g, b, a);
    return orig_colorWithRed(self, _cmd, r, g, b, a);
}

static void swizzleMethod(Class cls, SEL sel, IMP newImp, void** origImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *origImp = (void*)method_getImplementation(m);
        method_setImplementation(m, newImp);
        logToFile(@"[SWIZZLE] %s.%s OK", class_getName(cls), sel_getName(sel));
    } else {
        logToFile(@"[SWIZZLE] %s.%s NOT FOUND", class_getName(cls), sel_getName(sel));
    }
}

__attribute__((constructor))
static void init(void) {
    logFile = fopen("/tmp/esp_dump.log", "w");
    if (!logFile) logFile = fopen("/var/mobile/Documents/esp_dump.log", "w");
    
    logToFile(@"=== AisiDump Tweak v1.0 Loaded ===");
    logToFile(@"[INIT] PID: %d", getpid());
    logToFile(@"[INIT] Bundle: %s", 
        [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");
    
    unityBase = findUnityBase();
    logToFile(@"[INIT] UnityFramework base: 0x%llx", unityBase);
    if (unityBase) {
        logToFile(@"[INIT] Entity chain: +0x1296D238 -> +0xB8 -> +0x2A4");
        logToFile(@"[INIT] Expected entity list addr: 0x%llx", unityBase + 0x1296D238);
    }
    
    // Log all loaded images
    logToFile(@"[INIT] Loaded images:");
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && (strstr(name, "PxExt") || strstr(name, "eye") || 
                     strstr(name, "Unity") || strstr(name, "Framework"))) {
            uint64_t base = (uint64_t)_dyld_get_image_header(i);
            logToFile(@"  [%u] 0x%llx: %s", i, base, name);
        }
    }
    
    // Swizzle drawing methods
    @autoreleasepool {
        swizzleMethod(objc_getClass("CAShapeLayer"), 
            @selector(setPath:), (IMP)hook_CAShapeLayer_setPath, 
            (void**)&orig_CAShapeLayer_setPath);
        
        swizzleMethod(objc_getClass("UILabel"), 
            @selector(setText:), (IMP)hook_UILabel_setText, 
            (void**)&orig_UILabel_setText);
        
        swizzleMethod(objc_getClass("UILabel"), 
            @selector(setTextColor:), (IMP)hook_UILabel_setTextColor, 
            (void**)&orig_UILabel_setTextColor);
        
        swizzleMethod(objc_getClass("UIView"), 
            @selector(setFrame:), (IMP)hook_UIView_setFrame, 
            (void**)&orig_UIView_setFrame);
        
        swizzleMethod(objc_getClass("UIColor"), 
            @selector(colorWithRed:green:blue:alpha:), (IMP)hook_colorWithRed, 
            (void**)&orig_colorWithRed);
    }
    
    // Dump entity list pointer if UnityFramework is loaded
    if (unityBase) {
        uint64_t entityChainAddr = unityBase + 0x1296D238;
        uint64_t val = 0;
        mach_vm_size_t out;
        kern_return_t kr = mach_vm_read_overwrite(
            mach_task_self(), entityChainAddr, 8, (mach_vm_address_t)&val, &out);
        logToFile(@"[DUMP] Read entity chain @0x%llx: kr=%d val=0x%llx", 
            entityChainAddr, kr, val);
        
        if (val) {
            uint64_t mgrAddr = val + 0xB8;
            uint64_t mgr = 0;
            mach_vm_read_overwrite(mach_task_self(), mgrAddr, 8, (mach_vm_address_t)&mgr, &out);
            logToFile(@"[DUMP] Read mgr @0x%llx: val=0x%llx", mgrAddr, mgr);
            
            if (mgr) {
                uint64_t listAddr = mgr + 0x2A4;
                uint64_t list = 0;
                mach_vm_read_overwrite(mach_task_self(), listAddr, 8, (mach_vm_address_t)&list, &out);
                logToFile(@"[DUMP] Read entity_list @0x%llx: val=0x%llx", listAddr, list);
            }
        }
    }
    
    logToFile(@"[INIT] Ready. Use ESP now, then check /tmp/esp_dump.log");
}
