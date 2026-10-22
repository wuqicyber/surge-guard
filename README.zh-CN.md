# Surge Guard

同一公开仓库管理三个组件：系统级网络门禁 `surge-guard`、用户级应用启动与恢复服务
`surge-gate`、SwiftBar 菜单。Swift 实现，无第三方运行时依赖。

默认行为是“Surge 增强模式就绪才允许普通联网”；也可配置“增强模式就绪，且指定域名
分流到指定策略组和允许节点才放行”。域名、策略组、节点和应用列表都属于本机配置，
公共代码不绑定某个用户、服务或网络。

Surge 增强模式接管正常应用流量，再按其规则代理或 DIRECT。本工具检查接管就绪并控制
PF；它仍是实验性外部门禁，不能证明每个数据包都不可绕过，也不能保证开机最早阶段或
守护被强杀时零泄漏。完整命令与协议以 [README.md](README.md) 为准。

新版系统守护每 30 秒在后台采样约 1 秒的 socket 活动，记录 nettop 报告的接口、进程、
本地/远端端点及本次字节增量。这些是 socket 计数，并未验证数据包实际路径，不能据此
确认绕过或确认全部经 Surge。仅接收与有发送计数分别标注；UDP 远端通配符保持未知，
不会归为公网。UDP 本地端口 5353 只提示 mDNS 常用端口，不能证明目标或路径。
系统扩展、局域网/保留地址和未知远端分别标注，不会自动批准独立网络，也不修改 PF。
重复证据五分钟内去重；同一 socket 从仅接收转为有发送，或 PF 批次/状态变化后，会重新记录。
公网发送线索优先保留。采样记录关联开始、结束门禁状态；期间发生切换时明确标为混合区间，
不会把整段字节按结束状态判作已放行或已阻断。手动或旧版记录未跟踪切换时明确显示未知。每次最多记录
20 条新证据，沿用每组件当前/上一份各 1 MiB 的日志轮转。每五分钟保留观测摘要和覆盖缺口，
普通用户 `observe-egress` 的文字与 JSON 输出都使用结构化 `flows[].candidate_domains`，
每条 socket 最多五个去重候选域名；IP 匹配规范化 IPv6 写法及 IPv4-mapped IPv6。
虚拟 IP 同时兼容原始 `d`／整数 `i` 和导出 `domain`／`IP` 格式。
`domain_queries` 分别记录 DNS 与虚拟 IP 查询的 `ok`、`empty`、`failed`（附原始错误）或
`unavailable`；后台守护标为 `not_requested`，root 不执行用户所有的 Surge CLI。
候选域名仅是缓存线索，不是该连接请求域名或实际路径的确认。
采样失败/恢复单独记录。SwiftBar 的“查看连接采样（只读）”可立即查看。
更新用户菜单只增加手动检查；后台持续记录需要安装新版系统守护。

阻断期间约每五秒、准备放行前，读取本工具 PF 阻断规则的计数，记录为 `pf_block_traffic`：
包括本次增量、当前规则累计、入站/出站包数与字节数，以及阻断批次和单调时间边界。
这能说明本规则命中了多少包，但不包含逐包的进程或目标。最后读取到清除规则之间仍可能有
未计入的命中；重载、读取失败或计数回退会明确记录缺口，不能把它们记成零包或无绕过。
不启用抓包、不改变 PF 规则；计数读取失败不改变放行条件，读取后的就绪与分流有效期会重新确认。

采样覆盖不到间隔内的所有短连接，也不具备完整的逐包审计能力；没有记录不代表确认无绕过。
日志保存毫秒时间和单调时钟；Surge 退出事件会记录“收到退出事件到 PF 阻断验证”的耗时，
该数值不等于实际退出至最后一个逃逸数据包的时间，也不承诺固定几十毫秒内完成阻断。

系统守护现在直接订阅已验证的 Surge 网络服务状态，收到“正在断开”等失效状态或进程
退出事件时，先加载阻断规则并清理旧连接状态，再进行其余条件和 PF 完整性检查。
`readiness_loss_blocked` 分别记录事件收到/发现失效、规则加载完成、阻断验证与旧状态
清理完成的时间；重新放行仍须通过全部接管和分流条件。此改动需更新系统守护才会生效。
它仍有事件通知和执行延迟，尚不能保证逐包零绕过。Surge 官方将 `include-all-networks`
列在 iOS 专用参数中，不能据此宣称 Mac 已启用系统级断开保护。

连续包级记录是单独启用的可选组件：使用系统 PKTAP 同时记录物理、隧道及回环接口，
默认 256 MB 环形抓包文件，每包保留前 256 字节及可用元数据，可能含少量应用数据。
同时在降权后的用户会话查询并保存 Surge 请求元数据，不保存 URL 参数、请求头或正文。
采集缺口、丢包、Surge 请求窗口滚动和进程变化会留痕；恢复采集不会清除历史缺口标志。
SwiftBar 单独提供状态、留存时间范围、预览、日志和启停入口，安装它不重启网络守护或修改 PF。
抓包运行与完整归属验证是两件事，未知包不能直接判为绕过；环形覆盖之前的历史不可还原。
详细安装、权限、保留范围和局限见 [包级审计说明](docs/packet-audit.md)。

## 可选的常驻 TCP 限制

可选的常驻 TCP 模式使用 `"persistent_tcp": true`，须先升级系统守护、专用启动器和
SurgeGate，再将该字段加入原配置，保留原有分流条件。省略或设为 `false` 保持响应式
门禁；旧版程序不认识此字段，不能先更新配置再升级。

此模式在放行状态也保留 PF 规则：普通 IPv4 TCP 只允许经已验证的 Surge VIF 和预期
源地址；Surge 专用有效组的 TCP 可以出站；其余非回环 TCP 默认拒绝，包括 IPv6。
UDP 不在此开关的常驻保护范围内，不能据此宣称所有协议零逃逸。
放行连接状态绑定接口，不允许 VIF 状态自动在物理接口匹配。当前版本不提供普通应用
IPv6 的 VIF 例外，也不提供 Tailscale、其他 VPN 或局域网例外。就绪或分流条件失败时，
仍执行原有完整阻断与本机旧连接状态清理。

只要求经过 Surge、允许 Surge 自己决定 DIRECT 或代理时，可明确应用
`examples/persistent-tcp.json`（`enhanced` + `persistent_tcp: true`）。
用户安装器保留现有系统策略、规则草稿和更新暂停状态，不静默取消已有分流限制。

更新 Surge 前，在菜单点“准备更新 Surge”，等 Gate 确认暂停后再启动官方更新。
暂停自动启动、身份修复和应用恢复；当前 Surge 不被该按钮退出，Guard/PF 独立运行。
更新完成或取消后点“恢复自动启动”。更新卡住不会自动解除保护、强杀更新器或自动恢复。
需要在 Surge 退出后联网的安装流程，应先在 Surge 正常时下载完整安装包。

暂停保存在私有 `update-mode.json`，跨 Gate 重启和电脑重启保留；损坏或读失败时暂停
自动操作并报告错误。确认超时仍保留请求，不能开始更新。已有退出/启动操作须完成后才
确认暂停；暂停期间拒绝有序关机请求。启动超时不会取消 NSWorkspace 请求或专用启动器，
`pending-launch.json` 记录发起请求的 Gate 实例，以及专用启动器的 PID 和出生时间。
Gate 重启后，确认应用启动即可结束等待；已记录的启动器退出或 PID 被复用时，按失败处理并
退避 30 秒后恢复。仍存活的启动器或尚未结束的回调继续阻止暂停确认。

若 Gate 在保存子进程身份之前崩溃，或丢失了 NSWorkspace 回调，仅凭应用没有出现无法确认
请求已取消。Gate 会显示 `launch_recovery_required`，给出应用和请求 ID。独立确认旧启动
已完成、失败或取消后，可用普通用户运行：

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" status --json
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" recover-launch REQUEST_UUID --confirm-settled
```

将 `REQUEST_UUID` 换成新鲜状态中的 `pending_launch.id`。该命令依赖你的明确确认，只清除
对应的孤立请求，不会取消 LaunchServices 操作，也不会解除已有更新暂停。恢复与关机消费共用
请求锁；若取得锁时启动记录已经变化，会重新观察后再处理关机请求。无法确认时须继续
等待或重启电脑，使旧 boot 请求失效；超时和手工删除标记都不代表启动已取消。
有序关机会明确拒绝未决启动；已经排队的关机请求也会被消费并拒绝，不要求应用退出，避免
以后恢复启动时意外执行旧关机请求。若服务启动失败且请求尚未消费，则按 nonce 撤回，允许
重试；已消费的请求须查状态和日志确认结果。Gate 配置、会话和状态文件实行大小上限，拒绝
符号链接及特殊文件，要求当前用户属主且无组或其他用户访问权限（通常为 `0600`）。
配置中每个应用列表最多 256 个 Bundle ID，每个最多 255 个 ASCII 字符；`gate.json`
上限为 256 KiB。会话中的每个列表最多 1024 个 ID，允许启动列表与保存列表合并，
不静默截断；会话与 Gate 状态读取上限为 1 MiB。每次保存前按读取规则验证，超限时
报错并保留旧检查点。读取上限更小的旧版 Gate 无法读取这种较大的新检查点。

真实恢复失败执行 30 秒退避；单纯等待 Guard
确认阻断不占用退避。每次身份修复只发送一次正常退出请求，不强制终止。
`surge-gate 命令 --help`（或 `-h`）只显示帮助；未知、重复或多余参数会在取得管理锁、
执行服务操作之前被拒绝。

安装器创建无普通成员的 `_surge_guard` 组，并安装 root 所有、模式为 `2755` 的固定
`surge-guard-launch`。它设置专用 real/effective GID，不赋予 root 用户身份；验证官方 Surge 签名后执行固定路径。普通用户执行该启动器的 `--check` 可以只读核对 UID/GID 和签名。
启动器以不跟随符号链接的方式打开各级目录和可执行文件，在签名验证前后对照
`fstat` / `lstat` 等价信息中的设备、inode、属主、权限、大小及修改时间，发现替换或修改就拒绝启动。
`/Applications/Surge.app` 保留普通用户属主及原有可写权限，以兼容应用内 Sparkle 自动更新。
这些检查缩小了竞态窗口，但签名验证与按路径 `execve` 仍非原子操作；最后一次检查至执行的
窗口，以及同用户恶意进程对应用包的写入，不属于当前启动器能完全防御的边界。
SurgeGate 会在确认阻断后，以正常退出方式纠正 Surge 的错误启动身份，再调用启动器；
退出被拒绝或超时就保持错误状态，不强制终止，也不退回普通身份放行。

目前专用启动器只控制经过它的启动，不能强制 Finder、Dock 或更新器独立启动的实例
从第一刻就使用专用组。检测后重启属于恢复机制；若要求所有入口、包括更新后的第一次
启动都具有该身份，还需要安装或执行前的控制，不能宣称当前实现已经满足。

状态 JSON 的 `enforcement` 应为 `persistent_tcp_egress`，放行时自身 anchor 不应为空。
守护卡住时已有规则继续保留，但状态应正常过期；开机最早阶段、接口重用、系统更新和
管理员修改 PF 等边界仍须单独验收，不能把规则存在或编译成功当成零逃逸证明。
详见 [验收步骤](docs/acceptance.md) 和 [实测记录](docs/verification.md)。

## Agent 从这里开始

1. 阅读 README 和 `AGENTS.md`，先检查已有安装、配置、服务和日志。
2. 构建并执行只读检查。`check` 成功只代表条件通过，不代表 PF 已运行。
3. 为目标机器准备明确的配置，先验证，再安装。
4. 先安装并确认 SwiftBar 离线恢复入口可用，再更新系统守护；确认系统状态后安装 SurgeGate。
5. 排障从 `doctor`、最近日志和具体原因开始；实机验收单独记录，不用构建成功代替。

### Agent 快速索引（组件职责、路径与常用操作）

| 组件 | 可执行文件 / Launchd 标签 | 状态与配置文件 | 常用命令与应急操作 |
| --- | --- | --- | --- |
| **surge-guard**（Root 防火墙门禁） | `/Library/PrivilegedHelperTools/surge-guard`<br>`system/io.github.surge-guard` | 策略：`/Library/Application Support/SurgeGuard/policy.json`<br>状态：`/Library/Application Support/SurgeGuard/status.json`<br>日志：`/private/var/db/surge-guard/events.log` | **应急暂停保护并放行网络**：`sudo /Library/PrivilegedHelperTools/surge-guard unlock`<br>**重新启用保护**：`sudo /Library/PrivilegedHelperTools/surge-guard start`<br>**只读查看非 Surge 连接与候选域名**：`surge-guard observe-egress` |
| **surge-guard-launch**（专用组启动器） | `/Library/PrivilegedHelperTools/surge-guard-launch`（`root:_surge_guard`，权限 `2755`） | 专用组记录：`/private/var/db/surge-guard/egress-group.json`（GID `60000...60999`） | **只读校验 UID/GID 与 Surge 签名**：`/Library/PrivilegedHelperTools/surge-guard-launch --check` |
| **surge-gate**（用户态伴随服务） | `~/Library/Application Support/SurgeGuard/bin/surge-gate`<br>`gui/$UID/io.github.surge-guard.gate` | 配置：`~/Library/Application Support/SurgeGuard/gate.json`<br>状态：`~/Library/Application Support/SurgeGuard/gate-status.json`<br>更新模式：`~/Library/Application Support/SurgeGuard/update-mode.json` | **手动退出或升级 Surge 前暂停自动重开**：`surge-gate update-pause`<br>**升级或维护完成后恢复**：`surge-gate update-resume`<br>**停止/启动服务（不影响当前联网与 PF）**：`surge-gate stop` / `surge-gate start`<br>**有序重启/关机（保存会话并安全断网）**：`surge-gate shutdown --action restart\|shutdown` |
| **surge-guard-audit**（按需抓包审计，默认关闭） | `/Library/PrivilegedHelperTools/surge-guard-audit`<br>`system/io.github.surge-guard.audit` | 目录：`/private/var/db/surge-guard/packet-audit/` | **临时开启连续抓包**：`sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-start`<br>**停止抓包并禁用开机自启**：`sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-stop` |

不要将本机配置、Surge profile、订阅、节点凭据、原始日志或诊断包提交到 GitHub。

## 构建与只读检查

需要 macOS 13+、Swift 5.9+ / Xcode Command Line Tools，以及 Network Extension 版本的
Surge Mac 增强模式。分流检查需要支持 `rule explain` 的 Surge CLI（Mac 6.9+）。

```sh
scripts/check.sh
.build/release/surge-guard check --json
.build/release/surge-guard status --json
```

构建会产生 Guard、Gate 和专用组启动器。未安装新版守护时，`status` 显示未知是合理结果。
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
      "required_group": "Residential"
    }
  ]
}
```

`routes` 模式要求增强模式就绪、当前为 Rule 模式、所有 URL 检查均通过。
策略组名称精确匹配并解析到代理，支持嵌套组。省略 `allowed_final_policies` 时，
组内更换代理节点不需要修改门禁配置。如果还要限制最终节点，可以额外填写
`"allowed_final_policies": ["Residential A", "Residential B"]`；已有白名单仍然有效。
显式填写空数组或 null 会被拒绝。两种配置都拒绝 DIRECT/REJECT、错误策略组、无效配置及查询失败／过期；
填写了白名单时，还会拒绝不在名单内的节点。组选择链必须连续、无环并终止于已识别的代理类型；
缺失 selected、未解析组或未知最终类型均保持阻断。
不会根据名称中“包含美国”等文字猜测节点属性，也不进行出口 IP 或网站连通性探测。
配置 URL 使用默认请求上下文；实际应用的进程、协议或 URL 特定规则可能影响结果。

本机策略和状态文件可供普通用户读取，禁止在 URL、查询参数或策略名称中放入秘密。
最多八条检查；未知配置字段、带凭据或包含原始控制字符的 URL 会被拒绝。

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

上面是全新安装的顺序。升级已有守护时，先保留现有策略安装新程序，验证状态，再用新程序应用新策略：

```sh
sudo .build/release/surge-guard install
/Library/PrivilegedHelperTools/surge-guard status --json
sudo /Library/PrivilegedHelperTools/surge-guard configure policy.local.json
```

旧程序要求 `allowed_final_policies` 必填；不要在升级前给旧守护应用省略该字段的新配置，
否则它会按无效配置阻断联网。

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

若系统程序不可用，在本地终端以普通用户运行独立恢复入口：

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-action" unlock
# 已安装入口缺失时，可使用经过审查的仓库副本：
# /bin/bash integrations/swiftbar/surge-guard-action.sh unlock
```

该脚本验证服务状态与 PID，等待旧进程退出并再次确认服务已卸载，再清空自身 anchor。
不能把 `bootout` 返回视为进程退出；查询失败时会中止，不执行清空规则。

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

`--menu-only` 与 `--recovery-only` 都只更新独立菜单文件，不查询或重启 Guard/Gate，
也不替换 Gate 可执行文件。需要安装／升级伴随服务时，另行执行
`.build/release/surge-gate install`，该命令会重启用户服务。
再将控制中心中旧的 Surge 渲染逻辑替换为：

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-menu" --section
```

菜单区分放行、阻断、手动解除、停止和未知；展示检查时间、规则结果、具体原因、SurgeGate
状态，并提供日志、诊断、规则草稿、重启和临时恢复入口。
守护停止不代表遗留 PF 规则已清除；抓包状态缺失、过期或不完整时显示不确定，服务可能仍在运行时
保留停止入口，不推断“已关闭、零内存”。采用系统文字颜色和明暗双配色。
菜单显示名为 `surge-guard` 和 `surge-gate`。surge-gate 只有在服务运行、状态新鲜、已就绪、无待恢复应用且系统门禁
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

请求先在锁内写入，再启动尚未运行的服务，避免服务先恢复应用再看到关机请求；并发请求不会相互覆盖。
服务查询失败按错误处理，不视为“未安装”。请求交由独立的用户服务处理，退出调用终端不会截断流程。
先保存会话，正常请求应用退出，确认后最后退出 Surge，验证 PF 已阻断，再请求 macOS 关机。
有未保存内容时由应用显示正常提示，拒绝／超时就中止；不使用 SIGKILL、宽泛 pkill，
也不修改系统全局恢复设置。最后一步可能需要系统自动化权限。
它不拦截所有 Apple 菜单关机、断电或内核故障。
macOS 接受 Apple event 只表示已提交，系统或其他应用仍可能取消关机。提交后及中止后都保留会话，
暂停快照与自动恢复；可以再次显式发起有序关机／重启，已退出应用仍保留在会话中，
也可重启 Gate 恢复自动运行。应用仍在退出阶段时拒绝重复请求。

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
日志默认按本地时间、级别、放行／阻断结果、中文原因、预期和实际分流组、最终策略分行显示，
先显示最近 200 条，再按需持续跟踪。每条标明 SurgeGuard／SurgeGate、当前状态、原因、影响和恢复进度。
默认省去 PID、run/event 标识和冗长的 OS UserInfo；`--json` 完整保留供 agent 读取的原始 JSON Lines。
SurgeGate 区分“应用原本已运行”和“发送了启动请求”，并分别记录“状态暂不可读”和“状态已恢复”。
一次状态文件读取失败会暂停应用恢复，不能单凭这一条认定整机断网。

SwiftBar 的系统日志入口只用 sudo 读取固定日志文件，再交给普通用户的 `format-logs` 格式化；
旧记录也能按新格式显示，不放宽原日志权限，也不以 root 执行用户目录中的渲染程序。
状态文件先在临时文件上设置好最终权限，再原子替换，消除重写时短暂不可读的权限窗口。
`status --json` 正常生成报告时退出码为 0，要读取 `state`，不能只看退出码。
`check --json` 的退出码 0 表示条件通过，1 表示未通过／错误。
JSON 使用 snake_case，状态有 allowed、blocked、unlocked、stopped、unknown。

状态绑定本次开机和 PID，检查及 PF 审计超过 8 秒过期；分流结果从查询开始计时，3 秒过期。
守护约每 0.5 秒检查增强模式、1 秒查询分流、5 秒审计 PF；这些不是断网延迟上限。
菜单分别显示状态发布的具体时间和 PF 验证距今时间；状态每秒发布，出现“不到 1 秒前”正常。
这些时间是菜单生成时的记录，展开菜单后不会逐秒计时。
日志包含状态变化、策略变化、查询错误、配置加载和管理操作；不为未变化的每次轮询重复写日志。
每个组件只保留当前文件和一份 `.1` 上轮文件，每份最多 1 MiB，即每组件最多 2 MiB。
写入前检查容量并轮转，拒绝超大记录和不安全权限；不会无限保留旧轮次。
SurgeGate 的 launchd 标准输出／错误改为 `/dev/null`，日志写入故障进入 macOS 自行管理的系统日志。
已有 `service.log` 保留但不再写入。
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

## Surge 启动和更新

常驻 TCP 模式固定使用 `_surge_guard` 专用组，重启和更新均沿用原有组 ID，绝不根据当前 Surge 的组身份扩大 PF 放行范围。Surge 保留原安装及更新方式；本工具不修改 Surge.app，不需要 App 管理权限。

Finder、Dock 或更新器可能先启动普通组实例。这个实例没有专用组的对外 TCP 放行资格；SurgeGate 等到系统守护确认阻断后，正常退出它，再通过固定启动器恢复专用组实例。身份错误、退出失败或恢复失败均保持阻断，不提供普通组放行的兜底。

恢复可能造成短暂断网；普通 TCP 出口的阻断规则已常驻 PF，不依赖 Gate 恢复的速度。本方案不保证所有独立启动入口的第一个实例就具有专用组，已执行与未执行的网络验证见 [验证记录](docs/verification.md)。
