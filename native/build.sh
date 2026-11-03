#!/usr/bin/env bash
# Builds OpenSSL (libcrypto) + libssh2 as static xcframeworks for iOS device, iOS Simulator
# and macOS (macOS slice lets `swift test` exercise LassoSSH without a simulator).
# Output: native/out/{COpenSSL,CLibSSH2}.xcframework  (gitignored, never committed).
# Approach adapted from Heeler's build-native.sh (Apache-2.0) — see NOTICE.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/Sources.lock"
IOS_MIN=18.0; MAC_MIN=15.0; JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OUT="$HERE/../Packages/LassoSSH/Artifacts"; WORK="$HERE/build"
for c in curl shasum tar perl make cmake xcodebuild xcrun; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done
rm -rf "$WORK"; mkdir -p "$WORK/dl"

fetch() { # name url sha
  local f="$WORK/dl/$1.tar.gz"
  curl -fsSL --proto '=https' --retry 3 "$2" -o "$f"
  local got; got=$(shasum -a 256 "$f" | awk '{print $1}')
  [ "$got" = "$3" ] || { echo "❌ $1 hash mismatch: $got"; exit 1; }
  tar -xzf "$f" -C "$WORK"
}
fetch openssl "$OPENSSL_URL" "$OPENSSL_SHA256"
fetch libssh2 "$LIBSSH2_URL" "$LIBSSH2_SHA256"
[ "${1:-}" = "--verify-only" ] && { echo "✅ sources verified"; exit 0; }
OSSL_SRC="$WORK/openssl-$OPENSSL_VERSION"; SSH2_SRC="$WORK/libssh2-$LIBSSH2_VERSION"

openssl() { # slice configure-target minflag minver
  local b="$WORK/ossl-$1" p="$WORK/ossl-$1-prefix"; mkdir -p "$b" "$p/lib"
  ( cd "$b" && env -u CFLAGS -u LDFLAGS perl "$OSSL_SRC/Configure" "$2" \
      no-shared no-tests no-apps no-docs no-module no-legacy no-dso no-engine no-deprecated \
      no-dsa no-rc2 no-rc4 no-des no-cast no-bf no-idea no-seed no-camellia no-aria \
      no-sm2 no-sm3 no-sm4 no-whirlpool no-rmd160 --prefix="$p" --libdir=lib "$3=$4" >/dev/null \
    && make -s -j"$JOBS" build_generated libcrypto.a >/dev/null )
  mkdir -p "$p/include/openssl"
  cp -R "$OSSL_SRC/include/openssl/." "$b/include/openssl/." "$p/include/openssl/"
  find "$p/include/openssl" -name '*.in' -delete
  cp "$b/libcrypto.a" "$p/lib/"
}
libssh2() { # slice sdk minver
  local b="$WORK/ssh2-$1" p="$WORK/ssh2-$1-prefix" o="$WORK/ossl-$1-prefix"
  env -u CFLAGS -u LDFLAGS cmake -S "$SSH2_SRC" -B "$b" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$2" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$3" \
    -DCMAKE_INSTALL_PREFIX="$p" -DCMAKE_C_FLAGS=-DLIBSSH2_NO_AES_CBC \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENSSL_ROOT_DIR="$o" -DOPENSSL_INCLUDE_DIR="$o/include" -DOPENSSL_CRYPTO_LIBRARY="$o/lib/libcrypto.a" >/dev/null
  cmake --build "$b" --parallel "$JOBS" >/dev/null && cmake --install "$b" >/dev/null
}
framework() { # name lib headersdir slice
  local f="$WORK/fw-$4/$1.framework"; mkdir -p "$f/Headers" "$f/Modules"
  cp "$2" "$f/$1"; cp -R "$3/." "$f/Headers/"
  cp "$HERE/support/$1.h" "$f/Headers/"; cp "$HERE/support/$1.modulemap" "$f/Modules/module.modulemap"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $1" -c "Add :CFBundleIdentifier string dev.lasso.$1" \
    -c "Add :CFBundlePackageType string FMWK" -c "Add :CFBundleVersion string 1" "$f/Info.plist" >/dev/null
}

for s in ios:ios64-xcrun:-mios-version-min:$IOS_MIN:iphoneos \
         sim:iossimulator-arm64-xcrun:-mios-simulator-version-min:$IOS_MIN:iphonesimulator \
         mac:darwin64-arm64:-mmacosx-version-min:$MAC_MIN:macosx; do
  IFS=: read -r slice tgt flag ver sdk <<<"$s"
  echo "🔨 $slice"
  openssl "$slice" "$tgt" "$flag" "$ver"
  libssh2 "$slice" "$sdk" "$ver"
  mkdir -p "$WORK/h-ossl-$slice" && cp -R "$WORK/ossl-$slice-prefix/include/openssl" "$WORK/h-ossl-$slice/"
  framework COpenSSL "$WORK/ossl-$slice-prefix/lib/libcrypto.a" "$WORK/h-ossl-$slice" "$slice"
  framework CLibSSH2 "$WORK/ssh2-$slice-prefix/lib/libssh2.a" "$WORK/ssh2-$slice-prefix/include" "$slice"
done

rm -rf "$OUT"; mkdir -p "$OUT/Notices"
for n in COpenSSL CLibSSH2; do
  xcodebuild -create-xcframework -framework "$WORK/fw-ios/$n.framework" -framework "$WORK/fw-sim/$n.framework" \
    -framework "$WORK/fw-mac/$n.framework" -output "$OUT/$n.xcframework" >/dev/null
done
cp "$SSH2_SRC/COPYING" "$OUT/Notices/libssh2-BSD-3-Clause.txt"
cp "$OSSL_SRC/LICENSE.txt" "$OUT/Notices/OpenSSL-Apache-2.0.txt"
{ echo "openssl $OPENSSL_VERSION $OPENSSL_SHA256"; echo "libssh2 $LIBSSH2_VERSION $LIBSSH2_SHA256"
  xcodebuild -version | paste -sd ' ' -; } > "$OUT/PROVENANCE.txt"
rm -rf "$WORK"
echo "✅ native/out ready"
