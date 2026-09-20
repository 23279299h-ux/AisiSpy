// AisiDump Tweak.mm - minimal test version
// Just write a file on load, no frameworks
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

static FILE* logFile = NULL;

static void logToFile(const char* fmt, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(logFile, fmt, args);
    va_end(args);
    fprintf(logFile, "\n");
    fflush(logFile);
}

__attribute__((constructor))
static void init(void) {
    // Try every possible path
    logFile = fopen("/tmp/aisidump_test.log", "w");
    if (!logFile) logFile = fopen("/var/mobile/Documents/aisidump_test.log", "w");
    
    logToFile("=== AisiDump v3 MINIMAL LOADED ===");
    logToFile("PID: %d", getpid());
    
    // List all images
    uint32_t count = _dyld_image_count();
    logToFile("Images: %u", count);
    for (uint32_t i = 0; i < count && i < 200; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && (strstr(name, "PxExt") || strstr(name, "eye") || 
                     strstr(name, "Unity") || strstr(name, "rn.notes"))) {
            uint64_t base = (uint64_t)_dyld_get_image_header(i);
            logToFile("  [%u] 0x%llx: %s", i, base, name);
        }
    }
    
    // Also try to dlopen UIKit to get bundle ID
    void* uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    logToFile("UIKit: %p", uikit);
    
    logToFile("=== DONE ===");
}
