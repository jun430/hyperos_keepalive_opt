# 澎湃内存管理优化（hyperos_keepalive_opt）

> 面向 HyperOS3 / 澎湃 OS 的 KernelSU 内存管理模块 —— 不滥杀后台、内存占用控制在合理区间、游戏时自动腾内存，CPU 开销近乎为零。

| 项 | 内容 |
|---|---|
| 模块 ID | `hyperos_keepalive_opt` |
| 版本 | 2.0.0 |
| 作者 | 雨色 |
| 适用 | HyperOS3（实测机型：红米 K100 Pro Max / M098FE / 内核 6.12.69-android16） |
| 管理器 | KernelSU / Magisk / APatch（`resetprop` 兼容） |
| 依赖 | 无需任何附加框架，纯 shell 实现 |

---

## 一、它解决什么问题

HyperOS3 后台保活差的**真正根因**不是 zram 或 swappiness，而是 lmkd 判定之前存在 **四层「预判性主动回收」**——内存还没到阈值，系统就提前杀后台：

| 机制 | 实测状态 | 模块处理方式 |
|---|---|---|
| `mimd-service2_0` 内存守护 | running，reclaim.enable=true | `stop` + mimdtrigger 置 -1 |
| `mi_reclaim` 内核回收 | enable_flags=0x3（全开） | `echo "enable 0" > info` |
| `unfairmem` 不公平回收 | unfairMemory.enable=true | resetprop 关 |
| `memory_standard` app 堆限制 | enable=true | resetprop 关 |

关掉这四层后，后台进程只在 lmkd 判定「真正内存不足」时才被回收，保活能力显著提升。

---

## 二、功能清单（M1 ~ M10）

| 编号 | 功能 | 说明 |
|---|---|---|
| M1 | 关闭四层主动回收 | 保活核心，装完即关（可独立开关） |
| M2 | lmkd 保守化 | 三档阈值可调，默认只杀缓存进程 |
| M3 | 内存水位控制 | 内存到目标水位才清缓存，含迟滞避免反复清理 |
| M4 | 游戏模式 | 游戏前台自动清理无关缓存后台 + 清文件缓存 |
| M5 | zram 可选接管 | 默认关闭，与 Scene 交换控制器二选一 |
| M6 | 中文日志 | INF/WRN/ERR/GAME/MEM/RECLAIM/KEEP 分级，256KB 轮转 |
| M7 | WebUI 图形配置 | 液态玻璃外观，跟随系统主题，全部参数可视化 |
| M8 | daemon 守护 | 事件驱动 + 惰性轮询（常态 10s / 游戏 3s） |
| M9 | 卸载回滚 | uninstall.sh 一键还原 |
| M10 | 后台保活白名单 | 复用小米「锁后台」机制，永不杀但可清缓存 |

---

## 三、安装

### 音量键选择安装（customize.sh）

刷入模块时：

- **音量上键** = 完整安装 → 立即禁用四层主动回收（装完重启生效）
- **音量下键** = 轻量安装 → 不碰系统回收行为，仅装配置与 WebUI
- **10 秒无操作** = 默认完整安装

安装时**立即生成**打包好的默认配置（`hkom.conf` / `games.conf` / `keep.conf`），无需等开机。

---

## 四、WebUI 配置说明

在 KernelSU 管理器 → 模块 → 打开 WebUI，参数全部中文标注：

### lmkd 阈值（三档必须满足：轻微 ≥ 中等 ≥ 严重）

| 档位 | 推荐值 | 含义 |
|---|---|---|
| 轻微压力 | 1001 | 不杀任何进程（1001 为哨兵值） |
| 中等压力 | 960 | 只杀 adj≥960 的纯缓存进程 |
| 严重压力 | 930 | 最后防线也只杀缓存进程 |

> 数值越大越「不杀」。要最强保活：`1001 / 960 / 930`。

### 内存水位

| 项 | 推荐值 | 说明 |
|---|---|---|
| 目标占用水位 | 85 | 内存占到 85% 才开始清缓存 |
| 迟滞区间 | 3 | 降到 82% 就停止，减少反复清理 |
| 清理级别 | 1 | 只清文件缓存（最温和、开销最小） |

### 后台保活白名单

默认含微信 / QQ / 百度输入法 / 讯飞输入法，写入系统 `locked_apps`（小米「锁后台」）。
**合并逻辑**：不会覆盖你已锁定的其它 App，只做去重叠加。

### 游戏白名单

默认 53 个主流大厂手游包名（来源 HyperOS 内置 `GamePowerOptFeature.xml` + 标准包名），
游戏页默认收起，点「展开全部」查看完整列表，可增删。

---

## 五、CPU 开销

daemon 每 10 秒读一次 `/proc/meminfo`（微秒级）+ 偶尔一次 `drop_caches`（毫秒级）。
**总体开销基本为零**，无感知。事件驱动 + 惰性轮询，不扫 `/proc`，不轮询游戏。

---

## 六、文件结构

```
源码/
├── module.prop          # 模块元信息
├── system.prop          # 系统属性
├── customize.sh         # 音量键安装交互
├── post-fs-data.sh      # 早期初始化
├── service.sh           # 开机延迟执行（兜底关回收 + 拉 daemon）
├── uninstall.sh         # 卸载回滚
├── lib.sh               # 共享函数库（配置/日志/快照/动作）
├── action.sh            # 动作执行器（WebUI / daemon 调用）
├── daemon.sh            # 主循环（水位判定 + 游戏模式 + 心跳）
├── proc_monitor.sh      # 游戏事件监听（am_proc_start）
├── config/
│   ├── default.conf     # 默认配置模板
│   ├── games.conf       # 游戏白名单（53 包名）
│   └── keep.conf        # 后台保活白名单
└── webroot/
    └── index.html       # WebUI（液态玻璃，跟随系统主题）
```

---

## 七、注意事项

1. **不碰 CPU 调度 / governor / 频率 / cpuset**，与调度类模块无冲突。
2. **zram 接管默认关闭**，与 `scene_swap_controller` 职责分离，二选一，勿同时抢写。
3. `swappiness` 仅在 `zram_takeover=1` 时生效，默认交给系统/Scene 管理。
4. 游戏检测基于 `am_proc_start` 事件 + 进程存活复核，白名单用精确整行匹配。
5. 卸载前建议先在 WebUI 记录当前配置，`uninstall.sh` 会还原系统回收开关。

---

## 八、许可证

本项目仅用于自有设备的内存管理优化。作者：雨色。
