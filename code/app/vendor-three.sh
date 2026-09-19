#!/bin/bash
# 把 Three.js + 加载器打成一个 IIFE 单文件（Resources/web/three.bundle.js，全局 LD_THREE），并复制 Draco 解码器。
# 为什么打包而不用 ES module：皮肤是 file:// 页面，WebKit 对 file:// 的 module import 有 CORS 限制；
# 单文件 <script src> 没有这个问题，也不用改皮肤加载路径。产物随仓库提交（vendored），重新生成才需要网络。
set -euo pipefail
THREE_VERSION="${THREE_VERSION:-0.170.0}"
ESBUILD_VERSION="${ESBUILD_VERSION:-0.24.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/Resources/web"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
npm init -y >/dev/null
npm i --silent "three@$THREE_VERSION" "esbuild@$ESBUILD_VERSION"
cat > entry.js <<'JS'
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/examples/jsm/loaders/DRACOLoader.js';
import { FBXLoader } from 'three/examples/jsm/loaders/FBXLoader.js';
import * as SkeletonUtils from 'three/examples/jsm/utils/SkeletonUtils.js';
export { THREE, GLTFLoader, DRACOLoader, FBXLoader, SkeletonUtils };
JS
npx esbuild entry.js --bundle --minify --format=iife --global-name=LD_THREE --legal-comments=none --outfile="$OUT/three.bundle.js"
mkdir -p "$OUT/draco"
cp node_modules/three/examples/jsm/libs/draco/draco_wasm_wrapper.js node_modules/three/examples/jsm/libs/draco/draco_decoder.wasm node_modules/three/examples/jsm/libs/draco/draco_decoder.js "$OUT/draco/"
# 版本记录（纯 ASCII：macOS 自带 bash 3.2 在 set -u 下会被同一行里的多字节字符带偏，把变量名解析错）
echo "three ${THREE_VERSION} / esbuild ${ESBUILD_VERSION} / $(date '+%Y-%m-%d')" > "${OUT}/three.bundle.version"
echo "OK $(du -h "${OUT}/three.bundle.js" | cut -f1) three.bundle.js (three ${THREE_VERSION}) + draco/"
