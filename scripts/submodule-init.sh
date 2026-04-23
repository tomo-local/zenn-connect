#!/bin/bash
# clone 後に submodule を初期化・取得する
set -e
git submodule update --init --recursive
echo "All submodules initialized."
