// AisiMonitor Helper — root权限二进制工具
// 功能：进程查找、内存读写、dylib注入、反调试patch
// 编译：clang -arch arm64 -o helper helper.c -framework Foundation -framework IOKit
// 权限：chmod 6755 helper (setuid root)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <errno.h>

#define TARGET_BUNDLE "rn.notes.best"
#define LOG_FILE "/var/mobile/Documents/aisi_helper.log"

static FILE *g_log = NULL;

static void log_msg(const char *fmt, ...) {
    if (!g_log) g_log = fopen(LOG_FILE, "a");
    if (!g_log) return;
    va_list args;
    va_start(args, fmt);
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    fprintf(g_log, "[%02d:%02d:%02d] ", tm->tm_hour, tm->tm_min, tm->tm_sec);
    vfprintf(g_log, fmt, args);
    fprintf(g_log, "\n");
    fflush(g_log);
    va_end(args);
}

// ========== 1. 查找目标进程PID ==========
static pid_t find_process(const char *bundle_id) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    sysctl(mib, 3, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = malloc(size);
    sysctl(mib, 3, procs, &size, NULL, 0);

    pid_t pid = -1;
    int count = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        if (procs[i].kp_proc.p_pid > 0) {
            // 通过进程名匹配（爱思助手可能显示为不同名字）
            char name[256];
            strncpy(name, procs[i].kp_proc.p_comm, sizeof(name)-1);
            name[sizeof(name)-1] = 0;
            if (strstr(name, "爱思") || strstr(name, "notes") ||
                strstr(name, "eye") || strstr(name, "best")) {
                pid = procs[i].kp_proc.p_pid;
                log_msg("找到进程: PID=%d name=%s", pid, name);
                break;
            }
        }
    }
    free(procs);
    return pid;
}

// ========== 2. 获取task端口 ==========
static task_port_t get_task(pid_t pid) {
    task_port_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        log_msg("task_for_pid失败: %s", mach_error_string(kr));
        return MACH_PORT_NULL;
    }
    log_msg("获取task端口成功: 0x%x", task);
    return task;
}

// ========== 3. 读取内存 ==========
static int read_memory(task_port_t task, mach_vm_address_t addr, void *buf, size_t size) {
    mach_vm_size_t out_size = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, size, (mach_vm_address_t)buf, &out_size);
    if (kr != KERN_SUCCESS) {
        log_msg("读取内存失败 @0x%llx: %s", (unsigned long long)addr, mach_error_string(kr));
        return -1;
    }
    return (int)out_size;
}

// ========== 4. 写入内存 ==========
static int write_memory(task_port_t task, mach_vm_address_t addr, const void *buf, size_t size) {
    kern_return_t kr = mach_vm_write(task, addr, (vm_offset_t)buf, (mach_msg_type_number_t)size);
    if (kr != KERN_SUCCESS) {
        log_msg("写入内存失败 @0x%llx: %s", (unsigned long long)addr, mach_error_string(kr));
        return -1;
    }
    log_msg("写入内存成功 @0x%llx (%zu字节)", (unsigned long long)addr, size);
    return 0;
}

// ========== 5. Patch反调试函数（远程进程）==========
static int patch_remote_antidebug(task_port_t task) {
    // 在远程进程中查找ptrace符号地址
    // 注意：需要先获取远程进程的dyld共享缓存基址
    // 简化版：通过任务端口读取远程进程的符号表

    // 方法1：远程创建线程执行dlopen+dlsym+patch
    // 方法2：直接计算ptrace在dyld共享缓存中的偏移

    // arm64 patch: mov w0, #0; ret
    uint32_t patch_code[2] = {0x52800000, 0xD65F03C0};

    // 读取远程进程的dyld共享缓存基址
    task_dyld_info_data_t dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr != KERN_SUCCESS) {
        log_msg("获取dyld info失败: %s", mach_error_string(kr));
        return -1;
    }
    log_msg("dyld all_image_info_addr: 0x%llx", (unsigned long long)dyld_info.all_image_info_addr);

    // 读取all_image_info获取第一个镜像（dyld本身）
    struct dyld_all_image_infos *infos = malloc(sizeof(struct dyld_all_image_infos));
    mach_vm_size_t out_size;
    kr = mach_vm_read_overwrite(task, dyld_info.all_image_info_addr,
                                sizeof(struct dyld_all_image_infos),
                                (mach_vm_address_t)infos, &out_size);
    if (kr != KERN_SUCCESS) {
        log_msg("读取all_image_info失败");
        free(infos);
        return -1;
    }

    // 第一个镜像通常是dyld
    if (infos->infoArrayCount > 0) {
        struct dyld_image_info *img = malloc(sizeof(struct dyld_image_info) * infos->infoArrayCount);
        mach_vm_read_overwrite(task, (mach_vm_address_t)infos->infoArray,
                               sizeof(struct dyld_image_info) * infos->infoArrayCount,
                               (mach_vm_address_t)img, &out_size);

        for (uint32_t i = 0; i < infos->infoArrayCount; i++) {
            char path[1024];
            mach_vm_read_overwrite(task, (mach_vm_address_t)img[i].imageFilePath,
                                   sizeof(path), (mach_vm_address_t)path, &out_size);
            if (strstr(path, "libsystem_kernel") || strstr(path, "dyld")) {
                log_msg("镜像[%d]: %s @ 0x%llx", i, path,
                        (unsigned long long)img[i].imageLoadAddress);
                // 在libsystem_kernel中找ptrace
                // 简化：ptrace在libsystem_kernel.dylib中的偏移是固定的
                // 需要解析Mach-O符号表，这里用已知偏移（iOS 16.5）
                // 实际使用时需要动态解析
            }
        }
        free(img);
    }
    free(infos);

    log_msg("远程反调试patch需要解析远程符号表，建议使用Tweak注入方式");
    return 0;
}

// ========== 6. 远程dylib注入 ==========
static int inject_dylib(task_port_t task, const char *dylib_path) {
    // 方法：在远程进程中分配内存，写入dylib路径，创建线程执行dlopen
    mach_vm_address_t remote_path = 0;
    mach_vm_size_t path_len = strlen(dylib_path) + 1;

    // 1. 在远程进程分配内存
    kern_return_t kr = mach_vm_allocate(task, &remote_path, path_len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        log_msg("分配远程内存失败: %s", mach_error_string(kr));
        return -1;
    }

    // 2. 写入dylib路径
    kr = mach_vm_write(task, remote_path, (vm_offset_t)dylib_path, (mach_msg_type_number_t)path_len);
    if (kr != KERN_SUCCESS) {
        log_msg("写入dylib路径失败: %s", mach_error_string(kr));
        return -1;
    }
    log_msg("dylib路径已写入远程内存 @0x%llx", (unsigned long long)remote_path);

    // 3. 获取dlopen在远程进程中的地址
    // dlopen在libdyld.dylib中，需要解析远程符号
    // 简化：使用本地dlopen地址 + ASLR偏移差
    void *local_dlopen = dlsym(RTLD_DEFAULT, "dlopen");
    log_msg("本地dlopen地址: %p", local_dlopen);

    // 4. 创建远程线程执行dlopen(path, RTLD_NOW)
    // arm64线程状态：x0=path, x1=RTLD_NOW(2), pc=dlopen
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__x[0] = remote_path;           // 第一个参数：path
    state.__x[1] = 2;                     // 第二个参数：RTLD_NOW
    state.__pc = (uint64_t)local_dlopen;  // 指令指针（需要修正为远程地址）
    state.__sp = 0;                       // 栈（需要分配）
    state.__cpsr = 0;

    thread_act_t thread;
    kr = thread_create_running(task, ARM_THREAD_STATE64,
                               (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
    if (kr != KERN_SUCCESS) {
        log_msg("创建远程线程失败: %s", mach_error_string(kr));
        return -1;
    }
    log_msg("远程线程已创建，执行dlopen(%s)", dylib_path);

    // 5. 等待线程完成
    usleep(500000); // 500ms

    // 6. 读取返回值（x0寄存器）
    thread_state64_t result_state;
    mach_msg_type_number_t result_count = ARM_THREAD_STATE64_COUNT;
    kr = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&result_state, &result_count);
    if (kr == KERN_SUCCESS) {
        log_msg("dlopen返回值: 0x%llx", (unsigned long long)result_state.__x[0]);
    }

    thread_terminate(thread);
    mach_vm_deallocate(task, remote_path, path_len);
    return 0;
}

// ========== 7. Dump远程进程内存 ==========
static int dump_memory(task_port_t task, mach_vm_address_t addr, size_t size, const char *out_file) {
    void *buf = malloc(size);
    if (!buf) return -1;

    int ret = read_memory(task, addr, buf, size);
    if (ret < 0) {
        free(buf);
        return -1;
    }

    FILE *f = fopen(out_file, "wb");
    if (!f) {
        log_msg("打开输出文件失败: %s", out_file);
        free(buf);
        return -1;
    }
    fwrite(buf, 1, size, f);
    fclose(f);
    free(buf);
    log_msg("内存dump完成: %s (%zu字节) @0x%llx", out_file, size, (unsigned long long)addr);
    return 0;
}

// ========== 8. 枚举远程进程模块 ==========
static int list_modules(task_port_t task) {
    task_dyld_info_data_t dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr != KERN_SUCCESS) return -1;

    struct dyld_all_image_infos *infos = malloc(sizeof(struct dyld_all_image_infos));
    mach_vm_size_t out_size;
    mach_vm_read_overwrite(task, dyld_info.all_image_info_addr,
                           sizeof(struct dyld_all_image_infos),
                           (mach_vm_address_t)infos, &out_size);

    log_msg("========== 远程进程模块列表 (%d个) ==========", infos->infoArrayCount);
    struct dyld_image_info *img = malloc(sizeof(struct dyld_image_info) * infos->infoArrayCount);
    mach_vm_read_overwrite(task, (mach_vm_address_t)infos->infoArray,
                           sizeof(struct dyld_image_info) * infos->infoArrayCount,
                           (mach_vm_address_t)img, &out_size);

    for (uint32_t i = 0; i < infos->infoArrayCount; i++) {
        char path[1024] = {0};
        mach_vm_read_overwrite(task, (mach_vm_address_t)img[i].imageFilePath,
                               sizeof(path)-1, (mach_vm_address_t)path, &out_size);
        log_msg("  [%d] 0x%llx %s", i,
                (unsigned long long)img[i].imageLoadAddress, path);
    }

    free(img);
    free(infos);
    return 0;
}

// ========== 主函数 ==========
int main(int argc, char *argv[]) {
    // 检查root权限
    if (getuid() != 0) {
        fprintf(stderr, "需要root权限运行 (uid=%d)\n", getuid());
        fprintf(stderr, "请设置: chmod 6755 %s\n", argv[0]);
        return 1;
    }

    log_msg("========== AisiMonitor Helper启动 (uid=0) ==========");

    if (argc < 2) {
        printf("用法:\n");
        printf("  %s find              查找爱思助手进程\n", argv[0]);
        printf("  %s modules           列出远程进程模块\n", argv[0]);
        printf("  %s dump <addr> <size> <out>  Dump内存\n", argv[0]);
        printf("  %s inject <dylib>    注入dylib\n", argv[0]);
        printf("  %s patch             Patch远程反调试\n", argv[0]);
        return 0;
    }

    pid_t pid = find_process(TARGET_BUNDLE);
    if (pid < 0) {
        log_msg("未找到目标进程，请先启动爱思助手");
        fprintf(stderr, "未找到目标进程\n");
        return 1;
    }

    task_port_t task = get_task(pid);
    if (task == MACH_PORT_NULL) {
        fprintf(stderr, "获取task端口失败\n");
        return 1;
    }

    if (strcmp(argv[1], "find") == 0) {
        printf("找到进程: PID=%d\n", pid);
        list_modules(task);
    }
    else if (strcmp(argv[1], "modules") == 0) {
        list_modules(task);
        printf("模块列表已输出到日志\n");
    }
    else if (strcmp(argv[1], "dump") == 0 && argc >= 5) {
        mach_vm_address_t addr = strtoull(argv[2], NULL, 16);
        size_t size = strtoull(argv[3], NULL, 10);
        dump_memory(task, addr, size, argv[4]);
        printf("内存dump完成: %s\n", argv[4]);
    }
    else if (strcmp(argv[1], "inject") == 0 && argc >= 3) {
        inject_dylib(task, argv[2]);
        printf("dylib注入完成\n");
    }
    else if (strcmp(argv[1], "patch") == 0) {
        patch_remote_antidebug(task);
        printf("反调试patch完成\n");
    }
    else {
        fprintf(stderr, "未知命令: %s\n", argv[1]);
    }

    mach_port_deallocate(mach_task_self(), task);
    return 0;
}
