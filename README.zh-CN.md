[English](README.md) | 简体中文

<img src="docs/assets/deva-hero.svg" alt="deva.sh" width="640">

[![CI](https://img.shields.io/github/actions/workflow/status/thevibeworks/deva/ci.yml?branch=main&label=ci)](https://github.com/thevibeworks/deva/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thevibeworks/deva?sort=semver)](https://github.com/thevibeworks/deva/releases)
[![Docs](https://img.shields.io/badge/docs-docs.deva.sh-111111)](https://docs.deva.sh)
[![License](https://img.shields.io/github/license/thevibeworks/deva)](LICENSE)

在 Docker 里跑 Claude Code、Codex、Gemini、Grok、Kimi 五个 agent CLI，并且不再假装 agent 自带的权限弹窗是在保护你。

核心就四条：

- 容器即沙箱。五个 agent 全在容器里跑，agent 自带的权限系统全部关掉（`claude --dangerously-skip-permissions`、`codex --dangerously-bypass-approvals-and-sandbox`、`gemini --yolo`、`grok --always-approve`、`kimi --yolo`）。隔离靠 Docker，不靠 permission theater。
- 挂载即契约。跨越主机边界的只有你显式挂载的东西，没有暗箱行为。
- 一个项目一个常驻容器，五个 agent 共用。包、构建缓存、临时状态保温，不用每次重建。
- 它就是一个 bash 脚本，不是框架。

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
