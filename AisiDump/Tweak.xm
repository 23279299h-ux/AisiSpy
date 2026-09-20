// AisiDump Tweak.xm
// Hook vm_read_overwrite to dump all game memory reads
// Target: rn.notes.best (爱思助手)
// RootHide/ElleKit rootless

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <substrate.h>

static FILE* logFile = NULL;
static mach_port_t ourTask = 0;
static uint64_t unityBase = 0;
static int dumpCount = 0;

static void logToFile(NSString* fmt, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(logFile, [fmt UTF8String], args);
    va_end(args);
    fprintf(logFile, "\n");
    fflush(logFile);
}

// Get UnityFramework base address
static uint64_t findUnityBase(void) {
    Dl_info info;
    void* handle = dlopen("/private/var/containers/Bundle/Application/"
                          "*/王者荣耀.app/Frameworks/UnityFramework", RTLD_LAZY);
    if (handle) { dlclose(handle); }
    
    // Iterate loaded images
    uint32_t count = 0;
    dyld_image_count();
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* name = _dyld_get_image_name(i);
        if (strstr(name, "UnityFramework")) {
            return (uint64_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// Hook mach_vm_read_overwrite
// This is the syscall eye.framework uses to read game memory
static kern_return_t (*orig_mach_vm_read_overwrite)(
    vm_map_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_address_t data,
    vm_size_t* outsize);

static kern_return_t hook_mach_vm_read_overwrite(
    vm_map_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_address_t data,
    vm_size_t* outsize) {
    
    kern_return_t kr = orig_mach_vm_read_overwrite(
        target_task, address, size, data, outsize);
    
    if (kr == KERN_SUCCESS && unityBase) {
        // Only log reads from UnityFramework address range
        uint64_t offset = address - unityBase;
        if (offset > 0x100000 && offset < 0x20000000 && dumpCount < 50000) {
            dumpCount++;
            // Read the value
            uint64_t val = 0;
            if (size == 8) {
                val = *(uint64_t*)data;
            } else if (size == 4) {
                val = *(uint32_t*)data;
            } else if (size == 2) {
                val = *(uint16_t*)data;
            }
            
            // Log interesting offsets (entity range)
            if ((offset >= 0x12960000 && offset <= 0x129B0000) ||  // entity list region
                (offset >= 0x200 && offset <= 0x600) ||  // entity struct offsets
                dumpCount % 100 == 0) {
                logToFile(@"[DUMP] read addr=0x%llx offset=0x%llx size=%lu val=0x%llx",
                    (uint64_t)address, offset, (unsigned long)size, val);
            }
        }
    }
    return kr;
}

// Hook dlopen to catch eye.framework loading
static void* (*orig_dlopen)(const char* path, int mode);
static void* hook_dlopen(const char* path, int mode) {
    void* handle = orig_dlopen(path, mode);
    if (path && strstr(path, "PxExtFFi")) {
        logToFile(@"[HOOK] dlopen: %s -> %p", path, handle);
        // Find UnityFramework base now that app is running
        unityBase = findUnityBase();
        logToFile(@"[HOOK] UnityFramework base: 0x%llx", unityBase);
        logToFile(@"[HOOK] Entity chain offsets: +0x1296D238, +0xB8, +0x2A4");
        logToFile(@"[HOOK] Expected entity list addr: 0x%llx", 
            unityBase ? unityBase + 0x1296D238 : 0);
    }
    if (path && strstr(path, "eye")) {
        logToFile(@"[HOOK] dlopen: %s -> %p", path, handle);
    }
    return handle;
}

// Hook objc_msgSend to catch drawing calls
static id (*orig_objc_msgSend)(id self, SEL _cmd, ...);
static id hook_objc_msgSend(id self, SEL _cmd, ...) {
    const char* selName = sel_getName(_cmd);
    
    // Log ESP drawing calls
    if (strstr(selName, "moveToPoint") || 
        strstr(selName, "addLineToPoint") ||
        strstr(selName, "closePath") ||
        strstr(selName, "setPath") ||
        strstr(selName, "setText") ||
        strstr(selName, "setTextColor") ||
        strstr(selName, "setFrame") ||
        strstr(selName, "colorWithRed")) {
        
        logToFile(@"[DRAW] objc_msgSend: [%s %s]", 
            class_getName([self class]), selName);
    }
    
    return orig_objc_msgSend(self, _cmd);
}

__attribute__((constructor))
static void init(void) {
    // Open log file
    logFile = fopen("/tmp/esp_dump.log", "w");
    if (!logFile) {
        logFile = fopen("/var/mobile/Documents/esp_dump.log", "w");
    }
    
    logToFile(@"=== AisiDump Tweak Loaded ===");
    logToFile(@"[INIT] PID: %d", getpid());
    logToFile(@"[INIT] Bundle: %s", 
        [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown");
    
    // Find UnityFramework
    unityBase = findUnityBase();
    logToFile(@"[INIT] UnityFramework base: 0x%llx", unityBase);
    
    // Hook dlopen
    MSHookFunction((void*)dlopen, (void*)hook_dlopen, (void**)&orig_dlopen);
    logToFile(@"[INIT] Hooked dlopen");
    
    // Hook mach_vm_read_overwrite
    // It's in libsystem_kernel.dylib
    void* sym = dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
    if (sym) {
        MSHookFunction(sym, (void*)hook_mach_vm_read_overwrite, 
                      (void**)&orig_mach_vm_read_overwrite);
        logToFile(@"[INIT] Hooked mach_vm_read_overwrite at %p", sym);
    } else {
        logToFile(@"[INIT] ERROR: mach_vm_read_overwrite not found");
    }
    
    // Hook objc_msgSend
    MSHookFunction((void*)objc_msgSend, (void*)hook_objc_msgSend, 
                  (void**)&orig_objc_msgSend);
    logToFile(@"[INIT] Hooked objc_msgSend");
    
    logToFile(@"[INIT] Ready. Wait for ESP activation...");
}
