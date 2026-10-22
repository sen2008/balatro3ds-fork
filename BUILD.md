# Build Instructions

**English** | [简体中文](BUILD.zh-CN.md)

These instructions are provided for users to create and package a Balatro3DS.3dsx file manually on their own machine. Alternative building methods can be found on the [Lovebrew wiki](https://lovebrew.org). You will need to have devkitPro and their `3ds-dev` package installed for this process. You can find the instructions for that on the [devkitPro wiki](https://devkitpro.org/wiki/Getting_Started).

Shoutout to @natesquared in the lovebrew discord, these steps are based on a similar set of instructions they gave to a different user.

> [!IMPORTANT]
> This recipe fuses the game onto a stock LövePotion release, which is missing five fixes this port depends on. A build made this way boots and plays, but sound effects lose their pitch bend, music crossfades seek to the wrong place, overlapping sounds can hard-crash the console, and the menu shows the older prebaked animation instead of the generated backdrop.
>
> If you just want to play, take a build from the [releases page](https://github.com/idkhan/Balatro3DS/releases). If you're working on the port, use `./dev/setup.sh` and `./dev/build.sh` instead — they build a patched runtime and handle asset conversion, music downsampling and CIA packaging for you.

## Windows
Unlike the Linux and macOS recipe below, this builds the patched runtime with `./dev/setup.sh` and `./dev/build.sh`, so you get the full-featured `.3dsx` and a `.cia`. The scripts are written for macOS and Linux, so a few tools need to be swapped in first.

> [!IMPORTANT]
> Run every command in this section from **devkitPro's MSYS2 shell**, not Git Bash, PowerShell or cmd. Open it with `C:\devkitPro\msys2\usr\bin\bash.exe -l` (or the "MSYS2" shortcut devkitPro adds to the Start menu). Git Bash can't see the devkitPro tools.

1. Install devkitPro with the [Windows installer](https://github.com/devkitPro/installer/releases) and tick **3DS Development** when it asks. Then install LövePotion's libraries along with `rsync` and `patch`. Without `patch`, LövePotion silently skips its 3DS luasocket fix and the runtime fails to compile on `net/if.h`.

Do a full update first. Mixing old and new MSYS2 packages can break tools: a `curl` newer than its `libcurl` won't even start.

```sh
    pacman -Syu
    pacman -S --needed 3ds-dev 3ds-cmake 3ds-box2d 3ds-curl 3ds-flac 3ds-libconfig \
        3ds-libjpeg-turbo 3ds-libmodplug 3ds-libogg 3ds-libpng 3ds-libtheora \
        3ds-libvorbisidec 3ds-liblua51 3ds-lz4 3ds-mbedtls 3ds-physfs 3ds-tinyxml2 \
        3ds-zlib rsync patch
```

2. Install ffmpeg and Python 3.13 or newer on Windows. `patch_lovepotion.py` needs 3.13, and devkitPro's MSYS2 only ships 3.12. From PowerShell:

```powershell
    winget install Gyan.FFmpeg.Essentials
    winget install Python.Python.3.14
```

Then note where each one landed. You'll need both paths in step 4.

```powershell
    (Get-Command ffmpeg).Source
    py -3.14 -c "import sys; print(sys.executable)"
```

3. Clone the repository. All remaining commands run from its root.

```sh
    git clone https://github.com/idkhan/Balatro3DS.git
    cd Balatro3DS
```

4. Set up the Windows tools in `dev/.tools` (gitignored). `setup.sh` only knows how to download the macOS and Linux builds of makerom and bannertool, so download the Windows builds yourself:

```sh
    mkdir -p dev/.tools/bin
    curl -fL https://github.com/3DSGuy/Project_CTR/releases/download/makerom-v0.19.0/makerom-v0.19.0-win_x86_64.zip -o dev/.tools/makerom.zip
    curl -fL https://github.com/Epicpkmn11/bannertool/releases/download/v1.2.2/bannertool.zip -o dev/.tools/bannertool.zip
    unzip -jo dev/.tools/makerom.zip makerom.exe -d dev/.tools
    unzip -jo dev/.tools/bannertool.zip windows-x86_64/bannertool.exe -d dev/.tools
    rm dev/.tools/*.zip
```

Next, create small wrapper scripts that stand in for `dkp-pacman`, `ffmpeg`, `python3` and `oggenc`. Replace the two paths with the ones from step 2. Keep the quotes, and change `C:\` to `/c/` with forward slashes.

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

5. Build the patched LövePotion runtime. This clones LövePotion, applies the port's fixes and compiles it, which takes a few minutes. You only need to do it once, and again whenever `dev/patch_lovepotion.py` changes.

```sh
    source dev/.tools/env-windows.sh
    ./dev/setup.sh
```

> [!NOTE]
> If the compile reaches `[252/252]` and then exits with an error right after `Translating .../compile_commands.json`, the runtime still built fine. That error comes from the build-type report at the end of the script. Check that `dev/.cache/lovepotion/build/main.release/lovepotion.elf` exists, then carry on.

6. Build the game. `all` produces both formats, and `3dsx` or `cia` builds just one. Run `source dev/.tools/env-windows.sh` first in any new shell.

```sh
    ./dev/build.sh all
```

The output goes to `dev/dist/`:

- `Balatro3DS.3dsx`: copy it into the `3ds` folder at the root of your SD card and launch it from the Homebrew Launcher.
- `Balatro.cia`: install it with FBI (or another CIA installer). It then shows up on the Home Menu.

## Linux and macOS
1. We will start off by making a folder to contain all our files.

```sh
    mkdir build_dir
    cd build_dir
```

2. Navigate to the latest release on the [lovepotion github](https://github.com/lovebrew/lovepotion/releases) and download the file labeled `Nintendo.3DS-[xxxxxxx].zip`. Extract this folder into the directory we just made in the previous step. Your file structure should look like this:

```
    build_dir/
    └── Nintendo.3DS-[xxxxxxx]/ <- the `xxxxxxx` is just a random set 
        ├── lovepotion.3dsx        of 7 characters based on whatever 
        └── lovepotion.elf         was on the releases page.
```

3. Clone the lovebrew repository. (We need the romfs folder for later.)

```sh
    git clone https://github.com/lovebrew/lovepotion.git lovepotion && rm -rf lovepotion/.git
```

4. Clone the Balatro3DS repository.

```sh
    git clone https://github.com/idkhan/Balatro3DS.git Balatro3DS && rm -rf Balatro3DS/.git

```
5. Make a folder titled 'build'. Copy the Balatro3DS folder into it and name the folder 'game'. We will put all the files we generate in this folder.

```sh
    mkdir build
    cp -r Balatro3DS build/game
```
At this point your folder structure should look like this.
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

6. Delete the files the game doesn't load. This isn't housekeeping — `mkbcfnt` rasterizes every glyph in a face, and the seven CJK and Noto fonts sitting in the repository expand to roughly 599 MB of `.bcfnt` between them. Only `m6x11plus` is ever loaded, and its `.bcfnt` is already checked in. Keep `menu.png`: a stock runtime can't generate the menu backdrop, so the menu plays this prebaked animation instead.

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

7. Now we will convert the remaining images and fonts into `.t3x` and `.bcfnt` files. The `&& rm $0` sections are optional, this just deletes the original files to save space. 
> [!NOTE]
> This step takes a while, just be patient.
```sh
    find ./build/game -type f -name "*.png" -exec sh -c 'tex3ds -f rgba $0 -o ${0%.png}.t3x && rm $0' {} \;
    find ./build/game -type f -name "*.ttf" -exec sh -c 'mkbcfnt $0 -o ${0%.ttf}.bcfnt && rm $0' {} \;
```

8. Once that finishes we can create the metadata file.
> [!NOTE]
> Make sure to use the original `Balatro3DS` folder when referencing the `icon.png` file as the one under `build/game` could have been converted into a `.t3x` file in the previous step.

```sh 
    smdhtool --create "Balatro" "Balatro" "Gazpacho, rosematcha" ./Balatro3DS/resources/textures/1x/icon.png ./build/metadata.smdh

```

9. Now we can build the base `.3dsx` file. (This is where we use that romfs folder from earlier.)
> [!NOTE]
> This file is a stub, if you try to execute it on your 3ds as it is now you will just get an error.
>
> Make sure to replace the `xxxxxxx` in this command with the actual name of the folder on your machine.

> [!WARNING]
> Make sure to use the `lovepotion.elf` file and NOT the `lovepotion.3dsx` in the `Nintendo.3DS-[xxxxxxx]` folder.
```sh 
    3dsxtool Nintendo.3DS-[xxxxxxx]/lovepotion.elf ./build/base.3dsx --smdh=./build/metadata.smdh --romfs=./lovepotion/platform/ctr/romfs
```

10. Next, enter the `game` directory and package the game using `zip`.

```sh
    cd ./build/game
    zip -r ../balatro.love .
```

11. Finally you can fuse the stub with the game contents to create the compiled `3dsx` file.

```sh
    cd ..
    cat base.3dsx balatro.love > Balatro3ds.3dsx

```

Copy that file into the `3ds` folder at the root of your SD card and launch it from the Homebrew Launcher.
