#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <dlfcn.h>

static void dump_memory(void) {
    @autoreleasepool {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

        // 等待90秒让爱思完成下载+解密+加载ESP
        for (int i = 0; i < 9; i++) {
            [NSThread sleepForTimeInterval:10.0];
            NSString *status = [NSString stringWithFormat:@"waiting_%d", i*10+10];
            [status writeToFile:[docs stringByAppendingPathComponent:[NSString stringWithFormat:@"gamedump_status_%d.txt", i*10+10]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        [@"started" writeToFile:[docs stringByAppendingPathComponent:@"gamedump_started.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *dumpDir = [docs stringByAppendingPathComponent:@"gamedump"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dumpDir withIntermediateDirectories:YES attributes:nil error:nil];

        mach_port_t task = mach_task_self();
        vm_address_t address = 0;
        vm_size_t size = 0;
        NSMutableString *report = [NSMutableString stringWithString:@"=== Aisi Process Memory Dump ===\n"];
        int regionCount = 0;

        while (1) {
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            natural_t depth = 0;
            kern_return_t kr = vm_region_recurse_64(task, &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
            if (kr != KERN_SUCCESS) break;
            // dump所有可读区域，包括r-x（代码）和rw-（数据）
            if ((info.protection & VM_PROT_READ) && size > 0x1000 && size < 0x20000000) {
                vm_offset_t data = 0;
                mach_msg_type_number_t dataSize = 0;
                kr = vm_read(task, address, size, &data, &dataSize);
                if (kr == KERN_SUCCESS && dataSize > 0) {
                    NSString *filename = [NSString stringWithFormat:@"%@/region_%08x_%08x_prot%d.bin", dumpDir, (uint32_t)address, (uint32_t)size, info.protection];
                    NSData *memData = [NSData dataWithBytes:(void *)data length:dataSize];
                    [memData writeToFile:filename atomically:YES];
                    vm_deallocate(task, data, dataSize);
                    [report appendFormat:@"Region 0x%08llx size=0x%08llx prot=%d\n", (unsigned long long)address, (unsigned long long)size, info.protection];
                    regionCount++;
                }
            }
            address += size;
            if (address > 0x400000000) break;
        }
        [report appendFormat:@"Total regions: %d\n", regionCount];
        [report writeToFile:[docs stringByAppendingPathComponent:@"gamedump_report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"done" writeToFile:[docs stringByAppendingPathComponent:@"gamedump_done.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor))
static void initialize() {
    @autoreleasepool {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        [@"tweak_loaded" writeToFile:[docs stringByAppendingPathComponent:@"gamedump_loaded.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool { dump_memory(); }
        });
    }
}
