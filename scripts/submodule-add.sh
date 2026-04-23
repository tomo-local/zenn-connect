#!/bin/bash
# 新しい GitHub リポジトリを作成して submodule として追加する
#
# 使い方:
#   ./scripts/submodule-add.sh <repo-name> [description]
#
# 例:
#   ./scripts/submodule-add.sh react-mini-redux "Zenn記事: Reduxを自作"

set -e

REPO_NAME="$1"
DESCRIPTION="${2:-}"
GITHUB_USER="tomo-local"

if [ -z "$REPO_NAME" ]; then
  echo "Usage: $0 <repo-name> [description]"
  exit 1
fi

if [ -d "repos/$REPO_NAME" ]; then
  echo "Error: repos/$REPO_NAME already exists."
  exit 1
fi

echo "Creating GitHub repository: $GITHUB_USER/$REPO_NAME"
gh repo create "$GITHUB_USER/$REPO_NAME" \
  --public \
  --description "$DESCRIPTION" \
  --add-readme

echo "Adding as submodule..."
git submodule add "https://github.com/$GITHUB_USER/$REPO_NAME" "repos/$REPO_NAME"

# node_modules などが誤って commit されないよう .gitignore を追加
cat > "repos/$REPO_NAME/.gitignore" <<'EOF'
node_modules/
dist/
EOF
git -C "repos/$REPO_NAME" add .gitignore
git -C "repos/$REPO_NAME" commit -m "chore: add .gitignore"
git -C "repos/$REPO_NAME" push

git add .gitmodules "repos/$REPO_NAME"
git commit -m "feat: add submodule $REPO_NAME"

echo ""
echo "Done. repos/$REPO_NAME has been added."
echo "Repo: https://github.com/$GITHUB_USER/$REPO_NAME"
