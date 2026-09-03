// AisiMonitor Tweak — 注入到爱思助手(rn.notes.best)
// 功能：反调试绕过 + PxExtFFiMgr Hook + ESP绘制Hook + 日志输出
// 编译：theos make package

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <pthread.h>

// ========== 日志系统 ==========
static FILE *g_logFile = NULL;
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

#define LOG(fmt, ...) do { \
    pthread_mutex_lock(&g_logMutex); \
    if (g_logFile) { \
        NSDate *now = [NSDate date]; \
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init]; \
        [fmt setDateFormat:@"HH:mm:ss.SSS"]; \
        fprintf(g_logFile, "[%s] " fmt "\n", [[fmt stringFromDate:now] UTF8String], ##__VA_ARGS__); \
        fflush(g_logFile); \
        [fmt release]; \
    } \
    pthread_mutex_unlock(&g_logMutex); \
} while(0)

static void initLog() {
    NSString *logPath = @"/var/mobile/Documents/aisi_monitor.log";
    g_logFile = fopen([logPath UTF8String], "a");
    if (g_logFile) {
        fprintf(g_logFile, "\n========== AisiMonitor 启动 ==========\n");
        fprintf(g_logFile, "PID: %d, 时间: %s\n", getpid(), [[[NSDate date] description] UTF8String]);
        fflush(g_logFile);
    }
}

// ========== 反调试绕过 ==========

// 1. ptrace Hook (PT_DENY_ATTACH = 31)
static int (*orig_ptrace)(int request, pid_t pid, caddr_t addr, int data);
static int my_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) { // PT_DENY_ATTACH
        LOG("[反调试] ptrace(PT_DENY_ATTACH) 已拦截");
        return 0;
    }
    LOG("[反调试] ptrace(request=%d) 已放行", request);
    return orig_ptrace(request, pid, addr, data);
}

// 2. sysctl Hook (清除P_TRACED标志)
static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    // 检测是否是 KERN_PROC (1, 14, 1) 查询
    if (namelen >= 3 && name[0] == 1 && name[1] == 14 && name[2] == 1 && oldp && oldlenp) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        size_t count = *oldlenp / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            if (kp[i].kp_proc.p_pid == getpid()) {
                if (kp[i].kp_proc.p_flag & P_TRACED) {
                    kp[i].kp_proc.p_flag &= ~P_TRACED;
                    LOG("[反调试] sysctl: 已清除P_TRACED标志");
                }
            }
        }
    }
    return ret;
}

// 3. task_get_exception_ports Hook
static kern_return_t (*orig_task_get_exception_ports)(task_t, exception_mask_t, exception_mask_array_t, mach_msg_type_number_t, exception_port_array_t, exception_behavior_array_t, thread_state_flavor_array_t);
static kern_return_t my_task_get_exception_ports(task_t task, exception_mask_t masks, exception_mask_array_t masks_out, mach_msg_type_number_t *masksCnt, exception_port_array_t ports, exception_behavior_array_t behaviors, thread_state_flavor_array_t flavors) {
    kern_return_t ret = orig_task_get_exception_ports(task, masks, masks_out, masksCnt, ports, behaviors, flavors);
    if (task == mach_task_self()) {
        LOG("[反调试] task_get_exception_ports 已拦截，过滤异常端口");
        // 清空异常端口（防止检测调试器）
        for (mach_msg_type_number_t i = 0; i < *masksCnt; i++) {
            ports[i] = MACH_PORT_NULL;
            behaviors[i] = EXCEPTION_DEFAULT;
            flavors[i] = THREAD_STATE_NONE;
        }
    }
    return ret;
}

// 4. dladdr Hook (隐藏frida/gadget)
static int (*orig_dladdr)(const void *addr, Dl_info *info);
static int my_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (ret != 0 && info && info->dli_fname) {
        NSString *fname = [NSString stringWithUTF8String:info->dli_fname];
        if ([fname rangeOfString:@"frida" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fname rangeOfString:@"gadget" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [fname rangeOfString:@"AisiMonitor"].location != NSNotFound) {
            LOG("[反调试] dladdr隐藏: %@", fname);
            return 0; // 假装找不到
        }
    }
    return ret;
}

// 5. strstr Hook (隐藏frida字符串)
static char *(*orig_strstr)(const char *haystack, const char *needle);
static char *my_strstr(const char *haystack, const char *needle) {
    if (needle) {
        NSString *n = [NSString stringWithUTF8String:needle];
        if ([n rangeOfString:@"frida" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"gadget" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"LINENO"].location != NSNotFound ||
            [n rangeOfString:@"re.frida"].location != NSNotFound) {
            LOG("[反调试] strstr检测: %s，返回null", needle);
            return NULL;
        }
    }
    return orig_strstr(haystack, needle);
}

// 6. 内存Patch：直接修改反调试函数的指令
static void patchAntidebugInMemory() {
    // 查找ptrace函数并patch为mov w0, #0; ret
    void *ptraceAddr = dlsym(RTLD_DEFAULT, "ptrace");
    if (ptraceAddr) {
        vm_protect(mach_task_self(), (vm_address_t)ptraceAddr, 8, YES, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        // arm64: mov w0, #0 (0x52800000), ret (0xD65F03C0)
        uint32_t *code = (uint32_t *)ptraceAddr;
        code[0] = 0x52800000; // mov w0, #0
        code[1] = 0xD65F03C0; // ret
        vm_protect(mach_task_self(), (vm_address_t)ptraceAddr, 8, YES, VM_PROT_READ | VM_PROT_EXECUTE);
        LOG("[反调试] ptrace已内存patch为直接返回0");
    }
}

// ========== PxExtFFiMgr Hook ==========

%hook NSObject // 用NSObject作为hook容器，实际用C函数Hook

// AddLibPath
%end

// C函数Hook用MSHookFunction
static void (*orig_AddLibPath)(void *self, const char *path);
static void my_AddLibPath(void *self, const char *path) {
    LOG("[AddLibPath] 路径: %s", path ? path : "(null)");
    orig_AddLibPath(self, path);
}

static void *(*orig_OpenHandle)(void *self, const char *filename);
static void *my_OpenHandle(void *self, const char *filename) {
    LOG("[OpenHandle] 尝试加载: %s", filename ? filename : "(null)");
    void *ret = orig_OpenHandle(self, filename);
    LOG("[OpenHandle] 返回句柄: %p %s", ret, ret ? "(成功)" : "(失败)");
    return ret;
}

static void *(*orig_GetExport)(void *self, void *handle, const char *symbol);
static void *my_GetExport(void *self, void *handle, const char *symbol) {
    void *ret = orig_GetExport(self, handle, symbol);
    LOG("[GetExport] 句柄=%p 函数=%s 地址=%p", handle, symbol ? symbol : "(null)", ret);
    return ret;
}

static void hookPxExtFFiMgr() {
    void *handle = dlopen("@rpath/PxExtFFi.framework/PxExtFFi", RTLD_NOW);
    if (!handle) handle = RTLD_DEFAULT;

    void *addLib = dlsym(handle, "__ZN11PxExtFFiMgr10AddLibPathEPKc");
    void *openHdl = dlsym(handle, "__ZN11PxExtFFiMgr10OpenHandleEPKc");
    void *getExp = dlsym(handle, "__ZN11PxExtFFiMgr9GetExportEPvPKc");

    if (addLib) {
        MSHookFunction(addLib, (void *)my_AddLibPath, (void **)&orig_AddLibPath);
        LOG("[+] Hook AddLibPath @ %p", addLib);
    }
    if (openHdl) {
        MSHookFunction(openHdl, (void *)my_OpenHandle, (void **)&orig_OpenHandle);
        LOG("[+] Hook OpenHandle @ %p", openHdl);
    }
    if (getExp) {
        MSHookFunction(getExp, (void *)my_GetExport, (void **)&orig_GetExport);
        LOG("[+] Hook GetExport @ %p", getExp);
    }
}

// ========== dlopen/dlsym底层Hook ==========
static void *(*orig_dlopen)(const char *path, int mode);
static void *my_dlopen(const char *path, int mode) {
    void *ret = orig_dlopen(path, mode);
    if (path && (strstr(path, "PxExt") || strstr(path, "eye") || strstr(path, "Libraries"))) {
        LOG("[dlopen] %s mode=%d -> %p", path, mode, ret);
    }
    return ret;
}

static void *(*orig_dlsym)(void *handle, const char *symbol);
static void *my_dlsym(void *handle, const char *symbol) {
    void *ret = orig_dlsym(handle, symbol);
    if (symbol && (strstr(symbol, "PxExt") || strstr(symbol, "PxLib") ||
                   strstr(symbol, "esp") || strstr(symbol, "ESP") ||
                   strstr(symbol, "draw") || strstr(symbol, "Draw") ||
                   strstr(symbol, "start") || strstr(symbol, "init"))) {
        LOG("[dlsym] %s -> %p", symbol, ret);
    }
    return ret;
}

// ========== ObjC绘制Hook ==========

%hook UIBezierPath

- (void)addLineToPoint:(CGPoint)point {
    LOG("[骨骼线] (%.1f, %.1f)", point.x, point.y);
    %orig;
}

- (void)addArcWithCenter:(CGPoint)center radius:(CGFloat)radius startAngle:(CGFloat)startAngle endAngle:(CGFloat)endAngle clockwise:(BOOL)clockwise {
    LOG("[FOV圆圈] 中心=(%.0f,%.0f) 半径=%.1f 角度=%.0f°→%.0f°",
        center.x, center.y, radius, startAngle * 180 / M_PI, endAngle * 180 / M_PI);
    %orig;
}

- (void)moveToPoint:(CGPoint)point {
    LOG("[moveToPoint] (%.1f, %.1f)", point.x, point.y);
    %orig;
}

%end

%hook UIColor

+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    UIColor *c = %orig;
    LOG("[UIColor] RGBA=(%.0f,%.0f,%.0f,%.2f)", red*255, green*255, blue*255, alpha);
    return c;
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    if (text && text.length > 0) {
        CGRect frame = self.frame;
        LOG("[UILabel] \"%@\" 位置=(%.0f,%.0f) 大小=(%.0fx%.0f)",
            text, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    %orig;
}

%end

%hook UISlider

- (void)setValue:(float)value {
    LOG("[UISlider] FOV值=%.2f", value);
    %orig;
}

%end

%hook UITapGestureRecognizer

- (void)setNumberOfTapsRequired:(NSUInteger)taps {
    LOG("[手势] 点击次数=%lu", (unsigned long)taps);
    %orig;
}

- (void)setNumberOfTouchesRequired:(NSUInteger)touches {
    LOG("[手势] 手指数=%lu", (unsigned long)touches);
    %orig;
}

%end

%hook CAShapeLayer

- (void)setPath:(CGPathRef)path {
    if (path) {
        LOG("[CAShapeLayer setPath] 路径=%p", path);
    }
    %orig;
}

- (void)setStrokeColor:(CGColorRef)color {
    if (color) {
        const CGFloat *components = CGColorGetComponents(color);
        size_t count = CGColorGetNumberOfComponents(color);
        if (count >= 3) {
            LOG("[CAShapeLayer 描边色] RGBA=(%.0f,%.0f,%.0f,%.2f)",
                components[0]*255, components[1]*255, components[2]*255,
                count >= 4 ? components[3] : 1.0);
        }
    }
    %orig;
}

%end

// ========== 构造函数（最早执行）==========
__attribute__((constructor))
static void AisiMonitorConstructor() {
    @autoreleasepool {
        initLog();
        LOG("========== AisiMonitor构造函数执行 ==========");
        LOG("PID: %d, 进程: %@", getpid(), [[NSProcessInfo processInfo] processName]);

        // 1. 最先执行：内存patch反调试
        patchAntidebugInMemory();

        // 2. Hook系统反调试函数
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "ptrace"),
                       (void *)my_ptrace, (void **)&orig_ptrace);
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "sysctl"),
                       (void *)my_sysctl, (void **)&orig_sysctl);
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "task_get_exception_ports"),
                       (void *)my_task_get_exception_ports, (void **)&orig_task_get_exception_ports);
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "dladdr"),
                       (void *)my_dladdr, (void **)&orig_dladdr);
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "strstr"),
                       (void *)my_strstr, (void **)&orig_strstr);
        LOG("[+] 系统反调试函数Hook完成");

        // 3. Hook dlopen/dlsym
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "dlopen"),
                       (void *)my_dlopen, (void **)&orig_dlopen);
        MSHookFunction((void *)dlsym(RTLD_DEFAULT, "dlsym"),
                       (void *)my_dlsym, (void **)&orig_dlsym);

        // 4. 延迟Hook PxExtFFiMgr（等框架加载后）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                hookPxExtFFiMgr();
                LOG("[+] PxExtFFiMgr Hook完成");

                // 枚举已加载模块
                LOG("========== 已加载模块 ==========");
                Dl_info info;
                uint32_t count = _dyld_image_count();
                for (uint32_t i = 0; i < count; i++) {
                    const char *name = _dyld_get_image_name(i);
                    if (name && (strstr(name, "PxExt") || strstr(name, "eye") ||
                                 strstr(name, "爱思") || strstr(name, "notes"))) {
                        LOG("  模块: %s @ 0x%llx", name,
                            (unsigned long long)_dyld_get_image_vmaddr_slide(i));
                    }
                }
            }
        });

        LOG("[+] AisiMonitor初始化完成，反调试已绕过");
    }
}
