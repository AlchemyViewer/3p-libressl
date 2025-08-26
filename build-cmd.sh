#!/usr/bin/env bash

set -eux

pushd "$(dirname "$0")"

top="$(pwd)"
stage="$top"/stage

popd

SSL_SOURCE_DIR="$top/libressl"

# load autobuild provided shell functions and variables
case "$AUTOBUILD_PLATFORM" in
    windows*)
        autobuild="$(cygpath -u "$AUTOBUILD")"
    ;;
    *)
        autobuild="$AUTOBUILD"
    ;;
esac

source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd apply_patch
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

pushd "$SSL_SOURCE_DIR"
    ./update.sh
popd

case "$AUTOBUILD_PLATFORM" in
    # ------------------------ windows, windows64 ------------------------
    windows*)
        for arch in sse avx2 arm64 ; do
            platform_target="x64"
            if [[ "$arch" == "arm64" ]]; then
                platform_target="ARM64"
            fi

            mkdir -p "build_debug_$arch"
            pushd "build_debug_$arch"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_DEBUG)"
                if [[ "$arch" == "avx2" ]]; then
                    opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                elif [[ "$arch" == "arm64" ]]; then
                    opts="$(remove_switch /arch:SSE4.2 $opts)"
                fi
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$platform_target" $(cygpath -m $SSL_SOURCE_DIR) -DBUILD_SHARED_LIBS=OFF \
                        -DCMAKE_CONFIGURATION_TYPES="Debug" \
                        -DCMAKE_C_FLAGS_DEBUG="$plainopts" \
                        -DCMAKE_CXX_FLAGS_DEBUG="$opts /EHsc" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/debug")" \
                        -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include")"

                cmake --build . --config Debug --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Debug

                # conditionally run unit tests
                if [[ "${DISABLE_UNIT_TESTS:-0}" == "0" && "$arch" != "arm64" ]]; then
                    ctest -C Debug --parallel $AUTOBUILD_CPU_COUNT
                fi
            popd

            mkdir -p "build_release_$arch"
            pushd "build_release_$arch"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
                if [[ "$arch" == "avx2" ]]; then
                    opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                elif [[ "$arch" == "arm64" ]]; then
                    opts="$(remove_switch /arch:SSE4.2 $opts)"
                fi
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$platform_target" $(cygpath -m $SSL_SOURCE_DIR) -DBUILD_SHARED_LIBS=OFF \
                        -DCMAKE_CONFIGURATION_TYPES="Release" \
                        -DCMAKE_C_FLAGS="$plainopts" \
                        -DCMAKE_CXX_FLAGS="$opts /EHsc" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/release")" \
                        -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include")"

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                if [[ "${DISABLE_UNIT_TESTS:-0}" == "0" && "$arch" != "arm64" ]]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi
            popd
        done
    ;;

    # ------------------------- darwin, darwin64 -------------------------
    darwin*)
        export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

        for arch in x86_64 arm64 ; do
            ARCH_ARGS="-arch $arch"
            cc_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
            cc_opts="$(remove_cxxstd $cc_opts)"
            ld_opts="$ARCH_ARGS"

            mkdir -p "build_$arch"
            pushd "build_$arch"
                CFLAGS="$cc_opts" \
                LDFLAGS="$ld_opts" \
                cmake $SSL_SOURCE_DIR -G "Ninja" -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$cc_opts" \
                    -DCMAKE_CXX_FLAGS="$cc_opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$stage/include" \
                    -DCMAKE_OSX_ARCHITECTURES="$arch" \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi
            popd
        done

        lipo -create -output "$stage/lib/release/libcrypto.a" "$stage/lib/release/x86_64/libcrypto.a" "$stage/lib/release/arm64/libcrypto.a"
        lipo -create -output "$stage/lib/release/libssl.a" "$stage/lib/release/x86_64/libssl.a" "$stage/lib/release/arm64/libssl.a"
        lipo -create -output "$stage/lib/release/libtls.a" "$stage/lib/release/x86_64/libtls.a" "$stage/lib/release/arm64/libtls.a"
    ;;

    # -------------------------- linux, linux64 --------------------------
    linux*)
        for arch in sse avx2 ; do
            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            if [[ "$arch" == "avx2" ]]; then
                opts="$(replace_switch -march=x86-64-v2 -march=x86-64-v3 $opts)"
            fi

            # Release
            mkdir -p "build_$arch"
            pushd "build_$arch"
                cmake $SSL_SOURCE_DIR -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$(remove_cxxstd $opts)" \
                    -DCMAKE_CXX_FLAGS="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/$arch/release" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$stage/include"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi
            popd
        done
    ;;
esac

mkdir -p "$stage/LICENSES"
cp "$SSL_SOURCE_DIR/COPYING" "$stage/LICENSES/libressl.txt"