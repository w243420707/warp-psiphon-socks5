# WARP-plus Socks5 多地区 Psiphon 一键脚本

这是从 `https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh` 里单独提取出来的：

`启用WARP-plus-Socks5多地区Psiphon代理模式`

脚本文件：

```bash
warp_psiphon_socks5.sh
```

## 快速使用

上传到 VPS 后用 root 运行：

```bash
bash warp_psiphon_socks5.sh
```

运行后会先从 `bepass-org/warp-plus` 上游 README 自动刷新当前 Psiphon 支持地区，再要求输入两位国家/地区代码，例如 `JP`、`SG`、`US`。如果上游访问失败，会使用脚本内置备用列表。

默认参数：

- Socks5 地址：`127.0.0.1:40000`
- 国家地区：无默认值，必须选择或指定
- 模式：多地区 Psiphon，等同原脚本的 `--cfon --country XX`
- 开机自启：优先 systemd，非 systemd 环境回退到 cron
- 环境依赖：自动识别系统包管理器和 CPU 架构，只补装缺失依赖，已存在的不会重复安装

指定国家和端口：

```bash
bash warp_psiphon_socks5.sh install JP 40000
```

非交互运行时必须指定地区，例如：

```bash
COUNTRY=SG PORT=40000 bash warp_psiphon_socks5.sh install
```

## 管理命令

```bash
bash warp_psiphon_socks5.sh status
bash warp_psiphon_socks5.sh restart US 40000
bash warp_psiphon_socks5.sh stop
bash warp_psiphon_socks5.sh uninstall
```

## 支持地区

脚本每次 `install/start/restart` 会自动抓取最新地区列表：

`https://raw.githubusercontent.com/bepass-org/warp-plus/master/README.md`

当前内置备用列表：

`AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US`

## 安装位置

- 主目录：`/usr/local/warp-plus-psiphon`
- 配置：`/etc/warp-plus-psiphon.env`
- systemd 服务：`warp-plus-psiphon.service`

## 说明

这个独立版不会安装 x-ui 面板，也不会修改 x-ui 配置。它只下载原项目的 `xuiwpph_amd64` 或 `xuiwpph_arm64` 二进制，并按原功能启动本地 Socks5 代理。
