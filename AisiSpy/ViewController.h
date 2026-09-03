#import <UIKit/UIKit.h>

@interface ViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UILabel *pidLabel;
@property (strong, nonatomic) UITextView *logPreview;
@property (strong, nonatomic) UIButton *injectBtn;
@property (strong, nonatomic) UIButton *stopBtn;
@property (strong, nonatomic) UIButton *refreshBtn;
@property (strong, nonatomic) UIButton *dumpBtn;
@property (strong, nonatomic) UIButton *modulesBtn;
@property (assign, nonatomic) BOOL isMonitoring;
@property (assign, nonatomic) int targetPID;
@end
