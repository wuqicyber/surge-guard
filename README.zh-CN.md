# Surge Guard

同一公开仓库管理三个组件：系统级网络门禁 `surge-guard`、用户级应用启动与恢复服务
`surge-gate`、SwiftBar 菜单。Swift 实现，无第三方运行时依赖。

默认行为是“Surge 增强模式就绪才允许普通联网”；也可配置“增强模式就绪，且指定域名
分流到指定策略组和允许节点才放行”。域名、策略组、节点和应用列表都属于本机配置，
公共代码不绑定某个用户、服务或网络。

Surge 增强模式接管正常应用流量，再按其规则代理或 DIRECT。本工具检查接管就绪并控制
PF；它仍是实验性外部门禁，不能证明每个数据包都不可绕过，也不能保证开机最早阶段或
守护被强杀时零泄漏。完整命令与协议以 [README.md](README.md) 为准。

## Agent 从这里开始

1. 阅读 README 和 `AGENTS.md`，先检查已有安装、配置、服务和日志。
2. 构建并执行只读检查。`check` 成功只代表条件通过，不代表 PF 已运行。
3. 为目标机器准备明确的配置，先验证，再安装。
4. 先安装并确认 SwiftBar 离线恢复入口可用，再更新系统守护；确认系统状态后安装 SurgeGate。
5. 排障从 `doctor`、最近日志和具体原因开始；实机验收单独记录，不用构建成功代替。

不要将本机配置、Surge profile、订阅、节点凭据、原始日志或诊断包提交到 GitHub。

## 构建与只读检查

需要 macOS 13+、Swift 5.9+ / Xcode Command Line Tools，以及 Network Extension 版本的
Surge Mac 增强模式。分流检查需要支持 `rule explain` 的 Surge CLI（Mac 6.9+）。

```sh
scripts/check.sh
.build/release/surge-guard check --json
.build/release/surge-guard status --json
```

构建会产生两个程序。未安装新版守护时，`status` 显示未知是合理结果。
检查脚本不加载防火墙、不退出应用，也不安装任何服务。

## 配置联网条件

仅检查增强模式，沿用原有行为：

```json
{"version":1,"mode":"enhanced","route_checks":[]}
```

默认必须通过六项：Surge 官方签名进程、主服务属于 Surge、扩展已连接、VIF 已启用且地址
正确、IPv4 默认路由指向 VIF、没有冲突的全局 IPv6 主接口。不固定 utun 编号。

需要分流条件时，复制通用示例，填写目标机器上的真实值：

```sh
cp examples/routes.json policy.local.json
.build/release/surge-guard validate policy.local.json
.build/release/surge-guard check --config policy.local.json --json
```

```json
{
  "version": 1,
  "mode": "routes",
  "route_checks": [
    {
      "url": "https://example.com",
      "required_group": "Residential",
      "allowed_final_policies": ["Residential A", "Residential B"]
    }
  ]
}
```

`routes` 模式要求增强模式就绪、当前为 Rule 模式、所有 URL 检查均通过。
策略组名称精确匹配，并解析到白名单中的最终代理，支持嵌套组。
DIRECT/REJECT、错误节点、空白名单、无效配置、查询失败或过期都不放行。
不会根据名称中“包含美国”等文字猜测节点属性，也不进行出口 IP 或网站连通性探测。
配置 URL 使用默认请求上下文；实际应用的进程、协议或 URL 特定规则可能影响结果。

本机策略和状态文件可供普通用户读取，禁止在 URL、查询参数或策略名称中放入秘密。
最多八条检查，未知配置字段会被拒绝。

## 安装／升级系统守护

在本机操作。**先以普通用户安装离线恢复组件，确认菜单可用，再改系统守护：**

```sh
scripts/install-user.sh --recovery-only
```

已有控制中心时，按下文接入 `surge-guard-menu --section`；独立菜单则将
`integrations/swiftbar/surge-guard.5s.sh` 复制到 SwiftBar 插件目录。
确认“恢复与备份（离线可用）”已显示。该入口兼容旧版守护，网络断开时仍可用。
同时离线保留恢复命令：

```sh
sudo /Library/PrivilegedHelperTools/surge-guard unlock
```

```sh
sudo .build/release/surge-guard configure policy.local.json
sudo .build/release/surge-guard install
```

首次不执行 `configure` 时生成 enhanced 配置；升级保留已有配置。
全新安装还需要启动：

```sh
sudo /Library/PrivilegedHelperTools/surge-guard start
/Library/PrivilegedHelperTools/surge-guard status --json
sudo /Library/PrivilegedHelperTools/surge-guard doctor
```

升级已运行服务前自动保存 root 专用备份，再正常停止旧服务，**等待防火墙锁实际释放**，
最多 20 秒。`bootout` 返回不代表旧进程已经退出。之后原子替换、启动，并等待新 PF 状态验证；
升级前就绪时，须重新达到放行。失败自动尝试恢复上一版文件并重启，恢复成功也会明确报告升级失败。
不需要先 unlock。
分流模式升级会在停止旧服务前，先用暂存的新程序验证用户会话查询通路；预检失败就中止升级，
因此升级时保持 Surge 运行。此预检不修改 PF。
可能短暂中断已有连接；若自动恢复也失败，使用菜单中的“应急解除阻断”。
系统守护以 root 运行，但执行用户所有的 Surge CLI 前，会进入登录用户会话并降低权限。

“恢复与备份”提供：正常重启并等待验证、启动／恢复保护、备份当前版本与配置、恢复上一版、
恢复上一次规则，以及应急解除阻断。管理员操作在终端显示影响、授权和结果，不再使用
`kickstart -k` 强杀。应急入口独立于守护程序和策略，先等待旧 PID 退出，再清除此工具的
anchor；不会全局关闭 PF。**应急解除会关闭本工具的保护，启动守护或下次开机才恢复。**

```sh
sudo /Library/PrivilegedHelperTools/surge-guard backup
sudo /Library/PrivilegedHelperTools/surge-guard rollback
sudo /Library/PrivilegedHelperTools/surge-guard restore-policy
```

系统备份位于 `/private/var/db/surge-guard/backups/<id>`，仅 root 可读。
升级／手工备份与规则变更前的备份分开保存，保留历史，不整份覆盖其他服务修改过的 `pf.conf`。
恢复旧版可能减少保护条件，尤其旧版仅检查增强模式，需明确核对。首次安装没有上一版可恢复。

## 安装 SurgeGate 和 SwiftBar

新版系统守护安装完成后，以普通用户执行：

```sh
scripts/install-user.sh
```

自动读取 SwiftBar 插件目录，也可显式传入目录。已有单一控制中心时使用：

```sh
scripts/install-user.sh --menu-only
```

再将控制中心中旧的 Surge 渲染逻辑替换为：

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-menu" --section
```

菜单区分放行、阻断、手动解除、停止和未知；展示检查时间、规则结果、具体原因、SurgeGate
状态，并提供日志、诊断、规则草稿、重启和临时恢复入口。采用系统文字颜色和明暗双配色。
显示名为 `SurgeGuard`。SurgeGate 只有在服务运行、状态新鲜、已就绪、无待恢复应用且系统门禁
已验证放行时才显示绿色；等待／过期为橙色，错误为红色。

SurgeGate 本轮已改为同包 Swift 程序，无需 Python。它只相信近期有效的系统守护状态，
不会使用“代理端口通＋任意 utun”的备用判定。启动 Surge 后等待就绪，不自动更改增强模式偏好或分流选择。

应用设置位于 `~/Library/Application Support/SurgeGuard/gate.json`，参照 `examples/gate.json`：

- `startup_apps`：每次就绪后启动的应用 Bundle ID。
- `priority_order`：恢复／启动的优先顺序。
- `excluded_apps`：不参与会话恢复和有序退出的应用。
- `restore_session`：是否恢复上次应用列表。
- `delay_between_apps_seconds`：成功启动间隔，0–30 秒。
- `quit_timeout_seconds`：正常退出等待时间，5–300 秒，超时中止关机。

应用必须用 Bundle ID，避免中英文名称差异。失败应用保留待重试，不直接丢弃。
每 30 秒原子保存一次应用列表和待恢复项，断电时尽量恢复最近记录；不能保证最后一次落盘之后
的变化，也不负责恢复应用文档或窗口。其他登录项仍可能自行启动，流量阻断由系统守护负责。

安装时迁移 `~/.surge_gate` 中可识别的旧配置／会话，保留原文件；停用旧登录任务并将旧 plist
改名保存。无法识别的应用名称写入迁移日志，供手动补全。

## 有序关机／重启

SwiftBar → **SurgeGate** 菜单最上方是电源操作：蓝色“有序重启电脑”和红色“有序关机”；
下方分隔线之后是日志和服务管理。

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" shutdown --action restart
# 或 --action shutdown
```

请求交由独立的用户服务处理，退出调用终端不会截断流程。
先保存会话，正常请求应用退出，确认后最后退出 Surge，验证 PF 已阻断，再请求 macOS 关机。
有未保存内容时由应用显示正常提示，拒绝／超时就中止；不使用 SIGKILL、宽泛 pkill，
也不修改系统全局恢复设置。最后一步可能需要系统自动化权限。
它不拦截所有 Apple 菜单关机、断电或内核故障。

关机后再开机，系统级守护由 LaunchDaemon 自动加载；登录用户账户后，SurgeGate 的
`RunAtLoad`／`KeepAlive` LaunchAgent 自动运行，启动 Surge，等待系统门禁放行后恢复应用。
其他登录项可能自行启动，其网络由系统守护控制。断电恢复基于最近一次约 30 秒间隔的应用快照，
应用文档／窗口恢复由各应用负责；开机最早阶段的限制仍见 README 的 Limits。

## 排查与管理

```sh
/Library/PrivilegedHelperTools/surge-guard doctor
sudo /Library/PrivilegedHelperTools/surge-guard doctor
sudo /Library/PrivilegedHelperTools/surge-guard logs
sudo /Library/PrivilegedHelperTools/surge-guard logs --follow
# agent 或脚本需要原始结构时：
sudo /Library/PrivilegedHelperTools/surge-guard logs --json
```

普通用户诊断无需授权；sudo doctor 增加实时 PF 检查。
日志默认按本地时间、级别、放行／阻断结果、中文原因、预期和实际策略、最终节点分行显示，
先显示最近 200 条，再按需持续跟踪。`--json` 保留供 agent 读取的 JSON Lines。
`status --json` 正常生成报告时退出码为 0，要读取 `state`，不能只看退出码。
`check --json` 的退出码 0 表示条件通过，1 表示未通过／错误。
JSON 使用 snake_case，状态有 allowed、blocked、unlocked、stopped、unknown。

状态绑定本次开机和 PID，检查及 PF 审计超过 8 秒过期；分流结果从查询开始计时，3 秒过期。
守护约每 0.5 秒检查增强模式、1 秒查询分流、5 秒审计 PF；这些不是断网延迟上限。
日志包含状态变化、策略变化、查询错误、配置加载和管理操作，1 MiB 轮转。
系统私有日志保留 root 权限，不为了菜单展示放宽访问。

[故障排查](docs/troubleshooting.md)提供按原因定位的步骤；
[实机验收](docs/acceptance.md)区分新增连接、已有连接、IPv6、重启和睡眠唤醒；
[验证记录](docs/verification.md)只记录实际完成的项目。

## 卸载与保留数据

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" uninstall
sudo /Library/PrivilegedHelperTools/surge-guard uninstall
```

再移除独立 SwiftBar 插件或组合菜单中的调用。卸载保留配置、会话、日志与原始 PF 备份，
只删除自己的 PF 配置段，不覆盖其他服务的配置。

此项目与 Surge 官方无关联，MIT 许可证。
