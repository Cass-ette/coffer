#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
app_bundle="${1:-.build/macos12-universal/Build/Products/Release/Coffer.app}"
output_dmg="${2:-.build/distribution/Coffer-macOS12-universal.dmg}"

if [[ ! -d "$app_bundle" ]]; then
    printf 'Missing app bundle: %s\n' "$app_bundle" >&2
    exit 1
fi
codesign --verify --deep --strict "$app_bundle"
for architecture in arm64 x86_64; do
    lipo "$app_bundle/Contents/MacOS/Coffer" -verify_arch "$architecture"
done

mkdir -p "$(dirname "$output_dmg")"
dmg_source_dir=$(mktemp -d "$PWD/.build/distribution/dmg-source.XXXXXX")
dmg_mount_dir=""
dmg_is_mounted=0
cleanup() {
    if [[ "$dmg_is_mounted" == 1 ]]; then
        hdiutil detach -quiet "$dmg_mount_dir" || true
    fi
    rm -rf "$dmg_source_dir"
    if [[ -n "$dmg_mount_dir" ]]; then
        rmdir "$dmg_mount_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT
ditto "$app_bundle" "$dmg_source_dir/Coffer.app"
ln -s /Applications "$dmg_source_dir/Applications"
cp docs/install-macos.md "$dmg_source_dir/INSTALL.md"
cat > "$dmg_source_dir/安装与升级.txt" <<'INSTRUCTIONS'
安装或升级 Coffer

1. 先完全退出正在运行的 Coffer。
2. 把 Coffer.app 拖到旁边的 Applications（应用程序）文件夹。
3. 已安装的用户选择“替换”，然后从“应用程序”打开 Coffer。
4. 升级后使用原来的主密码解锁。若 Touch ID 暂时不可用，先用主密码。

已有用户升级前，建议备份加密数据目录：
~/Library/Application Support/cc.cassette.coffer/
可在 Finder 按 Command + Shift + G，输入以上路径，复制整个文件夹作为备份。

替换 Coffer.app 不会删除这个数据目录，也不需要重新创建保险库。
如果升级后意外出现“创建保险库”页面，先退出应用并核对安装位置和原数据目录。

首次打开若提示无法验证开发者，在 Finder 中按住 Control 点按 Coffer，选择“打开”。
当前安装包使用本地签名，尚未经过 Apple 公证。

支持 macOS 12 或更新版本，同时包含 Intel 和 Apple 芯片版本。
INSTRUCTIONS

hdiutil create -ov -volname Coffer -fs HFS+ -format UDZO \
    -srcfolder "$dmg_source_dir" "$output_dmg"
hdiutil verify "$output_dmg"
dmg_mount_dir=$(mktemp -d "$PWD/.build/distribution/dmg-mount.XXXXXX")
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$dmg_mount_dir" "$output_dmg"
dmg_is_mounted=1
codesign --verify --deep --strict "$dmg_mount_dir/Coffer.app"
cmp "$app_bundle/Contents/MacOS/Coffer" "$dmg_mount_dir/Coffer.app/Contents/MacOS/Coffer"
[[ -L "$dmg_mount_dir/Applications" && "$(readlink "$dmg_mount_dir/Applications")" == /Applications ]]
[[ -f "$dmg_mount_dir/安装与升级.txt" ]]
hdiutil detach -quiet "$dmg_mount_dir"
dmg_is_mounted=0
shasum -a 256 "$output_dmg" > "$output_dmg.sha256"
printf 'DMG: %s\n' "$output_dmg"
