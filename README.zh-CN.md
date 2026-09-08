# Surge Guard

macOS 上的 Surge 自动断网工具：**Surge 正在运行且增强模式实际就绪时允许联网，否则阻断普通网络流量。**

这是独立开源项目，与 Surge 官方无关联。Swift 实现，无第三方运行时依赖，不读取节点、订阅或 Surge 配置文件。支持保留现有分流和 `DIRECT` 策略。

**当前为实验版本。它是基于状态检测的自动断网工具，不能保证开机全程、状态切换瞬间或守护进程被强制结束时零数据包泄漏。** 已通过的单元测试和 PF 语法检查不等于真实断网验收。请参阅下文限制和[实机验收步骤](docs/acceptance.md)。

## 工作方式

系统服务独立于 Surge 常驻，由 macOS `launchd` 管理；只有以下五项全部满足才放行：

1. 存在代码签名属于 Surge 官方的主进程。
2. 当前主网络服务属于 Surge 的 Network Extension。
3. 该扩展状态为已连接。
4. 对应 `utun` 网卡处于启用状态，并具有 Surge 的 `198.18.0.1` 地址。
5. 当前 IPv4 默认路由指向该网卡。

不固定 `utun9` 等接口编号，也不按 VPN 显示名称识别，因此其他 VPN 在线不等于 Surge 就绪。网络变化触发检查，另有每 0.5 秒的定时复核；实际响应还包含系统调度和防火墙执行时间。

阻断时同时处理 IPv4/IPv6、普通入站/出站流量，并清除涉及本机地址的既有 PF 连接状态。保留 `localhost`、DHCP 和必要的 IPv6 本地链路配置，不关闭 Wi-Fi 或网卡。互联网、普通局域网访问及其他 VPN 不能作为有意放行的备用出口。

就绪后只撤销本工具的阻断，保留现有网络行为。**这并不证明所有应用请求都必定经过 Surge**：Surge 的排除路由、其他 VPN 路由和物理网卡绑定仍按现有设置工作。它实现“Surge 就绪才允许联网”，不是“每个数据包必须代理”的强制隔离。

## 编译与只读检查

需要 macOS 13+、Swift 5.9+（Xcode Command Line Tools）和使用 Network Extension 的 Surge Mac 增强模式。单独 Gateway VM 不满足条件。

```sh
swift run surge-guard-tests
swift build -c release --product surge-guard
.build/release/surge-guard check
.build/release/surge-guard rules
```

测试不加载防火墙、不退出 Surge。`check` 只显示 Surge 就绪状态，退出码 0 表示就绪，1 表示未就绪；不代表 PF 防护已启动。

## 安装与启用

保持本机终端可用，先离线保存恢复命令：

```sh
sudo /Library/PrivilegedHelperTools/surge-guard unlock
```

在项目目录运行：

```sh
sudo .build/release/surge-guard install
sudo /Library/PrivilegedHelperTools/surge-guard start
sudo /Library/PrivilegedHelperTools/surge-guard status
```

安装会写入 root 所有的程序、LaunchDaemon、默认阻断规则，并在 `/etc/pf.conf` 添加标记清晰的独立 anchor。原配置备份至 `/private/etc/pf.conf.surge-guard.backup`。安装阶段不修改运行中的 PF，但安装好的服务会在下次开机加载。

首次启动需要将 anchor 接入运行中的 PF，可能重载主配置。已有自定义 PF 规则需要先检查；正常运行只维护本工具的 anchor。启动时会短暂阻断并重建连接，SSH、下载和远程桌面可能中断，建议在本机操作。

## 恢复与卸载

```sh
# 临时解除：停止服务，清除自己的规则，释放自己的 PF 引用。
sudo /Library/PrivilegedHelperTools/surge-guard unlock

# 永久卸载：删除程序、系统服务、anchor 和精确匹配的配置段。
sudo /Library/PrivilegedHelperTools/surge-guard uninstall
```

`unlock` 后重新 `start` 或重启会重新启用。`uninstall` 不恢复整份旧备份，以保留你后来对 PF 的修改；原始备份和无活动作用的运行目录会保留。

如果程序不可用，在本机终端依次执行：

```sh
sudo launchctl bootout system/io.github.surge-guard
sudo pfctl -a io.github.surge-guard -F rules
```

第一条提示找不到服务时可以继续第二条；其他错误应先解决，避免仍在运行的服务重新阻断。紧急恢复不会关闭整个 PF，也不会清空其他应用的规则。

## 需要了解的限制

- 检测和防火墙更新之间存在时间窗口；0.5 秒不是延迟上限。
- `RunAtLoad` 不能保证早于开机阶段的所有网络请求，PF 规则在启用和加载前不起作用。
- 放行时守护进程被 `SIGKILL`、卡死或无法被系统重启，可能维持放行。普通退出清理无法覆盖这些情况。
- “就绪”指本地增强模式接管已建立，不是所有网站或代理节点都可访问；避免依赖外网探测造成恢复死锁。
- 阻断时有明确的本地链路配置例外，不是物理链路上一包不发。
- Apple 不将第三方 PF/路由修改视为稳定的 VPN 集成接口；升级 macOS、Surge 或其他网络软件后需要复测。
- 此项目不用于防御 root 权限恶意程序，也未完成实机重启、睡眠唤醒及全协议防泄漏认证。

当前应按实验性自动断网工具评估。严格的永不直连保证需要 VPN/网络过滤架构本身持续执行限制，无法由一个外部状态监听程序补上。

[英文文档](README.md)包含实现、命令和参考项目；[实机验收](docs/acceptance.md)区分新连接、既有连接、IPv4/IPv6、恢复和开机状态。MIT 许可证，代码为独立实现，未复制参考项目源码。
