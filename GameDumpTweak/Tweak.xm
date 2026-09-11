#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <dlfcn.h>
#import <sys/stat.h>

// 游戏内存dump Tweak
// 只注入com.tencent.smoba (王者荣耀)
// 不hook任何函数，constructor启动后台线程dump内存

static void dump_memory(void) {
    @autoreleasepool {
        NSString *logPath = @"/tmp/gamedump_started.txt";
        [@"started" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 等待30秒让游戏完全加载+爱思助手ESP启动
        [NSThread sleepForTimeInterval:30.0];

        NSString *dumpDir = @"/tmp/gamedump";
        [[NSFileManager defaultManager] createDirectoryAtPath:dumpDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        mach_port_t task = mach_task_self();
        vm_address_t address = 0;
        vm_size_t size = 0;

        NSMutableString *report = [NSMutableString stringWithString:@"=== Game Memory Dump ===\n"];
        int regionCount = 0;

        while (1) {
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            natural_t depth = 0;

            kern_return_t kr = vm_region_recurse_64(task, &address, &size, &depth,
                                                     (vm_region_recurse_info_t)&info, &count);
            if (kr != KERN_SUCCESS) break;

            // 只dump可读可写的内存区域（游戏数据）
            if ((info.protection & VM_PROT_READ) && size > 0x1000 && size < 0x10000000) {
                vm_offset_t data = NULL;
                mach_msg_type_number_t dataSize = 0;

                kr = vm_read(task, address, size, &data, &dataSize);
                if (kr == KERN_SUCCESS && dataSize > 0) {
                    NSString *filename = [NSString stringWithFormat:@"%@/region_%08x_%08x.bin",
                                          dumpDir, (uint32_t)address, (uint32_t)size];
                    NSData *memData = [NSData dataWithBytes:(void *)data length:dataSize];
                    [memData writeToFile:filename atomically:YES];
                    vm_deallocate(task, data, dataSize);

                    [report appendFormat:@"Region 0x%08llx size=0x%08llx prot=%d saved\n",
                     (unsigned long long)address, (unsigned long long)size, info.protection];
                    regionCount++;
                }
            }

            address += size;
            if (address > 0x400000000) break; // 限制范围
        }

        [report appendFormat:@"Total regions: %d\n", regionCount];
        NSString *reportPath = @"/tmp/gamedump_report.txt";
        [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 标记完成
        [@"done" writeToFile:@"/tmp/gamedump_done.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor))
static void initialize() {
    @autoreleasepool {
        [@"tweak_loaded" writeToFile:@"/tmp/gamedump_loaded.txt"
                          atomically:YES encoding:NSUTF8StringEncoding error:nil];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool {
                dump_memory();
            }
        });
    }
}
