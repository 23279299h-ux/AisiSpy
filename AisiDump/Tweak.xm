/*
 * AisiDump v5 - RootHide/ElleKit ESP Memory Dumper
 *
 * Targets: com.tencent.smoba (game) + rn.notes.best (loader)
 *
 * What it does:
 *  1. Constructor writes marker immediately (confirms ElleKit loading)
 *  2. Background thread polls for eye.framework / PxExtFFi
 *  3. When found, dumps the decrypted __TEXT segment to file
 *  4. Logs all loaded images for analysis
 *  5. Dumps entity pointer chain values
 */

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/syslog.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/task.h>

/* ---------- logging ---------- */

static void alog(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    /* syslog (visible via `log show --predicate 'process == "..."'`) */
    syslog(LOG_NOTICE, "AisiDump: %s", buf);

    /* try multiple file paths */
    const char *paths[] = {
        "/var/mobile/Documents/aisidump_v5.log",
        "/tmp/aisidump_v5.log",
        "/var/mobile/Library/Caches/aisidump_v5.log",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, buf, strlen(buf));
            write(fd, "\n", 1);
            close(fd);
        }
    }
}

/* ---------- Mach-O segment dump ---------- */

static void dump_image_memory(const char *needle, const char *outPath) {
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, needle)) continue;

        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        alog("FOUND image: %s", name);
        alog("  header=%p slide=0x%lx", (void *)mh, (long)slide);

        if (!mh) continue;

        /* walk load commands */
        const uint8_t *ptr = (const uint8_t *)mh + sizeof(struct mach_header_64);
        for (uint32_t lc = 0; lc < mh->ncmds; lc++) {
            const struct load_command *cmd = (const struct load_command *)ptr;
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)ptr;

                alog("  SEG %-16s vmaddr=0x%llx vmsize=0x%llx fileoff=0x%llx filesize=0x%llx",
                     seg->segname, seg->vmaddr, seg->vmsize,
                     seg->fileoff, seg->filesize);

                /* dump readable, non-zero segments */
                if (seg->vmsize > 0 && seg->vmsize < 64*1024*1024) {
                    char segPath[512];
                    snprintf(segPath, sizeof(segPath), "%s.%s.bin",
                             outPath, seg->segname);
                    int fd = open(segPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
                    if (fd >= 0) {
                        const void *segStart =
                            (const void *)(seg->vmaddr + slide);
                        /* write in pages, skip unmapped */
                        size_t remaining = seg->vmsize;
                        size_t off = 0;
                        uint8_t zeroPage[0x4000];
                        memset(zeroPage, 0, sizeof(zeroPage));
                        while (remaining > 0) {
                            size_t chunk = remaining > 0x4000 ? 0x4000 : remaining;
                            const void *src = (const uint8_t *)segStart + off;
                            /* try to read; if fault, write zeros */
                            kern_return_t kr = KERN_SUCCESS;
                            vm_address_t addr = (vm_address_t)src;
                            vm_size_t regionSize = 0;
                            vm_region_basic_info_data_64_t info;
                            mach_msg_type_number_t cnt =
                                VM_REGION_BASIC_INFO_COUNT_64;
                            mach_port_t objName = MACH_PORT_NULL;
                            kr = vm_region_64(mach_task_self(), &addr,
                                              &regionSize, VM_REGION_BASIC_INFO_64,
                                              (vm_region_info_t)&info, &cnt,
                                              &objName);
                            if (kr == KERN_SUCCESS &&
                                (addr <= (vm_address_t)src)) {
                                write(fd, src, chunk);
                            } else {
                                write(fd, zeroPage, chunk);
                            }
                            off += chunk;
                            remaining -= chunk;
                        }
                        close(fd);
                        alog("  -> dumped %s (%zu bytes)", segPath, (size_t)seg->vmsize);
                    }
                }
            }
            ptr += cmd->cmdsize;
        }
    }
}

/* ---------- list all images ---------- */

static void listAllImages(void) {
    uint32_t n = _dyld_image_count();
    alog("=== Loaded images: %u ===", n);
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        /* log everything for the first 100, then only interesting ones */
        if (i < 100 ||
            (name && (strstr(name, "eye") || strstr(name, "PxExt") ||
                      strstr(name, "Unity") || strstr(name, "pxauth") ||
                      strstr(name, "notes") || strstr(name, "smoba") ||
                      strstr(name, "ElleKit") || strstr(name, "substrate") ||
                      strstr(name, "Cydia") || strstr(name, "Tweak")))) {
            alog("  [%3u] %p +0x%lx %s", i, (void *)mh, (long)slide,
                 name ? name : "?");
        }
    }
    alog("=== end image list ===");
}

/* ---------- background monitor ---------- */

static int dumped = 0;

static void *monitorThread(void *arg) {
    (void)arg;
    alog("monitor thread started, pid=%d", getpid());

    int rounds = 0;
    for (int tick = 0; tick < 600 && rounds < 3; tick++) {
        /* check for eye.framework */
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;

            if (strstr(name, "eye") || strstr(name, "PxExtFFi")) {
                alog("*** TARGET DETECTED at tick %d: %s", tick, name);
                listAllImages();

                /* dump both possible names */
                dump_image_memory("eye", "/var/mobile/Documents/eye_mem");
                dump_image_memory("PxExtFFi", "/var/mobile/Documents/pxext_mem");

                /* also dump via /tmp */
                dump_image_memory("eye", "/tmp/eye_mem");
                dump_image_memory("PxExtFFi", "/tmp/pxext_mem");

                rounds++;
                dumped = 1;
                alog("*** DUMP ROUND %d COMPLETE ***", rounds);
                break;   /* 跳出镜像循环 */
            }
        }
        if (dumped) tick += 59;  /* 本轮已dump, 快进60s再补采 */
        sleep(1);
    }

    if (!dumped) {
        alog("monitor timed out after 600s, target not loaded");
        /* still dump image list for debugging */
        listAllImages();
    }
    return NULL;
}

/* ---------- constructor ---------- */

__attribute__((constructor))
static void aisi_init(void) {
    /* 1. write marker FIRST, before anything else can fail */
    const char *markers[] = {
        "/var/mobile/Documents/AISIDUMP_V5_LOADED.txt",
        "/tmp/AISIDUMP_V5_LOADED.txt",
        NULL
    };
    for (int i = 0; markers[i]; i++) {
        int fd = open(markers[i], O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd >= 0) {
            const char msg[] = "loaded\n";
            write(fd, msg, sizeof(msg) - 1);
            close(fd);
        }
    }

    alog(" ");
    alog("==============================");
    alog("AisiDump v5 constructor");
    alog("pid=%d uid=%d", getpid(), getuid());

    /* executable path */
    char exePath[1024] = {0};
    uint32_t pathSize = sizeof(exePath);
    if (_NSGetExecutablePath(exePath, &pathSize) == 0) {
        alog("exe: %s", exePath);
    }

    /* immediate image snapshot */
    listAllImages();

    /* start background monitor */
    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&tid, &attr, monitorThread, NULL) == 0) {
        alog("monitor thread created");
    } else {
        alog("FAILED to create monitor thread: %s", strerror(errno));
    }
    pthread_attr_destroy(&attr);

    alog("constructor done");
}
