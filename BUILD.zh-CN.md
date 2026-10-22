# 构建说明

[English](BUILD.md) | **简体中文**

本文档介绍如何在自己的机器上手动制作并打包 `Balatro3DS.3dsx` 文件。其他构建方式可参考 [Lovebrew wiki](https://lovebrew.org)。你需要先安装 devkitPro 及其 `3ds-dev` 软件包，安装方法见 [devkitPro wiki](https://devkitpro.org/wiki/Getting_Started)。

感谢 lovebrew discord 里的 @natesquared，以下步骤基于他提供给另一位用户的类似说明整理。

> [!IMPORTANT]
> 这套流程把游戏融合到官方发布的原版 LövePotion 上，而它缺少本移植版依赖的五处修复。用这种方式构建出的版本可以启动和游玩，但音效会丢失变调，音乐交叉淡入淡出会跳到错误位置，声音重叠时可能直接把主机搞崩，菜单显示的也是旧的预烘焙动画而不是生成的背景。
>
> 如果你只是想玩，请直接从 [releases 页面](https://github.com/idkhan/Balatro3DS/releases)下载构建好的版本。如果你是在参与本移植版的开发，请改用 `./dev/setup.sh` 和 `./dev/build.sh` —— 它们会构建打过补丁的运行时，并替你处理资源转换、音乐降采样和 CIA 打包。

## Windows

与下面的 Linux 和 macOS 流程不同，这里用 `./dev/setup.sh` 和 `./dev/build.sh` 构建打过补丁的运行时，因此你能得到功能完整的 `.3dsx` 和 `.cia`。这些脚本是为 macOS 和 Linux 编写的，所以需要先替换掉几个工具。

> [!IMPORTANT]
> 本节所有命令都必须在 **devkitPro 的 MSYS2 shell** 中运行，而不是 Git Bash、PowerShell 或 cmd。用 `C:\devkitPro\msys2\usr\bin\bash.exe -l` 打开它（或使用 devkitPro 添加到开始菜单的 “MSYS2” 快捷方式）。Git Bash 看不到 devkitPro 的工具。

1. 用 [Windows 安装器](https://github.com/devkitPro/installer/releases)安装 devkitPro，在询问时勾选 **3DS Development**。然后安装 LövePotion 所需的库，以及 `rsync` 和 `patch`。缺少 `patch` 时，LövePotion 会静默跳过它的 3DS luasocket 修复，运行时将在 `net/if.h` 处编译失败。

先做一次完整更新。混用新旧 MSYS2 软件包会弄坏工具：比如比其 `libcurl` 更新的 `curl` 甚至无法启动。

```sh
    pacman -Syu
    pacman -S --needed 3ds-dev 3ds-cmake 3ds-box2d 3ds-curl 3ds-flac 3ds-libconfig \
        3ds-libjpeg-turbo 3ds-libmodplug 3ds-libogg 3ds-libpng 3ds-libtheora \
        3ds-libvorbisidec 3ds-liblua51 3ds-lz4 3ds-mbedtls 3ds-physfs 3ds-tinyxml2 \
        3ds-zlib rsync patch
```

2. 在 Windows 上安装 ffmpeg 和 Python 3.13 或更新版本。`patch_lovepotion.py` 需要 3.13，而 devkitPro 的 MSYS2 只带 3.12。在 PowerShell 中执行：

```powershell
    winget install Gyan.FFmpeg.Essentials
    winget install Python.Python.3.14
```

然后记下它们各自的安装位置。第 4 步会用到这两个路径。

```powershell
    (Get-Command ffmpeg).Source
    py -3.14 -c "import sys; print(sys.executable)"
```

3. 克隆仓库。后续所有命令都在仓库根目录下执行。

```sh
    git clone https://github.com/idkhan/Balatro3DS.git
    cd Balatro3DS
```

4. 在 `dev/.tools`（已加入 gitignore）中准备 Windows 工具。`setup.sh` 只会下载 makerom 和 bannertool 的 macOS 与 Linux 版本，因此 Windows 版本需要你自己下载：

```sh
    mkdir -p dev/.tools/bin
    curl -fL https://github.com/3DSGuy/Project_CTR/releases/download/makerom-v0.19.0/makerom-v0.19.0-win_x86_64.zip -o dev/.tools/makerom.zip
    curl -fL https://github.com/Epicpkmn11/bannertool/releases/download/v1.2.2/bannertool.zip -o dev/.tools/bannertool.zip
    unzip -jo dev/.tools/makerom.zip makerom.exe -d dev/.tools
    unzip -jo dev/.tools/bannertool.zip windows-x86_64/bannertool.exe -d dev/.tools
    rm dev/.tools/*.zip
```

接下来创建几个小的包装脚本，用来代替 `dkp-pacman`、`ffmpeg`、`python3` 和 `oggenc`。把两个路径替换成第 2 步得到的结果。引号要保留，并把 `C:\` 改成使用正斜杠的 `/c/`。

```sh
FFMPEG_EXE="/c/path/to/ffmpeg.exe"
PYTHON_EXE="/c/path/to/python.exe"

printf '#!/usr/bin/env bash\nexec /usr/bin/pacman "$@"\n' > dev/.tools/bin/dkp-pacman
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$FFMPEG_EXE" > dev/.tools/bin/ffmpeg
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PYTHON_EXE" > dev/.tools/bin/python3

# build.sh only ever calls `oggenc -Q -b <kbps> -o <out> -`; ffmpeg's libvorbis does the same job.
cat > dev/.tools/bin/oggenc <<'EOF'
#!/usr/bin/env bash
bitrate=128 out="" in="pipe:0"
while (( $# )); do
    case "$1" in
        -Q) ;;
        -b) bitrate="$2"; shift ;;
        -o) out="$2"; shift ;;
        -) ;;
        *) in="$1" ;;
    esac
    shift
done
exec ffmpeg -hide_banner -loglevel error -y -i "$in" -c:a libvorbis -b:a "${bitrate}k" -f ogg "$out"
EOF

cat > dev/.tools/env-windows.sh <<'EOF'
_tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$_tools/bin:$PATH"
export MAKEROM="$_tools/makerom.exe"
export BANNERTOOL="$_tools/bannertool.exe"
unset _tools
EOF

chmod +x dev/.tools/bin/*
```

5. 构建打过补丁的 LövePotion 运行时。这一步会克隆 LövePotion、应用本移植版的修复并编译它，需要几分钟。只需做一次，之后仅在 `dev/patch_lovepotion.py` 变化时重做。

```sh
    source dev/.tools/env-windows.sh
    ./dev/setup.sh
```

> [!NOTE]
> 如果编译进行到 `[252/252]`，然后在 `Translating .../compile_commands.json` 之后报错退出，运行时其实已经构建成功了。那个报错来自脚本末尾的构建类型报告。确认 `dev/.cache/lovepotion/build/main.release/lovepotion.elf` 存在，然后继续即可。

6. 构建游戏。`all` 会同时生成两种格式，`3dsx` 或 `cia` 只生成其中一种。在任何新开的 shell 里都要先执行 `source dev/.tools/env-windows.sh`。

```sh
    ./dev/build.sh all
```

产物位于 `dev/dist/`：

- `Balatro3DS.3dsx`：复制到 SD 卡根目录的 `3ds` 文件夹，再从 Homebrew Launcher 启动。
- `Balatro.cia`：用 FBI（或其他 CIA 安装器）安装，之后会出现在主菜单上。

## Linux 与 macOS

1. 先创建一个文件夹来存放所有文件。

```sh
    mkdir build_dir
    cd build_dir
```

2. 前往 [lovepotion github](https://github.com/lovebrew/lovepotion/releases) 的 releases 页面，下载名为 `Nintendo.3DS-[xxxxxxx].zip` 的文件。把这个文件夹解压到上一步创建的目录中。文件结构应如下所示：

```
    build_dir/
    └── Nintendo.3DS-[xxxxxxx]/ <- the `xxxxxxx` is just a random set 
        ├── lovepotion.3dsx        of 7 characters based on whatever 
        └── lovepotion.elf         was on the releases page.
```

3. 克隆 lovebrew 仓库。（稍后我们需要其中的 romfs 文件夹。）

```sh
    git clone https://github.com/lovebrew/lovepotion.git lovepotion && rm -rf lovepotion/.git
```

4. 克隆 Balatro3DS 仓库。

```sh
    git clone https://github.com/idkhan/Balatro3DS.git Balatro3DS && rm -rf Balatro3DS/.git

```

5. 新建一个名为 `build` 的文件夹。把 Balatro3DS 文件夹复制进去，并改名为 `game`。我们生成的所有文件都会放在这个文件夹里。

```sh
    mkdir build
    cp -r Balatro3DS build/game
```
此时你的文件夹结构应如下所示。
```
    build_dir/
    ├── Balatro3DS/
    │   └── ...
    ├── build/
    │   └── game/ 
    │       └── ...
    ├── lovepotion/
    │   └── ...
    └── Nintendo.3DS-[xxxxxxx]/
        └── ...
```

6. 删除游戏不会加载的文件。这不是在做清理 —— `mkbcfnt` 会光栅化字体中的每一个字形，而仓库里那七个 CJK 与 Noto 字体展开后合计约 599 MB 的 `.bcfnt`。实际只会加载 `m6x11plus`，且它的 `.bcfnt` 已经提交在仓库里。请保留 `menu.png`：原版运行时无法生成菜单背景，所以菜单会播放这段预烘焙动画作为替代。

```sh
    rm -f build/game/resources/fonts/GoNotoCJKCore.ttf \
          build/game/resources/fonts/GoNotoCurrent-Bold.ttf \
          build/game/resources/fonts/NotoSans-Bold.ttf \
          build/game/resources/fonts/NotoSansJP-Bold.ttf \
          build/game/resources/fonts/NotoSansKR-Bold.ttf \
          build/game/resources/fonts/NotoSansSC-Bold.ttf \
          build/game/resources/fonts/NotoSansTC-Bold.ttf \
          build/game/resources/fonts/m6x11plus.ttf
    rm -rf build/game/dev build/game/tests build/game/reference build/game/.git
```

7. 接下来把剩余的图片和字体转换成 `.t3x` 与 `.bcfnt` 文件。`&& rm $0` 部分是可选的，它只是删除原始文件以节省空间。
> [!NOTE]
> 这一步耗时较长，请耐心等待。
```sh
    find ./build/game -type f -name "*.png" -exec sh -c 'tex3ds -f rgba $0 -o ${0%.png}.t3x && rm $0' {} \;
    find ./build/game -type f -name "*.ttf" -exec sh -c 'mkbcfnt $0 -o ${0%.ttf}.bcfnt && rm $0' {} \;
```

8. 完成后就可以创建元数据文件了。
> [!NOTE]
> 引用 `icon.png` 时务必使用原始的 `Balatro3DS` 文件夹，因为 `build/game` 下的那个可能已在上一步被转换成 `.t3x` 文件。

```sh 
    smdhtool --create "Balatro" "Balatro" "Gazpacho, rosematcha" ./Balatro3DS/resources/textures/1x/icon.png ./build/metadata.smdh

```

9. 现在可以构建基础的 `.3dsx` 文件了。（这一步会用到之前那个 romfs 文件夹。）
> [!NOTE]
> 这个文件只是个存根（stub）。如果你现在就拿它到 3DS 上运行，只会得到一个错误。
>
> 记得把命令中的 `xxxxxxx` 替换成你机器上那个文件夹的实际名称。

> [!WARNING]
> 务必使用 `Nintendo.3DS-[xxxxxxx]` 文件夹中的 `lovepotion.elf` 文件，而**不是** `lovepotion.3dsx`。
```sh 
    3dsxtool Nintendo.3DS-[xxxxxxx]/lovepotion.elf ./build/base.3dsx --smdh=./build/metadata.smdh --romfs=./lovepotion/platform/ctr/romfs
```

10. 接着进入 `game` 目录，用 `zip` 打包游戏。

```sh
    cd ./build/game
    zip -r ../balatro.love .
```

11. 最后把存根与游戏内容融合，生成编译好的 `3dsx` 文件。

```sh
    cd ..
    cat base.3dsx balatro.love > Balatro3ds.3dsx

```

把这个文件复制到 SD 卡根目录的 `3ds` 文件夹，再从 Homebrew Launcher 启动即可。
