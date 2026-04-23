#!/bin/bash
# すべての submodule を最新コミットに更新する
set -e

if [ -n "$1" ]; then
  echo "Updating submodule: $1"
  git submodule update --remote --merge "repos/$1"
else
  echo "Updating all submodules..."
  git submodule update --remote --merge
fi

echo "Done."
