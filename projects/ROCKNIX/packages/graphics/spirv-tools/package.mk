# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2021-present Frank Hartung (supervisedthinking (@) gmail.com)
# Copyright (C) 2021-present Team LibreELEC (https://libreelec.tv)

. ${ROOT}/packages/graphics/spirv-tools/package.mk

# core builds the target side static with the tools, we want only the shared library
# GCC 16 reports speculative timer devirtualization as an array-bounds warning.
PKG_CMAKE_OPTS_TARGET="-DSPIRV_SKIP_TESTS=ON \
                       -DSPIRV_SKIP_EXECUTABLES=ON \
                       -DSPIRV_WERROR=OFF \
                       -DBUILD_SHARED_LIBS=ON"
