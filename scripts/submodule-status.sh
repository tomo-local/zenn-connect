#!/bin/bash
# 各 submodule の現在のコミットとブランチを確認する
git submodule status
echo ""
git submodule foreach 'echo "$name: $(git log -1 --oneline)"'
