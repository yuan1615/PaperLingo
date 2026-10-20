# 离线应用与 DMG 分发

## 分发内容

源码仓库不包含运行时或模型。离线打包把本机已安装且验证过的资源整理为一个自包含 `PaperLingo.app`，再生成便于拖拽安装的 DMG。目标为 M 系列 Mac / macOS 14+，v0.2 完整研究模型建议至少 32 GB 内存。

模型的许可独立于源码 MIT 许可。当前完整模型包面向个人非商业学习；重新分发前阅读 [第三方说明](../THIRD_PARTY_NOTICES.md) 和 app 内的 Notice / 许可材料。

## 构建

以下命令按当前源码生成 v0.2.4。此前已验证并单独分发的完整模型镜像仍为 v0.2.3，不包含 v0.2.4 的长句修复；版本名不同的镜像应分别校验。

先完成 [开发指南](DEVELOPMENT.md) 中的基础与研究模型安装、真实推理检查，然后运行：

```bash
bash scripts/package-offline.sh

# 同一 APFS 卷可选择克隆大文件，减少暂存副本的实际磁盘占用
PAPERLINGO_CLONE_STAGE=1 PAPERLINGO_STAGE_ONLY=1 bash scripts/package-offline.sh
```

输出：

```text
dist/
  PaperLingo-0.2.4-Offline/
    PaperLingo.app
    Applications -> /Applications
    安装说明.txt
    Notice
  PaperLingo-0.2.4-macOS-arm64-offline.dmg
  PaperLingo-0.2.4-macOS-arm64-offline.dmg.sha256
```

`PAPERLINGO_CLONE_STAGE=1` 在 macOS/APFS 上优先以独立的写时复制文件暂存大模型和大运行库，不创建指向项目的链接；原项目删除或移动后，暂存 app 的文件仍独立存在。不支持克隆时回退到普通复制，空间预检仍按完整逻辑体积计算。

DMG 使用 `ULFO`（LZFSE）压缩，适用于本项目的 macOS 14+ 目标；打包时输出 `hdiutil` 阶段进度，避免大型权重使用 zlib 时的较长压缩等待。

主程序使用原子写入，最终签名后再以相同字节刷新为新文件。若通过 APFS 克隆自行安装，可在启动前执行以下操作后验证签名；脚本不修改签名内容，也不关闭系统安全检查：

```bash
APP=/Applications/PaperLingo.app
python3 scripts/replace-executable.py \
  "$APP/Contents/MacOS/PaperLingo" "$APP/Contents/MacOS/PaperLingo"
codesign --verify --deep --strict "$APP"
```

脚本拒绝覆盖已有分发 app 中的 `Runtime/`。重新构建前先把旧 `dist/PaperLingo-0.2.4-Offline/` 整体移到其他目录保存，再执行脚本，避免混用旧资源。

## 搬迁检查

也可先只生成 app，在另一个目录检查后再制作镜像：

```bash
PAPERLINGO_STAGE_ONLY=1 bash scripts/package-offline.sh

# 将整个 app 完整复制到另一个目录，路径可包含空格
mkdir -p /tmp/paperlingo-relocated
cp -R dist/PaperLingo-0.2.4-Offline/PaperLingo.app /tmp/paperlingo-relocated/

# 用搬迁后 app 自己的 Python 校验权重、导入、MPS 和真实推理
APP=/tmp/paperlingo-relocated/PaperLingo.app
PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
  "$APP/Contents/Resources/Runtime/venv/bin/python" \
  "$APP/Contents/Resources/engine/verify_portable.py" \
  --app "$APP" --work /tmp/paperlingo-portable-check --smoke

# 确认资源签名未被推理改写，再从原分发目录制作镜像
codesign --verify --deep --strict "$APP"
PAPERLINGO_IMAGE_ONLY=1 bash scripts/package-offline.sh
hdiutil verify dist/PaperLingo-0.2.4-macOS-arm64-offline.dmg
```

校验 SHA-256 时需先进入校验文件所在目录：

```bash
cd dist
shasum -a 256 -c PaperLingo-0.2.4-macOS-arm64-offline.dmg.sha256
```

上述检查不替代目标物理机器上的验收。`--smoke` 会启动专用回环端口上的引擎，结束时停止自己创建的服务；不操作用户学习数据库。

2026-10-16 的 v0.2.3 完整镜像已通过镜像 CRC、独立 SHA-256 复核，以及挂载后推理结束时的严格 app 签名检查。只读镜像中的内置 Python / PyTorch / MPS 正常，17 个模型文件校验一致；真实翻译、分段音频和重排测试通过。另用同一离线 app 中的 Ollama 验证前三页中文摘要与 1024 维跨语言检索，素材明确为合成诊断。结果保存在本机 `dist/PaperLingo-0.2.3-verification.json`；未在另一台物理 Mac 上验收。首次从新路径启动时，曾观察到 macOS 系统校验等待，应给其完成时间。

## 内部布局

- 独立 CPython 与 venv 的依赖合并，解释器链接使用相对路径，不依赖系统 Python 或 Homebrew。
- Hugging Face 快照解引用为实体文件，OmniVoice 标记使用相对模型路径。
- Python、Ollama、权重和许可放在 app 的只读资源树中。
- 日志、音频、HF 缓存和可写 Ollama metadata 放入用户 Application Support；权重通过文件链接访问，不复制到用户缓存。
- `distribution.json` 记录版本及每个模型文件的尺寸 / SHA-256。退出后移动 app，下次启动会更新用户目录中的权重链接。

## 签名、公证与发布

默认签名为本机 ad-hoc，未做 Apple Developer ID 公证。`PAPERLINGO_SIGN_IDENTITY` 可指定签名身份，但它不自动配置 hardened runtime、notarization 或 stapling；正式商业分发需要另行验证完整签名流程及模型许可。

此前 v0.1 离线镜像约 6.5 GB；v0.2.3 研究、向量与重排模型共新增约 19.3 GB。当前完整 DMG 为 25,009,271,792 字节（25.01 GB / 23.29 GiB），展开的 app 约 27.48 GB，旁边附有 SHA-256 和中文安装说明。完整镜像仅在本地生成并单独分发，未上传 GitHub。脚本从 Info.plist 读取版本，不会覆盖旧分发目录；模型不齐全时拒绝打包，下载中的 partial 文件不入包。阶段副本与压缩镜像需要大量额外空间，脚本会在复制和压缩前分别预检。不要将 DMG、模型或 Python 环境提交到 Git；GitHub 单个 Release asset 也有尺寸限制，完整镜像需使用合适的独立分发渠道或另行设计可校验的分卷方案。GitHub Releases 中的源码归档不能直接双击安装。参考 [GitHub 大文件与 Release 文档](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)。

## 用户安装与数据迁移

见 [packaging/INSTALL-zh.txt](../packaging/INSTALL-zh.txt)。安装包不包含开发者或用户的论文、词库、查询日志、录音或通知偏好。迁移学习数据时先退出两台 app，复制完整数据目录并保留存在的 SQLite WAL / SHM 文件。
