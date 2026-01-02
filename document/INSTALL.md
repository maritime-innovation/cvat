## Installation

0) CVATを設定するPCをTailscaleに登録してIPアドレスを取得する。

1) 環境設定ファイルのサンプルを本番用にコピーする。
```bash
cp env.example .env
```

2) .envの内容を編集。特にCVAT_DIR、DEPLOY_SAM_GPU、CVAT_TAILSCALE_IPには注意。
```bash
# CVAT install location (optional)
CVAT_DIR=/home/hoge/cvat
CVAT_VERSION_TAG=v2.54.0
CVAT_HOST=localhost

# Django superuser (required for non-interactive createsuperuser)
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_EMAIL=admin@example.com
DJANGO_SUPERUSER_PASSWORD=hogehoge

# Optional: deploy GPU version of SAM function (0/1)
DEPLOY_SAM_GPU=1

# Nuclio CLI version (optional)
NUCTL_VERSION=1.13.0

# --- CVAT access / routing ---
# If 1, add a Traefik override router that allows access via IP (e.g., Tailscale IP) without Host match.
CVAT_ALLOW_IP_ACCESS=1
# Optional: if empty, script auto-detects tailscale ip -4; else use this value
CVAT_TAILSCALE_IP=
```

3) セットアップスクリプトを実行。
```bash
./setup_cvat_with_sam.sh
```

4) Tailscale下にある別のPCからアクセス確認。HTTP/1.1 200 OKが出ることを確認する。
```bash
curl -I http://xxx.xxx.xxx.xxx:8080/api/server/about | head -n 10
```

5) サイトにアクセス（http://xxx.xxx.xxx.xxx:8080）

6) もし全ての設定を消してまっさらな状態に戻したいときは掃除用スクリプトを実行する。
```bash
./cleanup_cvat_docker_interactive.sh
```


