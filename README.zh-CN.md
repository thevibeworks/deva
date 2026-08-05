[English](README.md) | 简体中文

<img src="docs/assets/deva-hero.svg" alt="deva.sh" width="640">

[![CI](https://img.shields.io/github/actions/workflow/status/thevibeworks/deva/ci.yml?branch=main&label=ci)](https://github.com/thevibeworks/deva/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thevibeworks/deva?sort=semver)](https://github.com/thevibeworks/deva/releases)
[![Docs](https://img.shields.io/badge/docs-docs.deva.sh-111111)](https://docs.deva.sh)
[![License](https://img.shields.io/github/license/thevibeworks/deva)](LICENSE)

在 Docker 里跑 Claude Code、Codex、Gemini、Grok、Kimi 五个 agent CLI，并且不再假装 agent 自带的权限弹窗是在保护你。

容器即沙箱，挂载即契约。这换来的是：

- 全速跑 agent。权限弹窗存在的理由是爆炸半径等于你的整机；把爆炸半径缩小到一个容器，YOLO 就不再是鲁莽 —— 五个 agent 全部关掉自带权限系统跑（`claude --dangerously-skip-permissions`、`codex --dangerously-bypass-approvals-and-sandbox`、`gemini --yolo`、`grok --always-approve`、`kimi --yolo`）。最坏结果随容器一起销毁。
- 厂商代码永远见不到你的主机。agent CLI 是快速迭代、带自动更新的 npm 依赖树；在这里它们出生在镜像里：没有 `~/.ssh`、没有 `~/.aws`、没有 shell 环境变量汤、没有浏览器档案。想收集也无从下手。
- 跨越边界的一切都是显式的。文件靠挂载，密钥靠你传的 env，网络靠你选的姿态 —— 默认 bridge、走你的代理、`--host-net`、或者干脆不联网。你没接的线，agent 就没有。
- 身份是启动参数，不是全局单例。`~/.config/deva/` 下按 agent 分家，`--auth-with` / `--config-home` 切第二个账号或 API-key 计费。按次切账号，项目、会话、容器状态原地不动。
- 官方 CLI，原封不动。不做协议转译、不用山寨客户端、credentials 不过任何中间人代理。兼容层是容器，不是协议 shim —— 最好的模型永远配它自家最好的 harness。
- 手感和裸 CLI 一样。同一个 cwd、同一个 TTY、同一套 OAuth。每个项目一个保温容器，包和构建缓存常热。它就是一个 bash 脚本，不是框架。

## Quick Start

60 秒能跑通：

```bash
curl -fsSL https://raw.githubusercontent.com/thevibeworks/deva/main/install.sh | bash

cd ~/work/my-project
deva.sh codex
```

如果你本地已经在用这些 agent，deva 会默认把它们的 auth 目录自动链接到 `~/.config/deva/` 下的独立配置家目录；没有的话，首次运行会让你在容器里登录。

## 常用命令

```bash
deva.sh                  # 默认 agent 是 Claude
deva.sh codex            # 同一个容器，换 agent
deva.sh gemini
deva.sh grok
deva.sh kimi

deva.sh claude --rm      # 一次性容器，用完即扔
deva.sh claude --debug --dry-run   # 先看 docker run 长啥样再信它
deva.sh shell            # 进项目容器的 shell
deva.sh ps               # 看容器
deva.sh stop             # 停掉
deva.sh --show-config    # 看解析后的配置
```

## 这不是什么

- 不是安全魔法。挂载 `/var/run/docker.sock` 等于给了 host root，只是多绕了一步 —— deva 会明说。真不需要 Docker-in-Docker 就用 `--no-docker`。
- 把整个 home 读写挂进去再给 agent 危险权限，agent 就能动你整个 home。就是这么神奇。
- `--host-net` 给容器完整的网络可见性，想清楚再用。
- 不是通用 devcontainer 平台。

安全边界的完整说明见 [SECURITY.md](SECURITY.md)。

## 镜像

稳定版：

- `ghcr.io/thevibeworks/deva:latest`
- `ghcr.io/thevibeworks/deva:rust`
- `ghcr.io/thevibeworks/deva:cloak`（CloakBrowser 隐身 Chromium，headed；`deva.sh -p cloak`）

每日刷新：`ghcr.io/thevibeworks/deva:nightly`、`ghcr.io/thevibeworks/deva:nightly-rust`

## 文档

全部在 [docs.deva.sh](https://docs.deva.sh)：Quick Start、认证、工作原理、进阶用法、排障、设计哲学。

AI agent / LLM 请直接读 [llms.txt](llms.txt)，一次抓取看完整个产品。

## License

MIT，见 [LICENSE](LICENSE)。
