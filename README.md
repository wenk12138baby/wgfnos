# WireGuard 组网

飞牛 fnOS 的 WireGuard 加密组网应用配套资源。

## 中转网关部署脚本

用于「打洞失败（无公网 IP / 严格 NAT）」场景，在用户自己的 VPS 上部署 WireGuard 中转网关。

### 一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/wenk12138baby/wgfnos/main/scripts/wg-gateway-install.sh | sudo bash
```

### 部署后

脚本会输出一段 JSON 配置，复制回 NAS 管理页面的「中转服务器」标签页即可完成配置。

## 目录结构

-  - VPS 中转网关一键部署脚本
