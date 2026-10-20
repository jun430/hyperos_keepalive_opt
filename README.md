# 澎湃内存管理优化（hyperos_keepalive_opt）

> HyperOS3 后台保活模块：不滥杀后台、内存留得住、游戏自动腾内存，CPU 开销近乎为零。

| 项 | 内容 |
|---|---|
| 版本 | 2.0.0 |
| 作者 | 雨色 |
| 适用 | HyperOS3（红米 K100 Pro Max / M098FE / 内核 6.12.69） |
| 管理器 | KernelSU / Magisk / APatch |
| 依赖 | 无，纯 shell 实现 |

---

## 原理

后台保活差的根因不是 zram，而是 lmkd 判定前存在 **四层预判性主动回收**（mimd / mi_reclaim / unfairmem / memory_standard），内存没到阈值就提前杀后台。本模块关掉这四层，让后台只在真正内存不足时才被回收。

## 功能

| 功能 | 说明 |
|---|---|
| 关闭主动回收 | 停掉四层预判回收（保活核心） |
| lmkd 保守化 | 三档阈值可调，只杀缓存进程 |
| 内存水位控制 | 到目标水位才清缓存，含迟滞 |
| 游戏模式 | 游戏前台自动清缓存后台 + 清文件缓存 |
| 后台保活白名单 | 复用小米「锁后台」，永不杀但可清缓存 |
| WebUI | 液态玻璃外观，全中文参数，图形配置 |
| 中文日志 | 分级 + 心跳，256KB 轮转 |

## 安装

刷入时**音量上键** = 完整安装（禁用四层回收），**下键** = 轻量安装，10 秒无操作默认完整。安装即生成默认配置。

## 推荐配置

| 项 | 值 | 说明 |
|---|---|---|
| lmkd 轻微 / 中等 / 严重 | 1001 / 960 / 930 | 轻微压力不杀，中等起只杀缓存 |
| 水位 / 迟滞 / 清理级别 | 85 / 3 / 1 | 85% 才清缓存，只清文件缓存 |

数值越大越不杀后台；要最强保活用上表。

## 文件结构

```
├── module.prop / system.prop
├── customize.sh      # 音量键安装交互
├── service.sh        # 开机兜底 + 拉 daemon
├── daemon.sh         # 主循环（水位 + 游戏 + 心跳）
├── proc_monitor.sh   # 游戏事件监听
├── lib.sh / action.sh / uninstall.sh
├── config/           # default.conf / games.conf(53包名) / keep.conf
└── webroot/index.html  # WebUI
```

## 注意

- 不碰 CPU 调度 / governor / 频率。
- zram 接管默认关闭，与 `scene_swap_controller` 二选一。
- 卸载用 `uninstall.sh` 一键还原。

---

本项目仅用于自有设备优化。作者：雨色。