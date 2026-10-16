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

脚本构建 release 二进制、生成 macOS app bundle、复制资源并进行 ad-hoc 签名。主程序通过 `replace-executable.py` 写入新文件再原子替换；签名后再做一次字节不变的文件替换，减少原地覆写可执行文件的风险。新安装时曾观察到较长的系统加载等待，尚未完全确定系统原因；后续两次常规重开已通过。复制/安装 app 后如采用 APFS 克隆，也可对主程序运行此脚本；完整签名校验仍须通过。不要用 `swift run PaperLingo` 代替正式 app 启动，系统通知需要 bundle 身份。

开发版 `runtime.json` 指向当前项目的绝对 `.runtime/` 路径，因此移动项目后需重新构建。完整离线版采用不同的可重定位资源布局，见 [分发指南](DISTRIBUTION.md)。

## 安装本地模型

```bash
bash scripts/setup-local.sh
```

脚本在项目内下载 uv、独立 CPython 3.11.17、[requirements.txt](../engine/requirements.txt) 中的依赖、Ollama 0.40.4、OmniVoice 固定快照及 `translategemma:4b`。OmniVoice 权重使用上游 LFS SHA-256 校验，并在主模型和音频 tokenizer 均存在后写入 `models.ready`。

当前打包器要求 Python 3.11.17 和 OmniVoice 快照 `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`；更改模型或解释器时须同步调整安装、打包和许可材料。TranslateGemma 的上游标签可能更新，测试过的 digest 记录在第三方说明中，每次离线构建会记录实际 blob 的 SHA-256。

安装使用 `127.0.0.1:11434`。如已有另一个 Ollama 服务，请先退出以避免模型被下载到其他实例的目录。下载中断可重新执行脚本。

### v0.2 研究模型

完成基础安装后运行 `python3 engine/install_research.py` 和 `python3 engine/install_reranker.py`，或双击 `安装研究模型.command`。前者用独立的 `127.0.0.1:11435` 服务下载 `qwen3.6:27b-q4_K_M` 与 `qwen3-embedding:0.6b` 到同一项目模型目录，不操作系统 Ollama；后者下载固定快照的 `Qwen/Qwen3-Reranker-0.6B` 并校验 SHA-256。共约 19.3 GB，建议 32 GB 统一内存。

安装器会预检余量、通过文件锁防止重复安装、重试短暂断线，并交由 Ollama 校验完整 blob。Ollama 0.40.x 可能在异常退出后留下空的分段元数据；重新安装时仅对已知的下载分段几何恢复安全前缀，最终完整哈希仍必须通过。恢复大型权重时，会把过大的范围细分为 100 MB 的原生分段，保留安全的已写前缀，降低末段拖尾；旧分段元数据另外保存在安装日志目录。不要在安装进行中手动改写 partial 文件。进度写入 `.runtime/logs/research-progress.json`，完成后保存实际模型 digest 到 `.runtime/research-models.ready`。

应用内推理使用 `11434`。Ollama 只允许一个已加载模型和一个并行请求；整理时停下 app 自己创建的 OmniVoice 进程，随后恢复。不会停止外部进程。模型按需加载，研究任务结束后卸载；系统语音仍可使用。

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

研究模型就绪后可用原生客户端验证结构化输出、原文摘录匹配及跨语言检索：

```bash
swift run --disable-sandbox PaperResearchSmoke --work .test-output/research-smoke
# 只检查已安装的检索模型
swift run --disable-sandbox PaperResearchSmoke --embedding-only --work .test-output/embedding-smoke
# 可选：只取一份测试 PDF 的前三个片段，不代表全文汇总验收
swift run --disable-sandbox PaperResearchSmoke --source /absolute/path/to/test-paper.pdf --work .test-output/paper-smoke
```

默认素材明确为合成测试片段；工具不写入学习数据库。结果含实际耗时、模型名、向量维度、相似度和匹配后的汇总。全文 UI 验收需另行执行，不能把此诊断当成学术质量评测。

v0.2.1 的 `PaperResearchBenchmark --source PDF --work DIRECTORY` 使用与 app 相同的实验提取和概览客户端；会运行实际模型，只写隔离目录。`--plan-only` 仅检查证据规划，`--no-cache` 强制真实提取。

`PaperRetrievalBenchmark --input CORPUS_JSON --work DIRECTORY --port OLLAMA_PORT --rerank-port BRIDGE_PORT` 用显式提供的本地素材对照论文概览索引与旧版正文索引；输入数组元素为 `id/title/path/kind`，可选 `digest` 指向已保存的 PaperDigest JSON。工具加入明确标注的合成对照与笔记，不写用户库。服务须预先启动；小样本诊断不等于通用检索准确率。

数据库 schema 为 3；`paper-overview-v4` 保证每篇一个检索单元。正文仍存在原文证据与提取记录中，不能把原文全文存在本机等同于模型逐段读过。重排模型在 MPS 上使用 float32、eager attention、单文档无填充推理，避免已实测出现的批处理 NaN。

离线 app 的搬迁 / 权重验证使用其内置 Python，命令见分发指南。实际结果与范围见 [v0.2.1 验证](VERIFICATION_V0.2.1.md) 和 [历史验证](VERIFICATION.md)。

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

原生 UI 验收可另外构建不同 bundle identifier 的 QA app，并在其 `Contents/Resources/runtime.json` 中指定绝对 `data` 路径。此字段只用于隔离本地验收，正式构建脚本不会写入；不要把 QA bundle 覆盖用户安装版。

## 模块与约定

- `Sources/PaperCore/`：保持无 UI 的文本、存储、复习和运行时路径逻辑。
- `Sources/PaperLingo/`：原生阅读、选区、视图状态、引擎生命周期和播放。
- `engine/server.py`：只监听回环，校验 Origin、Content-Type、文本长度、语速和音色；模型惰性载入，推理串行化。
- 分段流用 UUID 标识请求，客户端停止或重启朗读时取消旧队列；完成中的小段推理不会被强制杀死。
- 查阅成功后才更新学习数据，失败时保留真实错误，不能写入虚构译文。
- `ResearchModels/Database/Client`：v2 档案与笔记、FTS5、逐页分块、向量一致性、结构化本地推理和引文匹配。持久化页码从零开始，界面显示时加一。
- `ResearchStore/Views`：任务与取消、完整文本处理、分段缓存及分层汇总、分类采用、关键词与语义融合检索。笔记与手工元信息独立于模型结果。
- 首次升级先通过 SQLite backup API 保存一致快照，再事务迁移到 `user_version=2`；不能用文件复制替代正在使用的 WAL 数据库备份。

优先遵循相邻代码格式。修复数据库与队列问题时关注持久性、去重和取消边界；不要添加只复述实现的检查。提交前查看 `git diff --check`，确保没有权重、个人数据、日志或绝对开发机路径。
