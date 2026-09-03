// 最小化测试dylib - 只写一个文件，不做任何其他操作
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor))
void minimal_test_init() {
    // 这是constructor的第一行，只要dylib被加载就一定会执行
    FILE *f = fopen("/tmp/aisi_minimal_loaded.txt", "w");
    if (f) {
        fprintf(f, "minimal dylib loaded! PID: %d\n", getpid());
        fclose(f);
    }

    // 再写一个，用不同的方式
    FILE *f2 = fopen("/tmp/aisi_minimal_loaded2.txt", "w");
    if (f2) {
        fprintf(f2, "second write OK\n");
        fclose(f2);
    }
}
