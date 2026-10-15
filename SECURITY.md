# Security policy

## Supported version

目前只维护最新的 v0.1.x 版本。PaperLingo 是本地桌面应用；语音和翻译接口设计为仅监听回环地址，不应直接暴露到局域网或公网。

## Reporting a vulnerability

请使用仓库的 [私有漏洞报告入口](https://github.com/yuan1615/PaperLingo/security/advisories/new)，提供受影响版本、最小复现步骤、影响范围和已脱敏的日志。请勿在公开 Issue 中提交未修复漏洞的利用细节、凭据、私人论文或学习数据库。

若私有报告入口暂不可用，可创建不含敏感细节的 Issue 请求维护者提供私下沟通方式。

## Local data

论文、词库和复习记录保存在当前用户的 Application Support 目录，没有额外的应用层加密。请按自己的设备与备份需求保护这些文件。在线导入网页和首次模型下载仍需要连接相应上游站点。
