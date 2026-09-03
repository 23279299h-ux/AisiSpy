// AisiMonitor Tweak — 无依赖版本，不链接CydiaSubstrate
// 功能：反调试绕过 + PxExtFFiMgr Hook + ESP绘制Hook + 日志输出
// ObjC方法用method_setImplementation，C函数用动态加载MSHookFunction

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <pthread.h>
#import <errno.h>
#import <string.h>

// ========== 动态加载CydiaSubstrate/ElleKit ==========
typedef void (*MSHookMessageEx_t)(Class, SEL, IMP, IMP*);
typedef void (*MSHookFunction_t)(void*, void*, void**);

static MSHookMessageEx_t g_MSHookMessageEx = NULL;
static MSHookFunction_t g_MSHookFunction = NULL;
static BOOL g_hasSubstrate = NO;

static void initSubstrate() {
    void *handle = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
    if (!handle) handle = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!handle) handle = dlopen("/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
    if (!handle) handle = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
    // ElleKit
    if (!handle) handle = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!handle) handle = dlopen("/var/jb/usr/lib/ellekit.dylib", RTLD_NOW);

    if (handle) {
        g_MSHookMessageEx = (MSHookMessageEx_t)dlsym(handle, "MSHookMessageEx");
        g_MSHookFunction = (MSHookFunction_t)dlsym(handle, "MSHookFunction");
        g_hasSubstrate = (g_MSHookMessageEx != NULL && g_MSHookFunction != NULL);
    }
}

// ObjC方法Hook包装
static void hookObjCMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (g_hasSubstrate && g_MSHookMessageEx) {
        g_MSHookMessageEx(cls, sel, newImp, origImp);
    } else {
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) m = class_getClassMethod(cls, sel);
        if (m) {
            *origImp = method_getImplementation(m);
            method_setImplementation(m, newImp);
        }
    }
}

// C函数Hook包装
static void hookCFunction(void *target, void *replace, void **orig) {
    if (g_hasSubstrate && g_MSHookFunction) {
        g_MSHookFunction(target, replace, orig);
    }
}

// ========== 日志系统 ==========
static FILE *g_logFile = NULL;
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

#define LOG(fmt, ...) do { \
    pthread_mutex_lock(&g_logMutex); \
    NSDate *now = [NSDate date]; \
    NSDateFormatter *_df = [[NSDateFormatter alloc] init]; \
    [_df setDateFormat:@"HH:mm:ss.SSS"]; \
    NSString *_msg = [NSString stringWithFormat:@"" fmt, ##__VA_ARGS__]; \
    NSString *_logLine = [NSString stringWithFormat:@"[%@] %@", [_df stringFromDate:now], _msg]; \
    NSLog(@"[AisiMonitor] %@", _msg); \
    if (g_logFile) { \
        fprintf(g_logFile, "%s\n", [_logLine UTF8String]); \
        fflush(g_logFile); \
    } \
    pthread_mutex_unlock(&g_logMutex); \
} while(0)

static void initLog() {
    NSArray *paths = @[@"/tmp/aisi_monitor.log", @"/var/mobile/Documents/aisi_monitor.log"];
    for (NSString *logPath in paths) {
        g_logFile = fopen([logPath UTF8String], "a");
        if (g_logFile) {
            NSLog(@"[AisiMonitor] 日志文件: %@", logPath);
            fprintf(g_logFile, "\n========== AisiMonitor 启动 ==========\n");
            fprintf(g_logFile, "PID: %d, 时间: %s\n", getpid(), [[[NSDate date] description] UTF8String]);
            fflush(g_logFile);
            break;
        } else {
            NSLog(@"[AisiMonitor] 无法打开日志: %s (%s)", [logPath UTF8String], strerror(errno));
        }
    }
}

// ========== 反调试绕过 ==========

static int (*orig_ptrace)(int request, pid_t pid, caddr_t addr, int data);
static int my_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) {
        LOG("[反调试] ptrace(PT_DENY_ATTACH) 已拦截");
        return 0;
    }
    return orig_ptrace(request, pid, addr, data);
}

static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (namelen >= 3 && name[0] == 1 && name[1] == 14 && name[2] == 1 && oldp && oldlenp) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        size_t count = *oldlenp / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            if (kp[i].kp_proc.p_pid == getpid() && (kp[i].kp_proc.p_flag & P_TRACED)) {
                kp[i].kp_proc.p_flag &= ~P_TRACED;
                LOG("[反调试] sysctl: 已清除P_TRACED标志");
            }
        }
    }
    return ret;
}

static int (*orig_dladdr)(const void *addr, Dl_info *info);
static int my_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (ret != 0 && info && info->dli_fname) {
        NSString *fname = [NSString stringWithUTF8String:info->dli_fname];
        if ([fname rangeOfString:@"frida" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fname rangeOfString:@"gadget" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fname rangeOfString:@"AisiMonitor"].location != NSNotFound) {
            LOG("[反调试] dladdr隐藏: %@", fname);
            return 0;
        }
    }
    return ret;
}

static char *(*orig_strstr)(const char *haystack, const char *needle);
static char *my_strstr(const char *haystack, const char *needle) {
    if (needle && (strcasestr(needle, "frida") || strcasestr(needle, "gadget") || strcasestr(needle, "AisiMonitor"))) {
        LOG("[反调试] strstr隐藏: %s", needle);
        return NULL;
    }
    return orig_strstr(haystack, needle);
}

// ========== dlopen/dlsym Hook ==========

static void *(*orig_dlopen)(const char *path, int mode);
static void *my_dlopen(const char *path, int mode) {
    void *handle = orig_dlopen(path, mode);
    if (path) {
        LOG("[dlopen] 加载: %s -> %p", path, handle);
    }
    return handle;
}

static void *(*orig_dlsym)(void *handle, const char *symbol);
static void *my_dlsym(void *handle, const char *symbol) {
    void *addr = orig_dlsym(handle, symbol);
    if (symbol && (strstr(symbol, "PxExt") || strstr(symbol, "LoadDyLib") || strstr(symbol, "FunCall") || strstr(symbol, "OpenHandle"))) {
        LOG("[dlsym] 查找: %s -> %p", symbol, addr);
    }
    return addr;
}

// ========== ESP绘制Hook ==========

static void (*orig_addLineToPoint)(UIBezierPath *self, SEL sel, CGPoint point);
static void my_addLineToPoint(UIBezierPath *self, SEL sel, CGPoint point) {
    LOG("[ESP绘制] addLineToPoint: (%.1f, %.1f)", point.x, point.y);
    orig_addLineToPoint(self, sel, point);
}

static void (*orig_addArcWithCenter)(UIBezierPath *self, SEL sel, CGPoint center, CGFloat radius, CGFloat startAngle, CGFloat endAngle, BOOL clockwise);
static void my_addArcWithCenter(UIBezierPath *self, SEL sel, CGPoint center, CGFloat radius, CGFloat startAngle, CGFloat endAngle, BOOL clockwise) {
    LOG("[ESP绘制] addArcWithCenter: (%.1f,%.1f) r=%.1f", center.x, center.y, radius);
    orig_addArcWithCenter(self, sel, center, radius, startAngle, endAngle, clockwise);
}

static UIColor *(*orig_colorWithRed)(Class self, SEL sel, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha);
static UIColor *my_colorWithRed(Class self, SEL sel, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    LOG("[ESP绘制] colorWithRed: %.2f %.2f %.2f %.2f", red, green, blue, alpha);
    return orig_colorWithRed(self, sel, red, green, blue, alpha);
}

static void (*orig_setText)(UILabel *self, SEL sel, NSString *text);
static void my_setText(UILabel *self, SEL sel, NSString *text) {
    if (text && ([text rangeOfString:@"m"].location != NSNotFound || [text rangeOfString:@"米"].location != NSNotFound || text.length < 10)) {
        LOG("[ESP绘制] UILabel setText: %@", text);
    }
    orig_setText(self, sel, text);
}

static void (*orig_setPath)(CAShapeLayer *self, SEL sel, CGPathRef path);
static void my_setPath(CAShapeLayer *self, SEL sel, CGPathRef path) {
    if (path) {
        LOG("[ESP绘制] CAShapeLayer setPath");
    }
    orig_setPath(self, sel, path);
}

// ========== PxExtFFiMgr Hook ==========

static void hookPxExtFFiMgr() {
    Class pxExtClass = objc_getClass("PxExtFFi_fw_class");
    if (pxExtClass) {
        LOG("[PxExtFFi] 找到类: PxExtFFi_fw_class");

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(pxExtClass, &methodCount);
        LOG("[PxExtFFi] 方法数量: %d", methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            const char *name = sel_getName(sel);
            LOG("[PxExtFFi] 方法: %s", name);
        }
        free(methods);
    } else {
        LOG("[PxExtFFi] 未找到PxExtFFi_fw_class类");
    }

    // 列出所有已加载的模块
    LOG("========== 已加载模块 ==========");
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "PxExt") || strstr(name, "eye") || strstr(name, "notes") || strstr(name, "tmp"))) {
            LOG("  模块: %s @ 0x%llx", name, (unsigned long long)_dyld_get_image_vmaddr_slide(i));
        }
    }
}

// ========== Hook所有ObjC方法 ==========

static void hookObjcMethods() {
    hookObjCMethod([UIBezierPath class], @selector(addLineToPoint:), (IMP)my_addLineToPoint, (IMP *)&orig_addLineToPoint);
    hookObjCMethod([UIBezierPath class], @selector(addArcWithCenter:radius:startAngle:endAngle:clockwise:), (IMP)my_addArcWithCenter, (IMP *)&orig_addArcWithCenter);
    hookObjCMethod(objc_getClass("UIColor"), @selector(colorWithRed:green:blue:alpha:), (IMP)my_colorWithRed, (IMP *)&orig_colorWithRed);
    hookObjCMethod([UILabel class], @selector(setText:), (IMP)my_setText, (IMP *)&orig_setText);
    hookObjCMethod([CAShapeLayer class], @selector(setPath:), (IMP)my_setPath, (IMP *)&orig_setPath);
    LOG("[+] ObjC绘制方法Hook完成");
}

// ========== 构造函数（最早执行）==========
__attribute__((constructor))
static void AisiMonitorConstructor() {
    // 最简单的测试：直接写文件，不依赖任何东西
    FILE *testFile = fopen("/tmp/aisi_monitor_loaded.txt", "w");
    if (testFile) {
        fprintf(testFile, "AisiMonitor constructor executed! PID: %d\n", getpid());
        fclose(testFile);
    }

    @autoreleasepool {
        initLog();
        LOG("========== AisiMonitor构造函数执行 ==========");
        LOG("PID: %d, 进程: %@", getpid(), [[NSProcessInfo processInfo] processName]);

        // 初始化注入框架
        initSubstrate();
        LOG("[+] 注入框架: %@", g_hasSubstrate ? @"CydiaSubstrate/ElleKit 已加载" : @"未找到，仅用method_setImplementation");

        // 1. Hook系统反调试函数
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "ptrace"), (void *)my_ptrace, (void **)&orig_ptrace);
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "sysctl"), (void *)my_sysctl, (void **)&orig_sysctl);
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "dladdr"), (void *)my_dladdr, (void **)&orig_dladdr);
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "strstr"), (void *)my_strstr, (void **)&orig_strstr);
        LOG("[+] 系统反调试函数Hook完成");

        // 2. Hook dlopen/dlsym
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "dlopen"), (void *)my_dlopen, (void **)&orig_dlopen);
        hookCFunction((void *)dlsym(RTLD_DEFAULT, "dlsym"), (void *)my_dlsym, (void **)&orig_dlsym);

        // 3. Hook ObjC绘制方法
        hookObjcMethods();

        // 4. 延迟Hook PxExtFFiMgr
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                hookPxExtFFiMgr();
                LOG("[+] PxExtFFiMgr Hook完成");
            }
        });

        LOG("[+] AisiMonitor初始化完成，反调试已绕过");
    }
}
