---

### 2. `build_ue5.sh` (コア・スクリプト)

```bash
#!/bin/bash
# ==============================================================================
# UE5-Survival-Kit: 限界環境用ハックプロトタイプ (PoC)
# ==============================================================================

# --- [ユーザー指定変数] 自分の環境に合わせて書き換えろ ---
GITHUB_URL="https://github.com/EpicGames/UnrealEngine.git"
UE_VERSION="5.7.4"
NAS_PATH="/mnt/nas/ue5_workspace"     # 広大なNASのパスを指定
TARGET_HOME_DIR="/home/ue5_user"      # コンテナ内でホームに見せかけるパス
PROJECT_FILE="$NAS_PATH/YourProject/YourProject.uproject" # 起動するプロジェクト

# --- エラーハンドリング・ログ機構 ---
set -o pipefail

log() {
    echo -e "\n\033[1;34m[INFO]\033[0m $1"
}

fail() {
    echo -e "\n\033[1;31m[CRITICAL ERROR]\033[0m Step [$1] で処理が停止しました。"
    echo "原因: 直前のコマンドが異常終了しました。環境依存のエラーである可能性が高いです。"
    echo "対策: 上記のログを確認し、ご自身の環境（権限・パス・ネットワーク等）に合わせてスクリプトを調整してください。"
    exit 1
}

# --- 1. 空き領域・環境をsearch ---
STEP="1.環境探索"
log "$STEP を開始します..."
# 権限があり、ディレクトリが存在し、かつ空き容量が最大の領域を探す
TARGET_DIR=$(df -Pk | grep '^/' | awk '{print $6}' | while read -r dir; do
    if [ -w "$dir" ] && [ -d "$dir" ]; then
        echo "$dir $(df -Pk "$dir" | tail -1 | awk '{print $4}')"
    fi
done | sort -k2 -nr | head -1 | awk '{print $1}')

if [ -z "$TARGET_DIR" ]; then
    echo "書き込み可能な領域が見つかりません。" && fail "$STEP"
fi
log "探索完了。最も空き容量が多い領域を採用: $TARGET_DIR"


# --- 2. クローン実行 ---
STEP="2.GitHubからClone"
log "$STEP を開始します..."
cd "$TARGET_DIR" || fail "$STEP"
if [ ! -d "UnrealEngine_$UE_VERSION" ]; then
    git clone "$GITHUB_URL" UnrealEngine_"$UE_VERSION" || fail "$STEP"
else
    log "ディレクトリが既に存在するため、クローンをスキップします。"
fi


# --- 3. ディレクトリ移動 ---
STEP="3.ディレクトリ移動"
log "$STEP を開始します..."
cd UnrealEngine_"$UE_VERSION" || fail "$STEP"


# --- 4. & 5. Versioning ---
STEP="4-5.git checkout (${UE_VERSION})"
log "$STEP を開始します..."
git fetch --tags || fail "$STEP"
git checkout tags/"$UE_VERSION" || fail "$STEP"


# --- 6. Setup.sh実行 ---
STEP="6.Setup.shの実行"
log "$STEP を開始します... (依存関係のダウンロード)"
./Setup.sh || fail "$STEP"


# --- 7. Docker Build ---
STEP="7.Dockerfileによるコンテナbuild"
log "$STEP を開始します..."
DOCKER_DIR="Engine/Extras/Containers/Dockerfile/linux/dev"
if [ ! -d "$DOCKER_DIR" ]; then
    echo "指定のDockerfileディレクトリが存在しません: $DOCKER_DIR" && fail "$STEP"
fi

cd "$DOCKER_DIR" || fail "$STEP"
docker build -t ue5-dev-env . || fail "$STEP"


# --- 8. & 9. & 10. & 11. Docker Run & Build & Exit ---
STEP="8-11.コンテナ内ビルド処理 (NASのマウント)"
log "$STEP を開始します... (NASをホーム領域と誤認させます)"

# 元のUE5ルートディレクトリへ戻る
cd ../../../../../ || fail "$STEP"

# NAS領域が存在しない場合は作成
mkdir -p "$NAS_PATH" || fail "$STEP"

# コンテナを起動し、内部でGenerateとmakeを実行して自動 exit する
docker run --rm \
    -v "$NAS_PATH":"$TARGET_HOME_DIR" \
    -v "$PWD":"/unreal" \
    ue5-dev-env /bin/bash -c "
        cd /unreal || exit 1
        echo '--- 9. GenerateProjectFiles.sh 実行 ---'
        ./GenerateProjectFiles.sh || exit 1
        echo '--- 10. make 実行 (軽量ビルドターゲット) ---'
        make ShaderCompileWorker UnrealEditor UnrealInsights || exit 1
        echo '--- 11. コンテナを exit します ---'
    " || fail "$STEP"


# --- 12. 軽量設定でEditor起動 ---
STEP="12.Editor起動"
log "$STEP を開始します..."

UE_EDITOR_PATH="$PWD/Engine/Binaries/Linux/UnrealEditor"
CACHE_DIR="$NAS_PATH/ue_cache" # 24GBを回避し、キャッシュもNASへ流し込む

mkdir -p "$CACHE_DIR"

log "起動コマンドを実行します（音無し・軽量設定）..."
"$UE_EDITOR_PATH" \
    -project="$PROJECT_FILE" \
    -deriveddatacache="$CACHE_DIR" \
    -nosound \
    -nullrhi \
    -novsync

log "全工程が正常に終了しました。環境のハックに成功しました。"
exit 0
