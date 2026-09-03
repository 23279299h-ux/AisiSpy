#import "LogViewController.h"

@implementation LogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:1.0];
    
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.3 alpha:1.0];
    tv.font = [UIFont fontWithName:@"Menlo" size:12];
    tv.editable = NO;
    
    if (self.logFilePath) {
        tv.text = [NSString stringWithContentsOfFile:self.logFilePath encoding:NSUTF8StringEncoding error:nil] ?: @"日志文件不存在";
    } else if (self.logText) {
        tv.text = self.logText;
    }
    
    [self.view addSubview:tv];
    
    // 分享按钮
    UIBarButtonItem *shareBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareLog)];
    self.navigationItem.rightBarButtonItem = shareBtn;
}

- (void)shareLog {
    NSString *text = self.logText ?: [NSString stringWithContentsOfFile:self.logFilePath encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    [self presentViewController:avc animated:YES completion:nil];
}

@end
