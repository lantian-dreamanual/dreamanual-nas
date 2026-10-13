# Dreamanual NAS 助手

连接群晖（Synology）NAS 的 macOS 桌面客户端。以听自己的曲库为主轴，兼顾文件管理与开关机。

> **当前状态：听歌 MVP 已通（2026-10-13）。** 接口可行性已在真实机器上逐条验完（见 [接口结论](docs/接口结论.md)），
> 功能范围已定（见 [产品定义](docs/产品定义.md)），整体界面出了 HTML 原型（[界面原型](design/界面原型.html)）。
> 地基已通：QuickConnect 端点解析、双会话（FileStation + AudioStation）、钥匙串口令、保活重登、
> 外壳（侧栏 + 主区 + 底部播放条）。**曲库页已接数据**：四维浏览 / 搜索 / 筛选 / 分页懒加载，
> 真机 12328 首完整渲染。**播放与队列已接**：取流走自定义 scheme + 资源装载代理（`stream.cgi`
> 要带 `X-SYNO-TOKEN`），真机验证过播放 / 拖进度 / 切歌（`DM_SMOKE=1` 冒烟通路）。
> **内容区侧栏已接**：每日随机 / 全部曲目 / 我的歌单 / 评分 ≥ 4 星（这台库还没评过分，此入口现为空）。
> **评分写入已接**（真机验证过写 5 / 写 3 / 复原 0 三步回读一致）：曲库表 / 队列表 / 播放条三处都能点星，写后回读校验，写失败弹 Toast。
> **封面缩略图已接**（真机验证）：曲库表 / 队列表标题列内嵌 28px、播放条 44px，按专辑取图（`cover.cgi` 只认
> `album_name` + `album_artist_name`）、同专辑缓存、无图退占位。
> 表头排序与字段配置、文件管理、系统状态还没接。

## 功能

| 模块 | 内容 |
|---|---|
| 听歌 | 全部 / 艺术家 / 专辑 / 流派 四维浏览 · 播放与队列 · 封面 · 改 ID3 标签 |
| 文件管理 | 共享夹导航 · 排序分页 · 搜索 · 下载与缩略图 · 新建 / 上传 / 改名 / 复制 / 移动 / 删除 |
| 关机与计划 | 状态卡片 · 关机与重启 · 读写开关机计划 |
| 相册 | 本期不做 |

## 系统要求

- macOS 13 或更新（落代码时确认）
- 一台群晖 NAS，已开启 QuickConnect，或可从本机直连
- 账号需具备管理员权限（关机与改开关机计划需要）

## 技术选型

- **SwiftUI**，与产品线另四个 app 一致
- 播放用 **AVPlayer**
- 设计令牌来自产品线的 `design/tokens.json`（0.9.0 起正式接入），强调色 **sky**（群晖天蓝，深字方案）；
  生成物在 `design/dist/css/dreamanual.nas.css` 与 `design/dist/swift/DreamanualTheme.nas.swift`

## 项目结构

```
nas/
├── DreamanualNAS/           源码（SwiftUI，macOS 14+）
│   ├── DreamanualNASApp.swift   入口：固定深色 + 窗口
│   ├── DesignSystem/
│   │   ├── DreamanualTheme.nas.swift   生成物副本（勿手改，门禁对账 design/dist）
│   │   └── DesignSystem.swift          组件层：选中态（两条轨道）/ 页头 / 按钮 / 输入框 / 搜索框 / 开关 / 评分星 / 封面 / Toast / LucideIcon
│   ├── Core/
│   │   ├── QuickConnect.swift     QC ID → 中继端点（每次启动重解析）
│   │   ├── SynologyClient.swift   请求构造 / 信封解码 / 错误码 / 取字节（封面）
│   │   ├── SessionManager.swift   双会话 + 保活 + 失效重登重放
│   │   ├── KeychainStore.swift    口令只进系统钥匙串
│   │   ├── AudioLibrary.swift     曲库数据层（四维 / 搜索 / 筛选 / 分页 / 歌单 / 评分读写 / 封面）
│   │   ├── CoverStore.swift       封面缓存（键按专辑 + 艺术家，负结果也缓存，并发上限 4）
│   │   ├── PlaybackEngine.swift   播放引擎（队列 / 播放顺序 / 拖进度 / 音量）
│   │   ├── StreamLoader.swift     取流装载器（自定义 scheme + Range + TLS 策略）
│   │   └── AppState.swift         连接状态机 + 模块切换
│   └── Features/
│       ├── ConnectView.swift      连接页
│       ├── LibraryView.swift      曲库页（四维浏览 + 搜索 + 筛选）
│       ├── QueueView.swift        队列页（播放顺序 + 正在播标记）
│       ├── RootView.swift         外壳（侧栏 + 主区）
│       └── PlayerBarView.swift    底部常驻播放条（进度线悬停上展 + 控制钮 + 音量）
├── Resources/
│   └── brand.svg        图标源文件（品牌标记直接读它；换图标同时换根目录 AppIcon.icns）
├── scripts/
│   ├── check-tokens.mjs    令牌门禁（生成物一致 + 引用完整）
│   ├── build-app.sh        编译 → 组装 .app → 签名
│   └── gen-icon.swift      brand.svg → AppIcon.iconset → icns（一次性，改图标时重跑）
├── design/
│   └── 界面原型.html    整体界面与功能位置（浏览器直接打开，含组件板与标注）
├── docs/
│   ├── 产品定义.md      做什么、不做什么、界面结构
│   └── 接口结论.md      接口怎么调、踩过的坑（脱敏版）
├── project.yml          XcodeGen 工程定义
├── AppIcon.icns         应用图标（gen-icon.swift 从 brand.svg 生成）
├── LICENSE
└── README.md
```

编译：`./scripts/build-app.sh`（或 `--install` 装进 /Applications）。门禁：`node scripts/check-tokens.mjs`；
产品线级 `node design/scripts/check-cross-end.mjs`（固定深色一项已扫 NAS）。

## 文档

- [界面原型](design/界面原型.html) —— 七个屏 + 组件板，浏览器打开可切换；样式与功能位置以它为准
- [产品定义](docs/产品定义.md) —— 功能范围、地基能力、界面结构、从实测来的硬约束
- [接口结论](docs/接口结论.md) —— 鉴权、曲库与取流、写接口写法、性能实测数据

## 开发顺序

地基（连接 / 双会话 / 保活 / 外壳）→ 听歌 MVP → 改 ID3 → 文件管理只读 → 文件管理写操作 → 关机与计划。

## 开发者

蓝添（Dreamanual）· [dreamanual.com](https://dreamanual.com)

## 许可证

MIT，见 [LICENSE](LICENSE)。
