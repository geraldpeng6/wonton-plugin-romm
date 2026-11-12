# 云吞插件：RomM

把共享文件夹里的游戏 ROM 整理成网页游戏库：扫描、检索、看封面和介绍，点开就在浏览器里玩（模拟器内置）。登录走云吞的账号（OIDC），打开就进库。

RomM 是上游应用（[rommapp/romm](https://github.com/rommapp/romm)，AGPL-3.0），本插件用它的官方多架构镜像 `rommapp/romm`，MariaDB 数据库放在同一个插件里，Redis 用镜像内置的 valkey（上游文档的默认做法）。

## 使用

- 游戏文件放共享文件夹 **games**，按上游 5.x 的库结构：`games/roms/<平台>/`（如 `games/roms/gba/` 放 GBA 的 ROM，命名规则见 [RomM 文档的 Folder Structure](https://docs.romm.app/latest/getting-started/folder-structure/)）；也可以在网页里直接上传。
- 应用发的信（密码重置、通知确认码）会出现在你的 Wonton 私聊里；通知渠道填云吞以外的邮箱收不到，RomM 会报发送失败。
- 封面、介绍等元数据靠 IGDB、ScreenScraper 这类外部服务，要用户自己的 API 密钥。本插件不预填密钥（云吞没有让用户自填密钥的地方），扫描和游玩不依赖元数据。

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。

## 图标

`icon.svg` 是 RomM 的官方标志（isotipo），来源与商标说明见 [NOTICE](NOTICE)。

## 开发

```bash
scripts/check.sh --official   # 检查插件包
scripts/dev.sh up             # 起开发环境
scripts/dev.sh probes         # 跑插件探针
scripts/dev.sh smoke          # 端到端冒烟
```

流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，规则见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。
