#!/bin/bash
# Downloads the prebuilt llama.cpp xcframework (official release) into Vendor/.
set -e
cd "$(dirname "$0")/.."
TAG="${1:-b11254}"
mkdir -p Vendor && cd Vendor
curl -L -o llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
unzip -q -o llama.zip && rm llama.zip
echo "Fetched llama.cpp $TAG into Vendor/build-apple/llama.xcframework"
