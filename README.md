# AisiSpy — TrollStore 爱思助手监视工具

TrollStore可直接安装的IPA，内置root helper和注入dylib，一键注入监视爱思助手。

## 架构

```
┌──────────────────────────────────────────────────┐
│              AisiSpy.ipa (TrollStore安装)         │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │  AisiSpy.app                               │  │
│  │                                            │  │
│  │  AisiSpy (主程序, UI)                      │  │
│  │    ├─ 进程状态检测                          │  │
│  │    ├─ 注入控制按钮                          │  │
│  │    ├─ 实时日志预览                          │  │
│  │    ├─ 内存Dump                             │  │
│  │    └─ 模块列表                             │  │
│  │                                            │  │
│  │  aisi_helper (setuid root)                 │  │
│  │    ├─ 进程查找                              │  │
│  │    ├─ 内存读写                              │  │
│  │    ├─ dylib远程注入                         │  │
│  │    └─ 模块枚举                              │  │
│  │                                            │  │
│  │  AisiMonitor.dylib (注入用)                │  │
│  │    ├─ 反调试patch (ptrace内存改写)          │  │
│  │    ├─ PxExtFFiMgr Hook                     │  │
│  │    ├─ 绘制Hook (UIBezierPath/UILabel)      │  │
│  │    └─ 日志输出                              │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  注入到爱思助手进程后:                            │
│  /var/mobile/Documents/aisi_monitor.log          │
└──────────────────────────────────────────────────┘
```

## 编译

### 环境要求
- Mac OS X 或 Linux
- Theos (https://theos.dev)
- iOS 16.5 SDK
- ldid (签名工具)
- clang

### 一键编译
```bash
cd AisiSpy
chmod +x build_ipa.sh
./build_ipa.sh
```

输出:
- `AisiSpy.ipa` — TrollStore安装包
- `AisiSpy.tipa` — TrollStore专用格式

## 安装

1. 将 `AisiSpy.ipa` 传到手机（AirDrop/文件App）
2. 用 **TrollStore** 打开 → 安装
3. 桌面出现「AisiSpy」图标

## 使用

### 步骤
1. **先启动爱思助手**（让它运行）
2. 打开 **AisiSpy**
3. 确认状态显示「运行中」+ PID
4. 点击 **「注入监视」**
5. 等待注入成功提示
6. 实时日志会显示在下方
7. 点击 **「查看完整日志」** 看全部输出

### 功能按钮

| 按钮 | 功能 |
|------|------|
| 注入监视 | 将AisiMonitor.dylib注入到爱思助手进程 |
| 停止监视 | 终止爱思助手进程 |
| 刷新状态 | 刷新进程状态和日志 |
| Dump内存 | 输入地址和大小，dump爱思助手内存 |
| 模块列表 | 列出爱思助手加载的所有dylib |
| 查看完整日志 | 全屏查看日志，支持分享 |

## 注入后会记录

```
[反调试] ptrace已内存patch为直接返回0
[AddLibPath] /var/mobile/Library/Caches/Libraries/
[OpenHandle] PxExtFFi.bin -> 0x... (成功)
[GetExport] PxLib_start_PxExtFFi -> 0x...
[dlsym] get_entity_list -> 0x...
[骨骼线] (150.0, 300.0)
[FOV圆圈] 中心=(200,400) 半径=90.0
[UIColor] RGBA=(255,0,0,1.00)
[UILabel] "敌人 15m" 位置=(145,290)
[UISlider] FOV值=90.00
[手势] 点击次数=2 手指数=3
```

## 反调试绕过原理

Tweak.dylib注入到爱思助手后，constructor在main()之前执行：

1. **内存patch ptrace** — 直接改写指令为 `mov w0,#0; ret`
2. **Hook sysctl** — 清除P_TRACED标志
3. **Hook task_get_exception_ports** — 返回空异常端口
4. **Hook dladdr** — 隐藏frida/gadget路径
5. **Hook strstr** — 拦截"frida"/"gadget"字符串检测

## 文件结构

```
AisiSpy/
├── Makefile                  # theos App编译配置
├── build_ipa.sh              # 一键编译打包脚本
├── README.md                 # 本文件
├── Resources/
│   ├── Info.plist            # App信息
│   └── entitlements.plist    # root权限配置
├── AisiSpy/
│   ├── main.m                # 入口
│   ├── AppDelegate.h/.m      # 应用代理
│   ├── ViewController.h/.m   # 主界面
│   └── LogViewController.h/.m # 日志查看器
├── helper/
│   └── helper.c              # root helper源码
└── Tweak/
    ├── Makefile              # Tweak编译配置
    └── Tweak.xm              # 注入dylib源码
```

## 注意事项

1. **TrollStore版本**: 需要TrollStore 2 (支持root权限和setuid)
2. **iOS版本**: 测试于iOS 16.5，支持15.0-16.6.1
3. **注入时机**: 必须先启动爱思助手，再注入
4. **日志文件**: 确保`/var/mobile/Documents/`可写
5. **反调试**: 注入后爱思助手的反调试全部失效，可以正常用frida attach
6. **setuid**: aisi_helper需要6755权限，TrollStore安装时保留
