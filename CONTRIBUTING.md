# Contributing

感谢你帮助改进 PaperLingo。请先查看 [README](README.md)、[产品设计](docs/PRODUCT.md) 与 [开发指南](docs/DEVELOPMENT.md)。

## 报告问题

使用 GitHub 的 Bug 表单，说明 macOS、芯片、内存、版本、复现步骤及预期 / 实际行为。涉及模型时注明使用 OmniVoice 还是系统语音，并附上已脱敏的相关错误日志。请勿提交个人论文、词库、数据库、原始录音或凭据。

功能建议请说明阅读或学习中遇到的具体问题及希望的交互。较大的架构或数据格式调整建议先在 Issue 中讨论。

## 提交代码

1. Fork 仓库，从 `main` 建立主题分支。
2. 保持改动聚焦，遵循相邻 Swift / Python 代码约定。
3. 修改行为或接口时同步更新文档；测试应验证用户行为或协议边界。
4. 运行相关检查，并在 PR 中说明改动原因、验证结果及限制。

```bash
swift run --disable-sandbox PaperCoreChecks
python3 -m unittest discover -s engine/tests -v
bash scripts/build-app.sh
```

上述检查不下载模型。涉及推理或播放时，再按开发指南运行真实模型验收；不要把协议模拟检查当作音质、翻译质量或跨机器验证。

提交信息建议使用 `feat: ...`、`fix: ...`、`docs: ...`、`test: ...` 或 `chore: ...`。PR 应解释具体问题、最终行为和必要的验证，不提交 `.runtime`、`dist`、个人数据或模型权重。

## 许可

你提交的自有代码将按本项目 MIT 许可证分发。引入第三方代码或资源时，请保留归属并更新 [第三方说明](THIRD_PARTY_NOTICES.md)。源码许可不改变模型权重的许可限制。
