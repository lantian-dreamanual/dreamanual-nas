# Dreamanual NAS 助手

连接群晖（Synology）NAS 的 macOS 桌面客户端。以听自己的曲库为主轴，兼顾文件管理与开关机。

> **当前状态：听歌 MVP 已通（2026-10-13）。** 接口可行性已在真实机器上逐条验完（见 [接口结论](docs/接口结论.md)），
> 功能范围已定（见 [产品定义](docs/产品定义.md)），整体界面出了 HTML 原型（[界面原型](design/界面原型.html)）。
> 地基已通：QuickConnect 端点解析、双会话（FileStation + AudioStation）、本机口令凭据、保活重登、
> 外壳（侧栏 + 主区 + 底部播放条）。**曲库页已接数据**：四维浏览 / 搜索 / 筛选 / 分页懒加载，
> 真机 12328 首完整渲染。**播放与队列已接**：取流走自定义 scheme + 资源装载代理（`stream.cgi`
> 要带 `X-SYNO-TOKEN`），真机验证过播放 / 拖进度 / 切歌（`DM_SMOKE=1` 冒烟通路）。
> **内容区侧栏已接**：每日随机 / 全部曲目 / 我的歌单 / 评分 ≥ 4 星（这台库还没评过分，此入口现为空）。
> **评分写入已接**（真机验证过写 5 / 写 3 / 复原 0 三步回读一致）：曲库表 / 队列表 / 播放条三处都能点星，写后回读校验，写失败弹 Toast。
> **封面缩略图已接**（真机验证）：曲库表 / 队列表标题列内嵌 28px、播放条 44px、沉浸屏 280px。**首选歌自己
> 目录里的图片**（`FileStation.List` 挑图 + `Thumb` / `Download mode=open`），目录里没有才兜底问
> `cover.cgi`（只认 `album_name` + `album_artist_name`）；缓存键按目录 + 档位、无图退占位。
> 🔴 目录优先的理由：同名但不同源的专辑只要都缺 `album_artist` 标签，DSM 会并成一张、只给一张图（实测
> 专辑名「0」并了 Low Roar / Superfly / 林忆莲 三家），按专辑名取图必然串台。
> **沉浸模式已接**：点播放条的封面或歌名进出（Esc / 右上角关闭钮退出），只收侧栏、播放条保留；
> 底是放大封面重模糊 + 压暗，左封面 280 右信息栏 380；歌词**内嵌优先**（`getlyrics` 读 ID3 的 `USLT` 帧）、
> **在线兜底**（`searchlyrics`，插件装在 NAS 上），没有歌词时换成「未匹配到歌词 + 接下来播放」。
> **表头排序与字段配置已接**：点表头按该列排、同一列再点换方向（当前列亮主色箭头）；表头最右竖三点
> 弹字段配置（勾选显示哪些列，标题是主键列、不可隐藏），排序与列显隐都存本机、跨重启保留。排序走
> 服务端的 `sort_by` / `sort_direction`（八个字段实测都被认）—— 曲库快照与它的字段筛选是分页的两路、
> 必须服务端排（否则第二页又回默认顺序），搜索 / 每日随机 / 高分曲 / 歌单四路本地排。
> 真机核对走 `DM_LIBRARY=<指令>` 冒烟通路（`sort=<字段>:asc|desc` / `hide=<字段>` / `menu` / `reset`）。
> **表格错位与横向滚动已修**（2026-10-13 用户真机抓到）：行尾补上与表头等宽的一格空道（少了这 32，
> 行的自适应标题列比表头宽、后面每一列整体右移）；窗口窄于内容宽时整块横向滚动，**表头与行在同一个
> 滚动容器里**一起滚；最小窗宽 1140 → **1170**（那一格字段配置是后来补的，1140 装不下、竖三点被裁）。
> 队列行首列的内边距同时修到 `.frame` 里面（写在外面那一格变 76、表头是 56，错位 20）。
> **右键菜单与下载已接**：曲库表与队列表的歌曲行右键出设计系统的菜单卡（播放 / 下一首播放 / 评分 /
> 下载）；菜单层挂根视图、越界收回窗口内，Esc 或点别处收起。下载走 `FileStation.Download` `mode=open`
> 取**原文件**，先弹保存面板；失败有两种形状（会话类 HTTP 200 + JSON `119`、路径类 HTTP 404 + HTML），
> 两条判据都写了 —— 见 [接口结论](docs/接口结论.md) 第十一节。
> **键盘与媒体键已接**：空格播放 / 暂停、← / → 前后 5 秒（本地事件监听，搜索框里打字不受影响）；
> Mac 的媒体键与控制中心走 `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`（不自己绑 F8），
> 并在引擎每次状态变化时把曲目信息发布给系统。核对走 `DM_KEYS=space,right,left,search` 冒烟通路
> —— `search` 记号把光标放进搜索框，验证「光标在文本里时空格不暂停」（走 SwiftUI 焦点状态；
> AppKit 硬塞第一响应者会被顶回来，真机实测）。真机三键 + 守卫全部通过。
> 界面状态的真机核对另有 `DM_UI=<指令>`（`window=<宽>x<高>` 摆窗口 / `songmenu` 开右键菜单 /
> `download` 下到临时目录验落盘）。
> **三点图标画空气已修**（2026-10-13 真机抓到）：SF Symbols 没有 `ellipsis.vertical`，兜底写了
> 这个名字真机上就是一片空白 —— 改成横排 `ellipsis` 转 90°，形态照原型 lucide more-vertical。
> 文件管理、系统状态还没接；桌面小组件已记在规划里（见 [产品定义](docs/产品定义.md) 第八节）。

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
│   │   ├── CredentialStore.swift  口令落本机文件（0600，钥匙串只留一次性迁移）
│   │   ├── KeychainStore.swift    已退役的钥匙串读写（仅 CredentialStore 迁移用）
│   │   ├── AudioLibrary.swift     曲库数据层（四维 / 搜索 / 筛选 / 分页 / 歌单 / 评分读写 / 封面）
│   │   ├── CoverStore.swift       封面缓存（键按专辑 + 艺术家，负结果也缓存，并发上限 4）
│   │   ├── LyricsService.swift    歌词读取（内嵌 getlyrics + 在线 searchlyrics + LRC 解析）
│   │   ├── LyricsStore.swift      歌词缓存（键按歌曲 id，内嵌优先、在线兜底）
│   │   ├── PlaybackEngine.swift   播放引擎（队列 / 播放顺序 / 拖进度 / 音量）
│   │   ├── StreamLoader.swift     取流装载器（自定义 scheme + Range + TLS 策略）
│   │   └── AppState.swift         连接状态机 + 模块切换
│   └── Features/
│       ├── ConnectView.swift      连接页
│       ├── LibraryView.swift      曲库页（四维浏览 + 搜索 + 筛选 + 表头排序 / 字段配置）
│       ├── QueueView.swift        队列页（播放顺序 + 正在播标记）
│       ├── ImmersiveView.swift    沉浸模式（模糊封面底 + 大封面 + 歌词区两态）
│       ├── RootView.swift         外壳（侧栏 + 主区）
│       └── PlayerBarView.swift    底部常驻播放条（进度线悬停上展 + 控制钮 + 音量）
├── Resources/
│   └── brand.svg        图标源文件（品牌标记直接读它；换图标同时换根目录 AppIcon.icns）
├── scripts/
│   ├── check-tokens.mjs    令牌门禁（生成物一致 + 引用完整）
│   ├── build-app.sh        编译 → 组装 .app → 签名
│   └── gen-icon.swift      brand.svg → AppIcon.iconset → icns（一次性，改图标时重跑）
├── tools/
│   └── cover-selfcheck/    封面取图自检（只读）：同专辑逐首取图打字节数与 md5
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

地基（连接 / 双会话 / 保活 / 外壳）→ 听歌 MVP → 改 ID3 → 文件管理只读 → 文件管理写操作 → 关机与计划 → 桌面小组件。

## 开发者

蓝添（Dreamanual）· [dreamanual.com](https://dreamanual.com)

## 许可证

MIT，见 [LICENSE](LICENSE)。
