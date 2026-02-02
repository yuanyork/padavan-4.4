# 硬件看门狗测试指南

## 📋 测试准备

### 前置要求
1. 已刷入包含硬件看门狗的固件，或已手动编译安装
2. 内核支持MT7621看门狗 (`CONFIG_MT7621_WDT=y`)
3. SSH访问路由器
4. 确保重要数据已备份（某些测试会导致重启）

### 检查设备是否存在
```bash
# SSH登录路由器
ssh root@192.168.1.1

# 检查看门狗设备
ls -l /dev/watchdog
# 预期输出: crw------- 1 root root 10, 130 ...

# 检查内核消息
dmesg | grep -i watchdog
# 预期输出: mt7621-wdt 1e000100.watchdog: ...
```

---

## 🧪 测试方法

我已经创建了一个完整的测试脚本 `test_watchdog.sh`，包含8个测试场景。

### 方法1: 使用测试脚本（推荐）

```bash
# 上传测试脚本到路由器
scp trunk/user/scripts/test_watchdog.sh root@192.168.1.1:/tmp/

# SSH登录并运行
ssh root@192.168.1.1
chmod +x /tmp/test_watchdog.sh
/tmp/test_watchdog.sh
```

测试脚本提供交互式菜单：
```
========================================
Hardware Watchdog Test Suite
========================================
SAFE TESTS:
  1. Check watchdog device exists
  2. Check kernel module
  3. Basic watchdog functionality
  4. Check hw_watchdog daemon
  5. Watchdog feed test (safe)
  8. Monitor watchdog activity

DANGEROUS TESTS (will cause reboot):
  6. Kill daemon test (reboot in ~2min)
  7. Simulate system hang (immediate reboot)

  a. Run all safe tests
  q. Quit
========================================
```

---

### 方法2: 手动测试

#### ✅ 测试1: 验证设备和驱动

```bash
# 检查设备节点
ls -l /dev/watchdog

# 查看内核模块
lsmod | grep watchdog

# 查看内核日志
dmesg | grep watchdog
```

**预期结果:**
```
/dev/watchdog exists (字符设备 10:130)
dmesg显示: mt7621_wdt: Hardware Watchdog Timer
```

---

#### ✅ 测试2: 检查daemon是否运行

```bash
# 检查进程
ps | grep hw_watchdog

# 检查PID文件
cat /var/run/hw_watchdog.pid

# 查看日志
logread | grep hw_watchdog
```

**预期结果:**
```
hw_watchdog进程正在运行
日志显示: "Hardware watchdog daemon started (feed interval: 30s)"
```

---

#### ✅ 测试3: 简单喂狗测试（安全）

```bash
# 创建测试脚本
cat > /tmp/wdt_simple_test.sh << 'EOF'
#!/bin/sh
echo "Opening watchdog..."
exec 3>/dev/watchdog

echo "Feeding watchdog 3 times..."
for i in 1 2 3; do
    echo "Feed #$i at $(date '+%H:%M:%S')"
    echo "1" >&3
    sleep 5
done

echo "Disabling watchdog..."
echo "V" >&3  # Magic character to disable
exec 3>&-
echo "Done - watchdog disabled"
EOF

chmod +x /tmp/wdt_simple_test.sh
/tmp/wdt_simple_test.sh
```

**预期结果:**
```
每5秒喂狗一次
最后成功禁用看门狗
系统不会重启
```

---

#### ⚠️ 测试4: 停止喂狗测试（会重启！）

这是最简单的验证硬件看门狗是否真正工作的方法。

```bash
# 确保hw_watchdog正在运行
ps | grep hw_watchdog

# 记录当前时间
date

# 杀死hw_watchdog进程
killall hw_watchdog

# 观察系统日志（可选）
logread -f &

# 等待重启（约120秒）
echo "System should reboot in ~120 seconds..."
echo "Current time: $(date)"
```

**预期结果:**
```
1. hw_watchdog进程被杀死
2. 看门狗设备仍然打开（active状态）
3. 没有进程喂狗
4. ~120秒后，硬件看门狗触发
5. 路由器硬件复位，自动重启
6. 重启后hw_watchdog自动启动
```

**验证重启:**
```bash
# 重启后SSH重新登录
ssh root@192.168.1.1

# 查看系统运行时间（应该很短）
uptime

# 查看日志中的重启记录
logread | grep -A5 "kernel.*Boot"
```

---

#### ⚠️ 测试5: 模拟系统挂死（会重启！）

这个测试模拟真实的系统挂死场景。

```bash
# 确保hw_watchdog正在运行
ps | grep hw_watchdog

# 方法A: Fork炸弹（填满进程表）
# ⚠️ 这会让系统完全卡死！
echo "Launching fork bomb in 5 seconds..."
sleep 5
:(){ :|:& };:

# 方法B: 内存炸弹（耗尽内存）
# ⚠️ 这会让系统OOM！
while true; do cat /dev/zero | tail; done

# 方法C: 内核panic（如果内核支持）
echo c > /proc/sysrq-trigger
```

**预期结果:**
```
1. 系统变得完全无响应
2. SSH连接断开
3. 无法执行任何命令
4. hw_watchdog无法继续喂狗
5. ~120秒后硬件看门狗触发
6. 路由器强制重启
```

---

#### ✅ 测试6: 监控喂狗活动

这个测试不会导致重启，只是观察喂狗行为。

```bash
# 方法1: 使用strace跟踪系统调用（如果有）
strace -p $(pidof hw_watchdog) 2>&1 | grep -E "write|ioctl"

# 方法2: 监控/proc文件系统
watch -n 1 'cat /proc/$(pidof hw_watchdog)/fd/*'

# 方法3: 检查syslog
logread -f | grep hw_watchdog

# 方法4: 监控设备访问时间
watch -n 1 'ls -l /dev/watchdog'
```

**预期结果:**
```
每30秒看到一次write系统调用到/dev/watchdog
日志中没有错误消息
```

---

## 📊 测试结果判断

### ✅ 成功的标志

1. **设备存在测试**
   - `/dev/watchdog` 字符设备存在
   - dmesg显示mt7621-wdt驱动加载

2. **Daemon运行测试**
   - hw_watchdog进程运行中
   - 日志显示定期喂狗消息

3. **喂狗测试**
   - 能成功打开/写入/关闭设备
   - 使用'V'魔法字符能禁用看门狗

4. **重启测试**
   - 杀死daemon后120秒内系统自动重启
   - 重启后uptime显示刚启动
   - hw_watchdog自动重新启动

### ❌ 失败的情况

1. **设备不存在**
   ```
   原因: 内核未编译看门狗驱动
   解决: 检查kernel config中CONFIG_MT7621_WDT=y
   ```

2. **能打开设备但不重启**
   ```
   原因: 看门狗驱动有问题或硬件不支持
   解决: 检查dmesg错误消息，确认硬件型号
   ```

3. **Daemon启动失败**
   ```
   原因: 权限问题或设备不可用
   解决: 以root运行，检查/dev/watchdog权限
   ```

---

## 🔍 调试技巧

### 查看详细的watchdog信息

```bash
# 使用wdctl工具（如果有）
wdctl

# 读取watchdog信息（某些驱动支持）
cat > /tmp/wdt_info.c << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>

int main() {
    int fd = open("/dev/watchdog", O_RDONLY);
    struct watchdog_info info;

    if (ioctl(fd, WDIOC_GETSUPPORT, &info) == 0) {
        printf("Identity: %s\n", info.identity);
        printf("Firmware: %d\n", info.firmware_version);
        printf("Options: 0x%x\n", info.options);
    }

    int timeout, timeleft;
    if (ioctl(fd, WDIOC_GETTIMEOUT, &timeout) == 0)
        printf("Timeout: %d seconds\n", timeout);

    if (ioctl(fd, WDIOC_GETTIMELEFT, &timeleft) == 0)
        printf("Time left: %d seconds\n", timeleft);

    close(fd);
    return 0;
}
EOF

# 编译并运行（如果有gcc）
gcc -o /tmp/wdt_info /tmp/wdt_info.c
/tmp/wdt_info
```

### 监控内核消息

```bash
# 实时监控内核日志
dmesg -w | grep -i watchdog

# 查看看门狗相关的所有内核消息
dmesg | grep -i -E "watchdog|wdt|timeout"
```

---

## ⚡ 快速验证流程

如果你只想快速验证硬件看门狗是否工作，按以下步骤：

```bash
# 1. SSH登录路由器
ssh root@192.168.1.1

# 2. 检查设备和进程
ls -l /dev/watchdog && ps | grep hw_watchdog

# 3. 记录当前时间
date

# 4. 杀死守护进程
killall hw_watchdog

# 5. 等待2分钟
# 系统应该自动重启

# 6. 重启后重新登录，检查运行时间
ssh root@192.168.1.1
uptime
```

**如果uptime显示系统刚启动（几分钟以内），说明硬件看门狗工作正常！** ✅

---

## 📝 测试记录模板

建议记录测试结果：

```
测试日期: ____________________
固件版本: ____________________
设备型号: ____________________

测试1 - 设备存在: ☐ 通过 ☐ 失败
测试2 - Daemon运行: ☐ 通过 ☐ 失败
测试3 - 喂狗测试: ☐ 通过 ☐ 失败
测试4 - 重启测试: ☐ 通过 ☐ 失败
  - 杀死daemon时间: __________
  - 重启发生时间: __________
  - 实际超时时间: ______秒

备注:
_________________________________
_________________________________
```

---

## 🎯 总结

- **最简单的测试**: `killall hw_watchdog`，等待2分钟看是否重启
- **最安全的测试**: 使用测试脚本的"Run all safe tests"选项
- **最彻底的测试**: 依次运行所有测试项目

测试脚本位置: `trunk/user/scripts/test_watchdog.sh`

记住：任何涉及"重启"的测试都应该在不重要的时间段进行，并确保已保存所有配置！
