# 没有Mac？两种编译方法

## 方法一：GitHub Actions 在线编译（推荐，最简单）

### 步骤

1. **注册GitHub账号** (https://github.com) — 免费

2. **创建新仓库**
   - 点右上角 `+` → `New repository`
   - 名字随便填，比如 `AisiSpy`
   - 选 `Public` 或 `Private` 都行
   - 点 `Create repository`

3. **上传所有文件**
   - 在仓库页面点 `uploading an existing file`
   - 把AisiSpy文件夹里的**所有文件和文件夹**拖进去
   - 包括 `.github` 文件夹（这个很重要，是自动编译配置）
   - 点 `Commit changes`

4. **触发编译**
   - 等1-2分钟，GitHub会自动开始编译
   - 点仓库顶部的 `Actions` 标签
   - 看到 `Build AisiSpy IPA` 正在运行
   - 等它变成绿色对勾（约5-10分钟）

5. **下载IPA**
   - 点进那个绿色的编译记录
   - 页面最下方 `Artifacts` 区域
   - 点 `AisiSpy-IPA` 下载
   - 解压得到 `AisiSpy.ipa` 和 `AisiSpy.tipa`

6. **安装到手机**
   - 把IPA传到手机（AirDrop/微信/文件App）
   - 用TrollStore打开安装
   - 桌面出现AisiSpy图标

### 优点
- 完全免费
- 不需要装任何软件
- 5-10分钟搞定
- 以后改代码push上去自动重新编译

---

## 方法二：手机上直接编译（需要TrollStore+Sileo）

### 步骤

1. **安装Sileo** (TrollStore可装)
   - 浏览器打开 https://getsileo.app
   - 下载TrollStore版本的Sileo
   - 用TrollStore安装

2. **添加Procursus源**
   - 打开Sileo
   - 底部 `Sources` → 右上角 `+`
   - 输入: `https://apt.procurs.us`
   - 点 `Add Source`

3. **安装编译工具**
   - Sileo搜索并安装:
     - `clang` (编译器)
     - `ldid` (签名工具)
     - `make` (构建工具)
     - `theos` (iOS开发框架)
     - `git` (版本控制)
     - `NewTerm` (终端)
   - 全部安装完后重启手机

4. **上传项目到手机**
   - 方法A: 用Filza的WebDAV服务器（Filza设置里开启）
   - 方法B: AirDrop整个文件夹
   - 方法C: 用iTunes/Finder共享文件
   - 放到 `/var/mobile/Documents/AisiSpy/`

5. **编译**
   - 打开NewTerm
   - 输入:
     ```bash
     su
     # 输入密码（默认alpine）
     cd /var/mobile/Documents/AisiSpy
     bash build_on_ios.sh
     ```
   - 等待编译完成（手机上约10-20分钟）
   - 生成 `AisiSpy.ipa`

6. **安装**
   - 用Filza找到 `/var/mobile/Documents/AisiSpy/AisiSpy.ipa`
   - 点击 → 用TrollStore打开 → 安装

### 优点
- 完全在手机上操作
- 不需要电脑
- 改代码后直接重新编译

### 缺点
- 手机编译较慢
- 需要安装较多工具
- 占用手机存储空间

---

## 安装后使用

1. **先启动爱思助手**（让它在后台运行）
2. 打开 **AisiSpy**
3. 确认顶部显示「运行中」+ PID号
4. 点 **「注入监视」**
5. 等待「注入成功」提示
6. 下方实时日志会开始滚动
7. 点 **「查看完整日志」** 看全部输出

### 会看到的日志

```
[反调试] ptrace已内存patch为直接返回0
[AddLibPath] /var/mobile/Library/Caches/Libraries/
[OpenHandle] PxExtFFi.bin -> 0x... (成功)
[GetExport] PxLib_start_PxExtFFi -> 0x...
[骨骼线] (150.0, 300.0)
[FOV圆圈] 中心=(200,400) 半径=90.0
[UIColor] RGBA=(255,0,0,1.00)
[UILabel] "敌人 15m"
```

### 日志文件位置
- `/var/mobile/Documents/aisi_monitor.log` — Tweak日志
- `/var/mobile/Documents/aisi_helper.log` — helper日志

---

## Root权限说明

AisiSpy的root权限来自：
1. `aisi_helper` 二进制设置了 `setuid 0` (chmod 6755)
2. TrollStore安装时保留setuid位（普通App Store安装会清除）
3. entitlements中设置了 `platform-application` 和 `task_for_pid-allow`
4. 运行时helper以root身份执行，可以 `task_for_pid` 任意进程

**验证root权限**: 安装后打开AisiSpy，点「模块列表」，如果能列出爱思助手的所有dylib，说明root权限正常。
