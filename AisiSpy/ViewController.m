#import "ViewController.h"
#import "LogViewController.h"
#import <sys/sysctl.h>
#import <mach/mach.h>

#define HELPER_PATH @"/usr/local/bin/aisi_helper"
#define LOG_PATH @"/var/mobile/Documents/aisi_monitor.log"
#define TWEAK_DYLIB @"AisiMonitor.dylib"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AisiSpy 监视工具";
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:1.0];
    self.isMonitoring = NO;
    self.targetPID = -1;
    [self setupUI];
    [self refreshStatus];
    [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(refreshLogPreview) userInfo:nil repeats:YES];
}

- (void)setupUI {
    CGFloat w = self.view.bounds.size.width;
    
    // 状态卡片
    UIView *statusCard = [[UIView alloc] initWithFrame:CGRectMake(15, 90, w-30, 100)];
    statusCard.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:1.0];
    statusCard.layer.cornerRadius = 12;
    [self.view addSubview:statusCard];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, 200, 25)];
    titleLabel.text = @"爱思助手进程状态";
    titleLabel.textColor = [UIColor lightGrayColor];
    titleLabel.font = [UIFont systemFontOfSize:14];
    [statusCard addSubview:titleLabel];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 35, 200, 30)];
    self.statusLabel.text = @"检测中...";
    self.statusLabel.textColor = [UIColor orangeColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:20];
    [statusCard addSubview:self.statusLabel];
    
    self.pidLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 65, 200, 25)];
    self.pidLabel.text = @"PID: --";
    self.pidLabel.textColor = [UIColor grayColor];
    self.pidLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    [statusCard addSubview:self.pidLabel];
    
    // 操作按钮
    NSArray *btnTitles = @[@"注入监视", @"停止监视", @"刷新状态", @"Dump内存", @"模块列表", @"查看完整日志"];
    NSArray *btnColors = @[
        [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0],
        [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0],
        [UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1.0],
        [UIColor colorWithRed:0.5 green:0.3 blue:0.7 alpha:1.0],
        [UIColor colorWithRed:0.3 green:0.5 blue:0.5 alpha:1.0],
        [UIColor colorWithRed:0.2 green:0.4 blue:0.6 alpha:1.0]
    ];
    SEL btnActions[] = {@selector(injectTapped), @selector(stopTapped), @selector(refreshTapped),
                        @selector(dumpTapped), @selector(modulesTapped), @selector(viewLogTapped)};
    
    CGFloat btnY = 210;
    CGFloat btnW = (w - 45) / 2;
    CGFloat btnH = 50;
    for (int i = 0; i < 6; i++) {
        CGFloat x = 15 + (i % 2) * (btnW + 15);
        CGFloat y = btnY + (i / 2) * (btnH + 12);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(x, y, btnW, btnH);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = btnColors[i];
        btn.layer.cornerRadius = 10;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        btn.tag = i;
        [btn addTarget:self action:btnActions[i] forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:btn];
        if (i == 0) self.injectBtn = btn;
        if (i == 1) self.stopBtn = btn;
    }
    
    // 日志预览
    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(15, 395, 200, 25)];
    logTitle.text = @"实时日志预览";
    logTitle.textColor = [UIColor lightGrayColor];
    logTitle.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:logTitle];
    
    self.logPreview = [[UITextView alloc] initWithFrame:CGRectMake(15, 425, w-30, self.view.bounds.size.height - 450)];
    self.logPreview.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:1.0];
    self.logPreview.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.3 alpha:1.0];
    self.logPreview.font = [UIFont fontWithName:@"Menlo" size:11];
    self.logPreview.editable = NO;
    self.logPreview.layer.cornerRadius = 8;
    [self.view addSubview:self.logPreview];
}

#pragma mark - 进程检测

- (int)findAisiProcess {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    sysctl(mib, 3, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = malloc(size);
    sysctl(mib, 3, procs, &size, NULL, 0);
    int count = size / sizeof(struct kinfo_proc);
    int pid = -1;
    for (int i = 0; i < count; i++) {
        char name[256] = {0};
        strncpy(name, procs[i].kp_proc.p_comm, sizeof(name)-1);
        if (strstr(name, "爱思") || strstr(name, "notes") ||
            strstr(name, "eye") || strstr(name, "best")) {
            pid = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return pid;
}

- (void)refreshStatus {
    self.targetPID = [self findAisiProcess];
    if (self.targetPID > 0) {
        self.statusLabel.text = @"运行中";
        self.statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
        self.pidLabel.text = [NSString stringWithFormat:@"PID: %d", self.targetPID];
    } else {
        self.statusLabel.text = @"未运行";
        self.statusLabel.textColor = [UIColor colorWithRed:0.8 green:0.3 blue:0.3 alpha:1.0];
        self.pidLabel.text = @"PID: --";
    }
}

- (void)refreshLogPreview {
    NSString *log = [NSString stringWithContentsOfFile:LOG_PATH encoding:NSUTF8StringEncoding error:nil];
    if (log) {
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        NSInteger start = MAX(0, (NSInteger)lines.count - 30);
        NSArray *lastLines = [lines subarrayWithRange:NSMakeRange(start, lines.count - start)];
        self.logPreview.text = [lastLines componentsJoinedByString:@"\n"];
        [self.logPreview scrollRangeToVisible:NSMakeRange(self.logPreview.text.length, 0)];
    }
}

#pragma mark - 按钮动作

- (void)injectTapped {
    if (self.targetPID < 0) {
        [self showAlert:@"错误" message:@"爱思助手未运行，请先启动"];
        return;
    }
    
    // 复制Tweak dylib到可写位置
    NSString *bundleDylib = [[NSBundle mainBundle] pathForResource:TWEAK_DYLIB ofType:nil];
    NSString *destPath = @"/var/mobile/Documents/AisiMonitor.dylib";
    [[NSFileManager defaultManager] copyItemAtPath:bundleDylib toPath:destPath error:nil];
    
    // 通过helper注入
    NSString *cmd = [NSString stringWithFormat:@"%@ inject %@", HELPER_PATH, destPath];
    [self runHelperCommand:cmd completion:^(NSString *output) {
        self.isMonitoring = YES;
        [self showAlert:@"注入成功" message:[NSString stringWithFormat:@"已注入到PID %d\n\n%@", self.targetPID, output]];
    }];
}

- (void)stopTapped {
    if (!self.isMonitoring) {
        [self showAlert:@"提示" message:@"当前未在监视"];
        return;
    }
    // kill爱思助手进程（停止监视）
    kill(self.targetPID, SIGTERM);
    self.isMonitoring = NO;
    [self refreshStatus];
    [self showAlert:@"已停止" message:@"已终止爱思助手进程"];
}

- (void)refreshTapped {
    [self refreshStatus];
    [self refreshLogPreview];
}

- (void)dumpTapped {
    if (self.targetPID < 0) {
        [self showAlert:@"错误" message:@"爱思助手未运行"];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Dump内存"
        message:@"输入地址和大小（十六进制地址，十进制大小）" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"地址 (如 0x1054000)";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"大小 (如 602112)";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Dump" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *addr = ac.textFields[0].text;
        NSString *size = ac.textFields[1].text;
        NSString *outFile = [NSString stringWithFormat:@"/var/mobile/Documents/dump_%@.bin", addr];
        NSString *cmd = [NSString stringWithFormat:@"%@ dump %@ %@ %@", HELPER_PATH, addr, size, outFile];
        [self runHelperCommand:cmd completion:^(NSString *output) {
            [self showAlert:@"Dump完成" message:[NSString stringWithFormat:@"输出: %@\n\n%@", outFile, output]];
        }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)modulesTapped {
    if (self.targetPID < 0) {
        [self showAlert:@"错误" message:@"爱思助手未运行"];
        return;
    }
    [self runHelperCommand:[NSString stringWithFormat:@"%@ modules", HELPER_PATH] completion:^(NSString *output) {
        LogViewController *lvc = [[LogViewController alloc] init];
        lvc.logText = output;
        lvc.title = @"模块列表";
        [self.navigationController pushViewController:lvc animated:YES];
    }];
}

- (void)viewLogTapped {
    LogViewController *lvc = [[LogViewController alloc] init];
    lvc.logFilePath = LOG_PATH;
    lvc.title = @"完整日志";
    [self.navigationController pushViewController:lvc animated:YES];
}

#pragma mark - Helper命令执行

- (void)runHelperCommand:(NSString *)cmd completion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *output = [NSMutableString string];
        FILE *pipe = popen([cmd UTF8String], "r");
        if (pipe) {
            char buf[1024];
            while (fgets(buf, sizeof(buf), pipe)) {
                [output appendString:[NSString stringWithUTF8String:buf]];
            }
            pclose(pipe);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(output ?: @"");
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
