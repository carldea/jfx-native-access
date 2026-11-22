#!/bin/sh
# Builds librenderer.dylib from Renderer.swift (C ABI exported with @c, loaded by Java via FFM).
set -e
cd "$(dirname "$0")"

# Original Objective-C build (renderer.m kept for comparison):
 clang -shared -o librendererOC.dylib renderer.m \
   -framework Cocoa \
   -framework Metal \
   -framework QuartzCore \
   -arch arm64

swiftc -emit-library -O \
  -module-name Renderer \
  -swift-version 6 \
  -target arm64-apple-macos14.0 \
  -Xlinker -install_name -Xlinker @rpath/librenderer.dylib \
  -o librenderer.dylib Renderer.swift
