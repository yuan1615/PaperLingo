# Security policy

## Supported version

目前维护 v0.4.x。PaperLingo 本地引擎监听回环地址。用户可以为特定任务选择 OpenAI，在线请求使用官方 HTTPS 或加密 WebSocket 接口。

## Reporting a vulnerability

请使用仓库的 [私有漏洞报告入口](https://github.com/yuan1615/PaperLingo/security/advisories/new)，提供受影响版本、最小复现步骤、影响范围和已脱敏的日志。请勿在公开 Issue 中提交未修复漏洞的利用细节、凭据、私人论文或学习数据库。

若私有报告入口暂不可用，可创建不含敏感细节的 Issue 请求维护者提供私下沟通方式。

## Local data

论文、词库和复习记录保存在当前用户的 Application Support 目录，没有额外的应用层加密。请按自己的设备与备份需求保护这些文件。在线导入网页和首次模型下载仍需要连接相应上游站点。

## OpenAI credentials and requests

API Key 由用户在 App 内输入，保存于本机登录钥匙串，关闭钥匙串项目同步。项目源码、配置文件、偏好设置、导出文件和发行包均不保存该密钥。换机时请重新配置。若密钥泄露，请在 OpenAI 项目撤销并重新创建密钥。

翻译、摘要、生词讲解和朗读默认本地运行。选择 OpenAI 后，翻译发送选区，生成 PDF 摘要时发送完整 PDF 字节（包括文件内的元数据、图表、批注和附录），网页摘要发送开头文字，词语讲解发送表达和原句片段，朗读发送清理后的文本。线上客户端只允许固定的 OpenAI 接口，拒绝重定向。错误提示不会显示响应原文或鉴权请求头。文本请求使用 `store: false`。服务端仍可能按平台政策保留滥用监测日志。[OpenAI 数据控制说明](https://developers.openai.com/api/docs/guides/your-data)

口语练习由用户主动开始，通过 Realtime WebSocket 发送麦克风音频、教练指令及选中的论文或词条材料。切换模式沿用本次会话。关闭练习或离开该页面会结束连接。应用在内存中接收转写，用户主动生成复盘时会把最近最多 12 段自己的转写发送到 Responses API。只有用户选择保存的表达和关联材料会写入本机数据库。
