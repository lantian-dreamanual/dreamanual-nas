# Dreamanual NAS 助手

连接群晖（Synology）NAS 的 macOS 桌面客户端。以听自己的曲库为主轴，兼顾文件管理与开关机。

> **当前状态：曲库浏览已通（2026-10-12）。** 接口可行性已在真实机器上逐条验完（见 [接口结论](docs/接口结论.md)），
> 功能范围已定（见 [产品定义](docs/产品定义.md)），整体界面出了 HTML 原型（[界面原型](design/界面原型.html)）。
> 地基已通：QuickConnect 端点解析、双会话（FileStation + AudioStation）、钥匙串口令、保活重登、
> 外壳（侧栏 + 主区 + 底部播放条）。**曲库页已接数据**：四维浏览 / 搜索 / 筛选 / 分页懒加载，
> 真机 12328 首完整渲染。播放与队列、歌单与每日随机、文件管理、系统状态还没接。

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
│   │   └── DesignSystem.swift          组件层：选中态（两条轨道）/ 页头 / 按钮 / 输入框 / 搜索框 / 开关 / LucideIcon
│   ├── Core/
│   │   ├── QuickConnect.swift     QC ID → 中继端点（每次启动重解析）
│   │   ├── SynologyClient.swift   请求构造 / 信封解码 / 错误码
│   │   ├── SessionManager.swift   双会话 + 保活 + 失效重登重放
│   │   ├── KeychainStore.swift    口令只进系统钥匙串
│   │   ├── AudioLibrary.swift     曲库只读数据层（四维 / 搜索 / 筛选 / 分页）
│   │   └── AppState.swift         连接状态机 + 模块切换
│   └── Features/
│       ├── ConnectView.swift      连接页
│       ├── LibraryView.swift      曲库页（四维浏览 + 搜索 + 筛选）
│       ├── RootView.swift         外壳（侧栏 + 主区）
│       └── PlayerBarView.swift    底部常驻播放条（空态）
├── scripts/
│   ├── check-tokens.mjs    令牌门禁（生成物一致 + 引用完整）
│   └── build-app.sh        编译 → 组装 .app → 签名
├── design/
│   └── 界面原型.html    整体界面与功能位置（浏览器直接打开，含组件板与标注）
├── docs/
│   ├── 产品定义.md      做什么、不做什么、界面结构
│   └── 接口结论.md      接口怎么调、踩过的坑（脱敏版）
├── project.yml          XcodeGen 工程定义
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
