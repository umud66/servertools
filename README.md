# Server Deploy Tool

一个交互式服务器部署脚本，面向新机器初始化和代理服务部署，优先适配 Ubuntu。

## 功能

- 菜单式操作
- Ubuntu 软件源测速与自动切换
- Ubuntu 场景下启用 BBR 加速
- 预检查、运行日志、启动后校验
- IP、流媒体、AI 服务解锁初筛
- 域名管理
  - 支持覆盖已有域名配置
  - 支持按编号或按域名删除
  - 旧配置缺少 `DOMAIN=` 时会按文件名自动补全并自动编号
- 证书配置
  - 手动指定证书公私钥路径
  - 使用 Let's Encrypt 自动签发
- 安装并配置 `trojan-go`
  - 使用域名证书
  - 支持配置伪装回落地址和端口
  - 自动生成 WebSocket 配置
- 安装并配置 `hysteria2`
  - 直接填写域名、邮箱、密码
  - 使用 Hysteria2 内置 ACME 自动签发证书
- 提供快速部署向导

## 文件

- `deploy_server.sh`：主脚本

## 使用方法

```bash
chmod +x deploy_server.sh
sudo ./deploy_server.sh
```

## 推荐部署流程

1. 先执行“优化 Ubuntu 软件源”
2. 执行“安装基础依赖”
3. 执行“安装/启用 BBR”
4. 先进入“保护检查”执行一次预检查
5. 安装并配置 `Hysteria2`
6. 如需 `Trojan-Go`，再进入“域名与证书管理”添加域名和证书
7. 进入“测试工具”检查公网 IP、流媒体和 AI 服务可访问性

## 说明

- 域名配置保存在 `/etc/server-deploy-tool/domains`
- Trojan-Go 固定配置为 `/etc/trojan-go/config.json`
- Hysteria2 固定配置为 `/etc/hysteria2/config.yaml`
- 脚本记录配置分别保存在 `/etc/trojan-go/server-deploy.conf` 和 `/etc/hysteria2/server-deploy.conf`
- BBR 配置保存在 `/etc/sysctl.d/99-server-deploy-tool-bbr.conf`
- 运行日志保存在 `/etc/server-deploy-tool/runtime/deploy.log`
- 优化 Ubuntu 软件源时会备份 `/etc/apt/sources.list` 或 `/etc/apt/sources.list.d/ubuntu.sources`
- Hysteria2 默认监听 UDP 443
- 测试工具使用当前服务器出口 IP 发起请求，不会通过已配置的代理链路测试客户端连接
- 使用 Let's Encrypt standalone 签发时，如果 `80` 端口被占用，脚本会询问是否释放端口

## 注意事项

- 使用 Let's Encrypt 或 Hysteria2 ACME 时，需要域名已解析到当前服务器
- 签发证书前需保证 `80` 端口可访问
- 释放 `80` 端口会先停止 `apache2`、`httpd`、`caddy`，仍占用时才按 PID 结束进程
- 当前脚本按单服务配置设计，重新配置会覆盖上一份 Trojan-Go 或 Hysteria2 配置，并清理旧的 `@` 服务单元
- BBR 依赖内核支持，若写入后未生效，通常需要检查内核模块或重启服务器
- 软件包安装本身无法事务化回滚，当前脚本改为偏保守策略：先预检查，再做端口冲突检查、配置校验和服务存活校验
- 流媒体和 AI 检测是快速初筛，平台策略会变化，最终结果仍建议结合账号和客户端实测确认
