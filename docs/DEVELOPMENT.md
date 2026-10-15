# 开发指南

## 环境与构建

目标为 Apple Silicon / macOS 14+。原生项目只依赖系统 SwiftUI、AppKit、PDFKit、AVFoundation、UserNotifications 和 SQLite，不需要额外的 Swift 包管理依赖。

安装 Xcode Command Line Tools 后，在项目根目录运行：

```bash
swift --version
python3 --version
bash scripts/build-app.sh
open dist/PaperLingo.app
```

脚本构建 release 二进制、生成 macOS app bundle、复制资源并进行 ad-hoc 签名。不要用 `swift run PaperLingo` 代替正式 app 启动，系统通知需要 bundle 身份。

开发版 `runtime.json` 指向当前项目的绝对 `.runtime/` 路径，因此移动项目后需重新构建。完整离线版采用不同的可重定位资源布局，见 [分发指南](DISTRIBUTION.md)。

## 安装本地模型

```bash
bash scripts/setup-local.sh
```

脚本在项目内下载 uv、独立 CPython 3.11.17、[requirements.txt](../engine/requirements.txt) 中的依赖、Ollama 0.40.4、OmniVoice 固定快照及 `translategemma:4b`。OmniVoice 权重使用上游 LFS SHA-256 校验，并在主模型和音频 tokenizer 均存在后写入 `models.ready`。

当前打包器要求 Python 3.11.17 和 OmniVoice 快照 `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`；更改模型或解释器时须同步调整安装、打包和许可材料。TranslateGemma 的上游标签可能更新，测试过的 digest 记录在第三方说明中，每次离线构建会记录实际 blob 的 SHA-256。

安装使用 `127.0.0.1:11434`。如已有另一个 Ollama 服务，请先退出以避免模型被下载到其他实例的目录。下载中断可重新执行脚本。

## 检查与真实模型验证

### 不下载模型的回归检查

```bash
swift run --disable-sandbox PaperCoreChecks
python3 -m unittest discover -s engine/tests -v
for file in scripts/*.sh ./*.command; do bash -n "$file"; done
```

`PaperCoreChecks` 是独立断言程序，退出码非零表示检查失败；它不依赖完整 Xcode / XCTest。Python 检查只使用标准库与本地回环 HTTP 服务，模拟推理以验证协议；下载模型的检查也采用模拟上游接口，不连接 Hugging Face。

### 已安装模型的真实检查

先在 app 设置中启动两个本地引擎，然后运行：

```bash
python3 engine/doctor.py --smoke
python3 engine/benchmark_stream.py
```

前者验证中文翻译、24 kHz PCM WAV 与非静音输出；后者比较首段返回时间、总生成时间和整段接口。结果分别保存到 `.runtime/logs/smoke-test.json` 与 `.runtime/logs/stream-benchmark.json`。这些工具会连接本机模型并消耗推理资源。

离线 app 的搬迁 / 权重验证使用其内置 Python，命令见分发指南。已有实际结果与范围见 [VERIFICATION.md](VERIFICATION.md)。

### 启用 GitHub Actions

仓库提供 `.github/ci.example.yml`，包含 macOS 构建、Python / Swift 检查及签名验证，使用固定提交的官方 checkout Action。将其移至 `.github/workflows/ci.yml` 后提交即可启用；上传该路径需要相应的 GitHub workflow 写入权限。模板不会下载模型，普通源码克隆和本地检查无需该权限。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `PAPERLINGO_DATA_DIR` | 隔离论文与 SQLite 数据目录，便于测试；默认使用当前用户 Application Support |
| `PAPERLINGO_RUNTIME_DIR` | 覆盖模型与运行环境目录，按开发运行时布局读取 |
| `PAPERLINGO_ENGINE_WORK_DIR` | 覆盖引擎日志、缓存和可写模型索引目录 |
| `PAPERLINGO_APP_DIR` | 构建脚本的 app 输出目录；默认 `dist/PaperLingo.app` |
| `PAPERLINGO_SIGN_IDENTITY` | 覆盖默认 ad-hoc 签名身份；不会自动完成公证 |
| `PAPERLINGO_STAGE_ONLY=1` | 离线打包时只生成完整 app，供搬迁检查 |
| `PAPERLINGO_IMAGE_ONLY=1` | 从已有且已签名的分发目录重新生成 DMG |

在命令行直接执行 app 二进制时可传递隔离目录，例如：

```bash
PAPERLINGO_DATA_DIR="$(mktemp -d /tmp/paperlingo-dev.XXXXXX)" \
  dist/PaperLingo.app/Contents/MacOS/PaperLingo
```

这会隔离数据库，但用户偏好和系统通知仍使用同一 bundle 身份；不要把它当作完整的第二套用户账户。

## 模块与约定

- `Sources/PaperCore/`：保持无 UI 的文本、存储、复习和运行时路径逻辑。
- `Sources/PaperLingo/`：原生阅读、选区、视图状态、引擎生命周期和播放。
- `engine/server.py`：只监听回环，校验 Origin、Content-Type、文本长度、语速和音色；模型惰性载入，推理串行化。
- 分段流用 UUID 标识请求，客户端停止或重启朗读时取消旧队列；完成中的小段推理不会被强制杀死。
- 查阅成功后才更新学习数据，失败时保留真实错误，不能写入虚构译文。

优先遵循相邻代码格式。修复数据库与队列问题时关注持久性、去重和取消边界；不要添加只复述实现的检查。提交前查看 `git diff --check`，确保没有权重、个人数据、日志或绝对开发机路径。
