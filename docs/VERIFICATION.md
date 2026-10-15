# 本机验收记录

日期：2026-10-15。环境：Apple M2 Pro，32 GB 统一内存，macOS 15.6，Swift 6.0.3 Command Line Tools。构建为 arm64 macOS 原生应用，ad-hoc 签名。

## 已通过

- 发布构建、app bundle 资源定位与签名校验。
- 原生首页、试读正文、学习助手、设置页的实际窗口检查。
- 从 arXiv 摘要链接下载 OmniVoice 真实论文 PDF，保留原版式，双击选取单词并联动学习助手。
- 导入同一论文的 HTML 版本，保存本地正文；选取 intelligibility 后带出完整原句。
- 退出并重新启动后论文库恢复，读取已保存的阅读位置。
- 无效网页链接在导入窗口内提示，关闭错误后可继续修改和取消，不遗留旧错误弹窗。
- 模型未连接时返回真实错误，SQLite 中不产生伪造译文、词条或成功查询记录。
- macOS 通知权限已在系统设置开启，提醒设置为 Asia/Shanghai 20:30。系统日志确认接受了未来 30 天提醒和后续更新提醒。
- 测试通知经过系统投递管线，日志显示 shouldDeliver: true，并展示为 banner。
- 两个模型的下载进度在设置页实时显示，下载文件逐段续传；OmniVoice 权重使用官方 LFS SHA-256 校验。
- OmniVoice Python API 可导入，PyTorch 2.8.0 检测到 MPS 可用。

## 自动检查

`swift run --disable-sandbox PaperCoreChecks`：当前 13 项通过（含选区范围、大正文与离线运行时搬迁回归）。

涵盖 PDF 跨行词与句子、词条去重与查询频率、空译文拦截、句子制卡、复习间隔和优先级、已掌握词再次查询、数据库重启与来源移除、阶段边界与每日 20 项上限、HTML 正文提取、已收藏句子的重复查询计数。

`python3 -m unittest discover -s engine/tests -v`：当前 17 项通过（含 7 项分段返回与取消测试、3 项固定模型快照安装检查）。

涵盖续传与正确 SHA-256、错误 SHA-256 不安装、真实健康检查结构、浏览器 Origin 拒绝、非 JSON 表单拒绝、非法输入拒绝、未知路由拒绝。

## 模型最终联调

首次权重下载后运行 `python3 engine/doctor.py --smoke`，验证中文翻译、24 kHz PCM WAV、非静音声音和实际耗时。报告保存于 `.runtime/logs/smoke-test.json`。

最终推理检查通过：

| 项目 | 真实输出 | 本次耗时 |
| --- | --- | --- |
| 短语翻译 | spurious correlations → 虚假相关 | 冷启动 18.96 秒 |
| 句子翻译 | A robust representation should generalize beyond the training distribution. → 一个健壮的表示方法应该能够推广到训练数据之外。 | 热启动 0.50 秒 |
| 单词发音 | intelligibility，24 kHz，1.49 秒非静音 PCM WAV | 1.82 秒 |
| 句子发音 | A little reading, a little growth.，24 kHz，2.11 秒非静音 PCM WAV | 1.67 秒 |

这些是本机一次测试结果，不是延迟保证。OmniVoice 首次加载及英文试听、缓存再播放都已在原生播放器中验证。

- OmniVoice 权重版本：`c5fdb5ccb189668d56333f77ba2629f4cd7535f4`，音频 tokenizer 一并本地保存。
- TranslateGemma：`translategemma:4b`，4.3B / Q4_K_M，Ollama 0.40.4；模型 digest：`c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`。
- 原生交互验收：短语翻译自动制卡；再次查询保持一张卡、次数变为 2；「译原句」返回完整中文译文；句子经明确操作加入复习。
- 听力验收：播放前原文和译文均隐藏；正常短语发音和整句慢速发音请求成功；揭晓后显示答案及来源。
- 评分验收：一张卡评「记住」，SQLite 复习日志间隔精确为 86400 秒；另一张评「忘记」，间隔精确为 600 秒；本组结束后两张卡均不再立即到期。
- 生词本显示查询频率、复习状态、上下文，并可回到来源正文。
- 验收使用测试词卡验证查询和复习行为，测试数据库、论文及日志不随源码仓库分发。
- 最终重启后应用自行启动两个本地服务，设置页确认 TranslateGemma 与 OmniVoice 均已就绪；20:30 提醒设置在重启后保留。
- 最终 Ollama 由应用管理，绑定 127.0.0.1，并启用 `OLLAMA_NO_CLOUD=1`；OmniVoice 读取固定的本地模型快照，使用离线模式。

## 验证范围

没有进行翻译质量的正式基准评测，也没有把语音质量指标当作已验证结果。扫描 PDF 的 OCR、登录墙及动态网页、跨设备同步不属于第一版。系统通知受 macOS 休眠和专注模式策略影响。


## 阅读体验更新验收（2026-10-15）

- 扩大普通图标按钮至最小 32 × 32 pt；导航、论文卡片的空白区域也可触发，实际窗口中单击导航文字右侧空白已切换至生词本。
- 正文区域可独立收起左右面板，专注模式两侧均隐藏，浮动工具栏 2 秒后变为顶部「…」。Esc 退出，恢复面板偏好。实际缩小窗口到约 872 × 648 pt 后按钮与正文均可操作。
- 长选区小字号、8 行预览与展开按钮已在窗口验证，朗读和翻译按钮无需滚到长选区底部。
- 网页选区用真实位置查找附近句子，1,040,055 字节正文的本机一次检查约 0.0002 秒；同词多次出现、emoji UTF-16 边界和非法范围通过。移除阅读器时取消待处理选区，防止快速切换后带回旧选区。
- 播放器改成浮层。播放前后 PDF 标题和摘要的屏幕位置相同；暂停、收起、停止已逐一验证，正文不重排。
- 原生窗口已显示「1/3 段，已生成 1 段」并开始播放，此时其他段落尚未生成。快速停止、重新朗读、再次停止后没有旧音频重新出现。
- 协议自动测试明确阻塞第二段推理，验证第一段已通过 HTTP 返回；另验证取消早于注册、推理中取消、后续出错仍先交付首段，以及长句切分无丢词。

真实模型基准：610 字符、7 段、24 kHz WAV；16 步推理，使用固定首段音色提示。结果保存于 `.runtime/logs/stream-benchmark.json`，可用 `python3 engine/benchmark_stream.py` 重测。

| 项目 | 本机实测 |
| --- | --- |
| 首次加载后的首段 | 8.658 秒 |
| 模型已加载，未缓存的新首段 | 2.962 秒 |
| 同长度整段接口，等待完整音频 | 25.756 秒 |
| 分段全部生成完毕（模型已加载） | 28.603 秒 |

本次主要缩短开始聆听的等待；分段总生成时间有额外调用开销。按照本次热启动片段到达时间和 WAV 时长计算，队列没有缓冲断档；冷启动出现一次约 0.855 秒的等待。实际播放衔接和延迟仍取决于选区、机器负载和模型加载状态，不承诺所有文本无间隙。此次更新保留已有用户数据。


## v0.1.0 完整离线包验收

目标：Apple Silicon（M 系列）、macOS 14+，建议至少 16 GB 内存；本机实测为 M2 Pro / 32 GB。

- 自包含 app：嵌入 CPython 3.11.17、完整 Python 推理依赖、Ollama 0.40.4、TranslateGemma 4B Q4_K_M、OmniVoice 固定快照及音频 tokenizer。运行时与模型标记均不含开发机绝对路径；Python venv 已展开为可重定位的嵌入式环境。
- 完整应用复制至 `.test-output/Relocated Mac Install/PaperLingo.app` 后，使用其中的解释器运行验证。8 个模型/元数据文件的尺寸和 SHA-256 校验通过，PyTorch 2.8.0 和 MPS 张量运算通过，OmniVoice/torchaudio/soundfile 可导入。
- 使用全新可写模型索引、独立回环端口和应用内权重完成真实翻译："A robust model should generalize beyond its training data." → "一个健壮的模型应该能够泛化到训练数据之外。" 本次用时 2.791 秒。
- 同一搬迁目录下完成 2 段 OmniVoice 生成，返回 24 kHz、16-bit、非静音 WAV；第一段 17.288 秒收到，第二段 22.898 秒收到。包含首次导入/模型载入时间。报告：`.test-output/offline-relocation-check/verification.json`。
- 退出开发版及旧残留服务后，启动搬迁后的原生 app；设置显示内置离线模型，两个模型均就绪。进程命令行确认使用搬迁后的 `Runtime/bin/ollama`、`Runtime/venv/bin/python` 和相对模型目录，而非原项目 `.runtime`。
- AppKit 终止回调同步停止本应用拥有的模型服务；原生窗口 CmdQ 退出后，两项模型进程均已消失。
- 真实推理后签名校验通过；日志、Ollama metadata、HF 缓存及音频写到用户 Engine 目录，应用资源保持完整。
- 13 项 PaperCore 检查通过（新增跨目录/用户目录迁移、模型链接更新和开发配置兼容），14 项 Python 检查通过。
- 安装包不包含个人论文、数据库、查询日志、私人录音或下载缓存；第三方模型许可、使用条款、作者信息及 Gemma Notice 已附带。

当前签名为 ad-hoc，未做 Developer ID 公证；新机器的 Gatekeeper 和通知授权须由使用者按系统提示处理。已验证本机不同路径下的独立启动和真实推理，未声称已在目标物理 Mac 上执行。

最终交付镜像：`dist/PaperLingo-0.1.0-macOS-arm64-offline.dmg`，6,506,532,203 字节（约 6.51 GB）。最终镜像通过 `hdiutil verify` CRC 校验、独立 SHA-256 复核，以及只读挂载后的完整 app 签名校验；应用内安装/迁移说明与源文件一致。SHA-256：`478b4b53c4852ec496546baab4703f71b189349dd17f1aed1a600a17dbd228e8`。结构化报告：`dist/PaperLingo-0.1.0-verification.json`。
