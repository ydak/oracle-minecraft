# oracle-minecraft

Oracle Cloud の Always Free 枠で、統合版 (Bedrock) の Minecraft サーバーを立てるスクリプトです。

[Oracle Cloud Shell](https://cloud.oracle.com/?bdcstate=maximized&cloudshell=true) を開いて、下記を貼り付けます。

```bash
curl -fsSL https://raw.githubusercontent.com/ydak/oracle-minecraft/main/mc.sh | bash
```

あとはメニューから選ぶだけです。

```
[1] create  (マインクラフトサーバーを作成)
[2] delete  (マインクラフトサーバーを削除)
```

## 無料枠について

| | Oracle Always Free |
| --- | --- |
| CPU / メモリ | Ampere A1 2 OCPU / 12GB |
| 下り通信 | 10TB/月 |
| ブロックボリューム | 200GB |

[GCP 版](https://github.com/ydak/gcp-minecraft) は e2-micro (共有コア / 1GB) と下り 1GB/月 のため、描画距離などを切り詰める必要がありました。こちらはその制約がほぼありません。

2026 年 6 月 15 日に Ampere A1 の枠が 4 OCPU / 24GB から半減しています。今後も変わる可能性があるため、[Always Free の一覧](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)で最新の条件を確認してください。

## ARM について

統合版のサーバーには公式の ARM ビルドがありません。Mojang が配布しているのは x86-64 バイナリだけです。

利用している [itzg/minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server) が box64 によるエミュレーションに対応しているため、Ampere A1 でもそのまま動きます。スクリプト側で意識する必要はありません。

## 実装状況

| 操作 | 状態 |
| --- | --- |
| `create` | 実装済み (A1 / E2 とも実機で確認) |
| `delete` | 実装済み (実機で確認) |
| `update` | 実装済み (未検証) |
| `config` | 実装済み (未検証) |
| `backup` / `restore` | 未着手 |
