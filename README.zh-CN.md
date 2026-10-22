# Balatro for Nintendo 3DS

[English](README.md) | **简体中文**

扑克 Roguelike。Balatro 是一款令人上瘾的牌组构筑游戏：打出“违规”的扑克牌型、收集能改变玩法的小丑牌，触发肾上腺素飙升的夸张连招 —— 现在它来到了 3DS 上。

这是 Balatro 的同人重制版。本项目与 Balatro 的作者 LocalThunk 没有任何关联。所有美术与音效资源均来自原游戏，仅为在 3DS 硬件上运行做了适配。如果你想支持作者，或想体验完整的 Balatro，请购买原版游戏。

它运行在 [LövePotion](https://github.com/lovebrew/lovepotion) 之上 —— 这是 TurtleP 为自制固件主机实现的 LÖVE API。

## 安装

最方便的安装方式是使用 FBI。打开 [releases 页面](https://github.com/idkhan/Balatro3DS/releases)，用 FBI 的 “Remote Install” 功能扫描二维码即可。

CIA 未签名，因此安装需要带 sigpatch 的自制固件。如果你不想安装成一个标题（title），releases 页面也提供 `.3dsx`：把它放进 SD 卡根目录的 `3ds` 文件夹，再从 Homebrew Launcher 启动。

## 操作

下屏是牌桌，也是唯一的触摸区域；上屏是信息显示区。你可以完全用手柄按键游玩，完全用触摸游玩，或两者混用。

按键布局沿用 Balatro 在 Switch 上的方案，因为 3DS 的 ABXY 排列与之一致：

- **A** —— 选中。按住后按方向键可调整顺序。
- **B** —— 取消选中、出售；在未选中任何牌时用于排序。按住后按方向键可批量扫过。
- **X** —— 弃牌；在商店中为刷新。
- **Y** —— 出牌；在商店中为购买并使用。
- **L / R** —— 切换小丑牌面板与消耗品面板。

这六个按键都可以在“选项”中重新绑定；在 New 3DS 上还可以额外绑定 ZL 和 ZR。

## 性能说明

**本移植版已在 New 3DS 和 Old 3DS 上测试过**

在初代 3DS 上有若干项目被有意降低或关闭，因为它的 CPU 性能弱得多。部分粒子特效会以更粗的粒度绘制。

## Mod 支持

游戏加载 [Steamodded](https://github.com/Steamodded/smods) 风格的 Mod：一个包含 `.json` 清单文件的文件夹，加一个调用 `SMODS.Joker { ... }` 等接口的 Lua 文件。Mod 可以添加小丑牌、塔罗牌、星球牌、幻灵牌、凭证，以及用于 **选项 → 美术** 的整组人头牌贴图。

安装 Mod 时，把它的文件夹复制到游戏在 SD 卡上存档旁创建的 `mods` 文件夹（`/3ds/save/Balatro3DS/sdmc/mods`），然后重启游戏。**选项 → Mods** 会列出已加载的内容，以及未能加载的原因。

已保存的牌局会记住它当时使用了哪些 Mod。如果这些 Mod 发生变化，“继续”会提示需要安装或移除哪些内容；牌局本身会被保留。

这不是 Steamodded 本身。这里没有 Lovely，没有 PC 版游戏的内部实现，3DS 也无法运行着色器。每张牌都是独立的 `.t3x` 图片，Negative 牌需要自己的一套贴图。[MODDING.md](MODDING.md)（该文档目前只有英文版）介绍了完整 API，[`dev/example_mods/ExampleJokers`](dev/example_mods/ExampleJokers) 是一个可直接运行的示例，`dev/make_negative.py` 可以把一张牌的贴图转成它的 Negative 版本。

## 自行构建

`./dev/setup.sh` 会拉取 devkitPro 的 3DS 软件包、构建打过补丁的 LövePotion 运行时，并下载所需的宿主工具。随后 `./dev/build.sh` 生成 CIA，`./dev/build.sh 3dsx` 则生成融合好的 `.3dsx`；产物位于 `dev/dist/`。[BUILD.zh-CN.md](BUILD.zh-CN.md) 记录了更早的手动 `.3dsx` 制作流程，那是面向最终用户而非开发者的。

测试在 LuaJIT 下无头运行：`./tests/run.sh` —— 不需要 3DS 主机或 LÖVE 可执行文件。

## 许可证

本项目按原样提供，仅用于学习与爱好者用途。再分发前请先查看仓库的许可证文件。
