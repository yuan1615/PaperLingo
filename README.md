<p align="center">
  <img src="packaging/AppIcon.iconset/icon_128x128@2x.png" width="112" alt="PaperLingo 图标">
</p>

# PaperLingo

**在真实英文论文阅读中学习英语的 macOS 原生应用。**

Read papers. Learn words in context. Listen and review locally.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M%20series-blue)
![Version](https://img.shields.io/badge/version-0.1.0-blue)
[![MIT](https://img.shields.io/badge/source%20license-MIT-green)](LICENSE)

PaperLingo 将 PDF / 网页阅读、选词翻译、英文发音和间隔复习放在同一阅读空间。使用 TranslateGemma 4B 本地翻译、OmniVoice 本地语音合成；查阅过的生词与短语成为自己的每日练习材料。

当前为 **v0.1.0**。本仓库提供源码、模型安装和离线打包脚本；**不包含模型权重、Python 运行环境、DMG 安装包或个人学习记录**。

[快速开始](#快速开始) · [使用方式](#使用方式) · [项目架构](#项目架构) · [开发指南](docs/DEVELOPMENT.md) · [离线打包](docs/DISTRIBUTION.md) · [变更记录](CHANGELOG.md)

## 功能

| 功能 | 行为 |
| --- | --- |
| 论文阅读 | 导入本地 PDF 或 HTTP(S) 链接，保留 PDF 图表、公式与双栏版式；保存阅读位置 |
| 选词与选句翻译 | 英译中；保留原文、所在句、论文来源和页码 |
| 本地发音 | OmniVoice 正常 / 慢速朗读，美式 / 英式音色；可切换 macOS 系统语音 |
| 渐进朗读 | 长文本分段推理，首段完成即返回并播放，后续片段按序进入队列 |
| 专注阅读 | 左右面板独立隐藏，浮动工具栏自动收起，播放器不推移正文 |
| 个人词库 | 查询频率统计、上下文、来源跳转、搜索、删除和 JSON 导出 |
| 每日复习 | 认词与听力两种模式，四级自评分，默认每天约 10 分钟、每组最多 20 项 |
| 本地提醒 | 默认北京时间 20:30，可在设置调整；通知提供认词 / 听力入口 |

## 环境要求

- **Apple Silicon（M 系列）Mac，macOS 14 或更高版本**；当前完整模型安装与打包脚本面向 arm64。
- 建议 **16 GB 或以上统一内存**；实际联调环境为 M2 Pro / 32 GB。
- 建议预留 **20 GB 或以上磁盘空间**；同时保留开发环境、打包副本和 DMG 时需要更多空间。
- 从源码构建需要 Xcode Command Line Tools（Swift 5.9+）和 `python3`；模型安装脚本会另外下载独立 Python 3.11.17。
- 首次下载模型和导入网页需要联网；本地 PDF、翻译、发音与复习可离线使用。

## 快速开始

### 从源码运行

先安装 [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/)，并确认 `swift --version` 与 `python3 --version` 可用。

```bash
git clone https://github.com/yuan1615/PaperLingo.git
cd PaperLingo

# 构建原生 macOS app，不下载模型
bash scripts/build-app.sh

# 首次安装两个模型及项目内运行环境，需要联网
bash scripts/setup-local.sh

# 打开 app，在设置中检查两个本地引擎是否就绪
open dist/PaperLingo.app
```

下载中断后可以重新执行安装脚本，已有缓存和下载片段会复用。运行环境位于项目 `.runtime/`，不替换系统 Python。模型未安装时也能导入、阅读论文，并选择系统语音体验朗读。

亦可双击项目根目录的 `启动 PaperLingo.command` 与 `安装本地模型.command`。开发版 app 依赖当前项目的 `.runtime/`；移动项目后请重新构建。

### 安装完整离线包

如果你已取得单独分发的 `PaperLingo-0.1.0-macOS-arm64-offline.dmg`，双击后把 app 拖到「应用程序」。该版本包含 Python、Ollama 和全部模型，无需开发工具或再次下载模型。

当前离线包采用 ad-hoc 签名，未做 Apple Developer ID 公证。首次若被 macOS 拦截，请按 [安装与迁移说明](packaging/INSTALL-zh.txt) 在「隐私与安全性」中允许打开。仓库的源码 ZIP 不是可直接安装的 app。

## 使用方式

1. 导入 PDF 或论文链接。arXiv 摘要链接会自动获取对应 PDF。
2. 在正文选中单词、短语或句子，点击「翻译选区」或「朗读」。成功翻译的单词与短语自动进入词库；句子通过「加入复习」保存。
3. 阅读时收起侧栏或进入专注模式，浮动播放器支持暂停、继续、收起和停止。
4. 打开「今日练习」，先回想含义或听音辨认，再揭晓答案，并用「忘记 / 模糊 / 记住 / 轻松」评分。
5. 在设置中授权 macOS 通知，调整每日复习时间、音色和语速。

查询频率只在主动查阅时累计；改变选区不会反复计数。复习优先级结合查询频率、遗忘次数和逾期程度，不把个人查询次数当作通用词频。

### 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘O` | 导入 PDF |
| `⇧⌘O` | 导入链接 |
| `⇧⌘F` | 进入 / 退出专注阅读 |
| `Esc` | 退出专注阅读 |
| `⌥⌘S` | 显示 / 收起论文库 |
| `⌥⌘I` | 显示 / 收起学习助手 |
| `⌘L` | 朗读选区 |
| `⌘.` | 停止播放 |

## 项目架构

```mermaid
flowchart TD
    Reader[SwiftUI / AppKit 阅读空间] --> PDF[PDFKit / 网页正文]
    Reader --> Store[PaperCore / SQLite 词库与复习]
    Reader --> Translator[Ollama / TranslateGemma 4B]
    Reader --> Speech[Python HTTP Bridge / OmniVoice]
    Speech --> Audio[分段 WAV / 有序播放队列]
    Store --> Review[认词 / 听力 / macOS 本地提醒]
```

- **界面**：SwiftUI + AppKit；PDFKit 展示论文，NSTextView 展示提取后的网页正文。
- **学习数据**：SQLite 保存论文元信息、词条、查询与复习事件；透明的规则式间隔算法，尚未使用 FSRS。
- **翻译**：URLSession → `127.0.0.1:11434` → Ollama `translategemma:4b`（Q4_K_M）。
- **语音**：URLSession → `127.0.0.1:8765` → OmniVoice 0.2.1 / PyTorch MPS。推理串行执行，客户端播放与下一段推理并行。
- **分段协议**：`POST /speak/stream` 输出 NDJSON，依次返回 `start → audio → … → done`；支持取消与片段缓存。

首段上限 120 字符，后续每段上限 160 字符，单次最长 12,000 字符。分段缩短开始聆听的等待；模型首次加载、机器负载和文本长度仍会影响延迟，片段之间可能出现等待。

```text
Sources/
  PaperLingo/             原生界面、阅读器、音频与模型进程管理
  PaperCore/              数据库、文本规则、复习算法、运行时路径
  CSQLite/                SQLite 系统模块
engine/                   OmniVoice HTTP 服务、下载与诊断工具
engine/tests/             无需模型的 Python 回归检查
Tests/PaperCoreTests/     可独立运行的 Swift 核心检查
scripts/                  构建、环境安装与离线打包
packaging/                图标、Info.plist、安装说明及第三方许可
docs/                     产品设计、开发、分发与验收记录
.github/                  CI、Issue 表单与 PR 模板
```

## 数据与隐私

| 内容 | 位置 |
| --- | --- |
| 论文、词库、查询与复习记录 | `~/Library/Application Support/PaperLingo/` |
| 开发版模型、Python、日志和音频缓存 | 项目 `.runtime/` |
| 离线安装版模型与运行环境 | `PaperLingo.app/Contents/Resources/Runtime/` |
| 离线安装版可写日志与缓存 | `~/Library/Application Support/PaperLingo/Engine/` |

应用不调用在线翻译或在线 TTS；只有主动选择的文本发给本机模型，论文不会自动整篇提交。网页导入和模型安装会访问相应远程站点；没有内置云同步、用户账号或遥测服务。

迁移前先在两台电脑退出 app，再复制完整用户数据目录；可跳过 `Engine/` 缓存，存在的 SQLite `-wal` / `-shm` 辅助文件须一并保留。新机已有数据时先备份。JSON 导出不含 PDF 和完整复习日志，首版没有 JSON 导入。

## 开发与验证

以下检查无需下载模型：

```bash
swift run --disable-sandbox PaperCoreChecks
python3 -m unittest discover -s engine/tests -v
bash scripts/build-app.sh
```

仓库附带 [macOS CI 模板](.github/ci.example.yml)，启用方法见开发指南。检查不下载权重，也不把模型质量测试当作已通过。真实推理、渐进语音和搬迁测试见 [验收记录](docs/VERIFICATION.md)。

环境变量、真实模型诊断和代码约定见 [开发指南](docs/DEVELOPMENT.md)。完整 app / DMG 的构建、签名和分发方式见 [离线打包指南](docs/DISTRIBUTION.md)。

## 当前边界

- PDF 必须含可选择的文字层；扫描件需先 OCR。
- 网页提取适用于静态正文；登录墙、反爬或动态网页可先由浏览器打印为 PDF。
- 翻译与发音可能有误，孤立学术术语需结合原论文核对。
- 通知受 macOS 授权、休眠与专注模式影响；未来 30 天的提醒会在打开或学习后重新安排。
- 尚无跨设备同步、口语评分、全篇自动翻译、OCR 或个人模型训练。

## 参与贡献

欢迎通过 [Issues](https://github.com/yuan1615/PaperLingo/issues) 报告问题或提出建议，提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

[产品与交互设计](docs/PRODUCT.md) · [变更记录](CHANGELOG.md) · [源码 MIT 许可证](LICENSE)

## 许可与致谢

**PaperLingo 自有源码采用 [MIT License](LICENSE)**。这不改变第三方代码、模型权重、音频 tokenizer 或依赖的许可证，也不授予模型的额外商用权利。

| 组件 | 上游与许可 |
| --- | --- |
| OmniVoice 代码 | [k2-fsa/OmniVoice](https://github.com/k2-fsa/OmniVoice)，Apache-2.0 |
| OmniVoice 权重 | [模型卡](https://huggingface.co/k2-fsa/OmniVoice)，CC-BY-NC；当前完整模型包面向个人非商业学习 |
| TranslateGemma 4B | [Google / Ollama](https://ollama.com/library/translategemma)，Gemma Terms of Use 与 Prohibited Use Policy |
| Higgs Audio V2 tokenizer | Boson AI 社区许可，随 OmniVoice 快照分发 |
| Ollama | [ollama/ollama](https://github.com/ollama/ollama)，MIT |

详细归属、固定模型版本和随包许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [packaging/third-party/](packaging/third-party/)。感谢上述项目的作者和维护者。
