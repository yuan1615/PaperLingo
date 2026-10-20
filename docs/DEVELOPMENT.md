# 开发指南

## 环境与构建

目标为 Apple Silicon / macOS 14+。原生项目只依赖系统 SwiftUI、AppKit、PDFKit、NaturalLanguage、AVFoundation、UserNotifications 和 SQLite，不需要额外的 Swift 包管理依赖。

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

v0.2.2 的 `PaperResearchBenchmark --source PDF --work DIRECTORY --port OLLAMA_PORT` 使用与 app 相同的前三页加载器和一次摘要调用，随后为中文摘要建立一个向量；只写隔离目录。`--plan-only` 只检查前三页输入范围，不调用模型。需要预先启动本地 Ollama。

`PaperRetrievalBenchmark --input CORPUS_JSON --work DIRECTORY --port OLLAMA_PORT --rerank-port BRIDGE_PORT` 使用已保存的本版摘要检查中英文召回及无关查询过滤。输入数组元素为 `id/title`，可选 `digest` 指向本版 PaperDigest JSON；不加载 PDF，没有摘要的论文不建向量。不写用户库，服务须预先启动；内置语音合成查询适用于 OmniVoice 测试素材，小样本诊断不等于通用检索准确率。

数据库 schema 为 5；新增 `word_explanations` 缓存，原研究索引规则不变。`chinese-summary-only-v1` 只为新摘要建立一个检索单元。升级前备份数据库，清理旧实验和全文缓存，保留个人笔记及学习数据。当前整理不调用旧版实验提取接口；保留的旧数据类型和纯函数用于历史兼容及回归检查。重排模型继续使用 float32、eager attention、单文档无填充推理，避免已实测出现的批处理 NaN。

离线 app 的搬迁 / 权重验证使用其内置 Python，命令见分发指南。实际结果与范围见 [v0.2.2 验证](VERIFICATION_V0.2.2.md) 和 [历史验证](VERIFICATION.md)。

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

- `Sources/PaperCore/`：保持无 UI 的文本、存储、复习和运行时路径逻辑。长原句使用系统 `NLTokenizer` 并按需扩展局部窗口；不要重新引入固定字符截断或旧 `NSLinguisticTagger.sentenceRange` 的内部长度限制。
- `Sources/PaperLingo/`：原生阅读、选区、视图状态、引擎生命周期和播放。
- `engine/server.py`：只监听回环，校验 Origin、Content-Type、文本长度、语速和音色；模型惰性载入，推理串行化。
- 分段流用 UUID 标识请求，客户端停止或重启朗读时取消旧队列；完成中的小段推理不会被强制杀死。
- 查阅成功后才更新学习数据，失败时保留真实错误，不能写入虚构译文。
- `PaperSummary` 与 `ResearchModels/Database/Client`：文献档案、独立笔记、FTS5、前三页输入、固定结构中文摘要与每篇一个摘要向量。持久化页码从零开始，界面显示时加一。旧实验类型只用于历史兼容，不参与当前整理流程。
- `ResearchStore/Views`：任务与取消、一次摘要生成、分类采用、关键词与语义融合检索，以及摘要优先的研究库布局。笔记与手工元信息独立于模型结果。
- `Readers/SelectionPopover`：PDF / 网页选区锚点、拖选结束后的就地操作和译文展示；弹层不参与正文布局，原文与译文独立滚动；滚动正文和调整窗口保留结果，在明确关闭、切换论文及退出阅读时清理。
- 首次升级先通过 SQLite backup API 保存一致快照，再事务迁移到当前 `user_version=5`；不能用文件复制替代正在使用的 WAL 数据库备份。

优先遵循相邻代码格式。修复数据库与队列问题时关注持久性、去重和取消边界；不要添加只复述实现的检查。提交前查看 `git diff --check`，确保没有权重、个人数据、日志或绝对开发机路径。

## v0.2.4 长句回归范围

2026-10-20：32 项核心检查通过，覆盖 3,000 字符以上长句在开头、中间、结尾的选区、Unicode、历史截短片段的正确来源匹配及完整上下文保存。百万字节普通网页选区仍只需一个局部分句窗口。

独立应用标识和数据库中的 16 项原生界面检查通过：合成诊断 PDF / 网页的 1,315 字符选区、本机 TranslateGemma 返回、原生滚动视图偏移后的结果保留、窗口调整、Esc、网页视口锚点、旧词条按来源页恢复、860 × 620 窗口完整原句和复习播放器布局。已查看原句末尾及评分按钮的渲染截图。滚动验证采用原生滚动视图操作；未自动覆盖真实触控板的所有连续手势。测试数据未写入正式学习库。

v0.2.4 当时的修改不升级数据库 schema 或模型，不重新生成 v0.2.3 的完整模型镜像。历史原句恢复只读取已保存的 PDF 页或网页快照；来源缺失或匹配不明确时保留已有上下文，不编造后续文字，也不修改历史查阅和评分事件。

## v0.2.5 复习播放布局回归

在可显示原生窗口的 macOS 桌面会话中运行（无需安装模型）：

```bash
bash scripts/check-review-ui.sh
```

脚本创建独立 bundle identifier、合成词条和数据库，结果与截图写入忽略的 `.test-output/review-ui.*`。原生鼠标事件验证完整原句朗读、暂停、继续、停止和详情入口；使用 macOS 系统语音，不修改正式 app 的发音偏好。分段生成、播放、暂停及长错误状态通过注入界面状态检查，不代表重新验证 OmniVoice 推理质量。

2026-10-20：34 项原生 UI 检查、32 项核心检查和 Release 构建通过。860 × 620、1100 × 800、1440 × 900 三种尺寸逐一比较播放前后的卡片边界、滚动偏移及评分区域像素；另检查详情弹层、听力模式的揭晓按钮和整句词条。已查看小窗口和大窗口渲染截图。播放控件固定在进度栏，禁止重新通过动态 `safeAreaInset` 插入复习播放器。详情弹层仅按需打开，不参与卡片布局。

本版不更改模型、数据库格式或历史学习记录；已有完整模型 DMG 仍为 v0.2.3，未在本次界面修复中重新打包。

## v0.2.6 原句词语高亮

`ReviewContextText` 只为原句中的当前词条添加浅黄色底色与加粗；匹配忽略大小写、支持短语中的空白，按 Unicode 字母/数字边界排除更长词中的子串。按字面转义表达中的正则字符，不修改原句字符、保存数据或朗读输入。

2026-10-20：Release 构建及既有 34 项原生 UI 回归检查通过。已查看独立数据中的单词、短语和 `C++` 预览，确认重复/大写形式均突出显示，`learn` 不误标 `learning` 或 `learner`。数据库和模型不变。

## v0.2.7 词语语境讲解

阅读翻译继续走 TranslateGemma。生词本只为展开的当前词条生成讲解；800 ms 防抖、单任务执行、原句/词条/提示词版本/模型签名缓存校验。只读取该词保存的 PDF 页或网页快照，模型输入限制为选词附近约 1,200 UTF-16 单元，保留完整原句用于界面展示。

固定提示词与结构在 `Sources/PaperCore/WordExplanation.swift`：本句词义、结合原句、用法提示；目标合计约 100–180 字。`ResearchClient.explainWord` 关闭思考、上下文 3,072、输出最多 384 tokens、45 秒请求墙钟上限、`keep_alive=0`。过长、不完整和截断响应均不覆盖有效缓存，不自动重试。缺原句时明确标注，不编造文中含义。

`VocabularyStore` 将讲解设为低优先级。翻译、语音、论文整理与语义检索在调用模型前取消并等待讲解任务完成清理；快速切换词条也等待旧请求卸载。只暂停 app 自己启动的语音进程，结束后按原生命周期恢复，不停止外部服务。已保存讲解可用于今日练习，复习页面不会发起新讲解。

schema 5 在一致备份后只增加独立缓存表，词条删除时级联清理。讲解不修改原译文、查阅频率、到期时间或评分；过期响应保存前再次核对当前词条语境。JSON 备份版本升为 5，包含当前有效讲解。

检查命令（原生 UI 需要桌面会话）：

```bash
swift run --disable-sandbox PaperCoreChecks
bash scripts/check-vocabulary-ui.sh
bash scripts/check-review-ui.sh
# 先在独立端口启动本地 Ollama，避免和正式应用争抢资源
swift run -c release --disable-sandbox PaperWordExplanationSmoke --port 11436 --work .test-output/word-smoke
swift run -c release --disable-sandbox PaperWordExplanationSmoke --port 11436 --work .test-output/word-cancel --cancel-only --cancel-after 15
```

`check-vocabulary-ui.sh` 使用随机回环端口和独立 app / 数据库，模拟慢响应、断连、错误和输出上限，并使用系统语音验证前台抢占；它不下载或运行真实大模型。原生测试生成的截图和报告均留在忽略的 `.test-output/` 中。

2026-10-20 的真实 Qwen3.6 样例在每次请求前卸载模型，三次耗时 20.50 / 20.26 / 21.21 秒，讲解长度 90 / 90 / 91 字符。`novel` 在方法与阅读材料两种语境中分别解释为“新颖的”和“小说”，另检查 `in contrast to`。加载约占 10 秒，操作系统文件缓存可能仍然温热；这些合成诊断不代表通用词典准确率或其他设备性能。加载阶段取消与卸载约 0.006 秒，进入生成阶段后约 0.388 秒，专用端口均无驻留模型；不含语音服务恢复时间。

最终验证：36 项核心、29 项生词讲解/调度原生 UI 检查和 34 项原复习 UI 检查通过；另有 7 项真实模型集成检查，覆盖讲解取消后真实 TranslateGemma 的约 4 秒返回、自有 OmniVoice 服务暂停/恢复/实际播放，以及原学习记录保持不变。取消任务后的语音恢复使用独立取消上下文，启动生命周期标识防止停止引擎后意外重启。真实模型验收使用独立端口、合成词条与隔离数据，没有写入正式学习库。
