# QSDK の netifd wireless driver

`examples/wireless/qcawificfg80211.sh` を `/lib/netifd/wireless/` に配置すると、既存の netifd が QSDK のラジオと VAP を管理します。netifd 本体のバイナリーは変更しません。

無線の起動と設定適用には、ROM にある純正 `/sbin/wifi` と `/lib/wifi/` の制御処理を使います。MLO を含む設定は全ラジオにまとめて適用し、同じ設定での複数回の setup をまとめます。停止操作では、他のラジオが共有する MLD を削除しないよう、純正のラジオ単位の停止処理を使います。古い netifd は共有ブリッジ接続も外すため、停止後に残りの有効なラジオを再起動して接続を復元します。全ラジオを停止する場合は再起動しません。

`contrib/qsdk/wifi` は既存の `/sbin/wifi` の入口を置き換えます。通常の操作を標準 `network.wireless` API に接続し、機種固有のコマンドは ROM の処理へ渡します。

次のコマンドで、ハードウェアを操作せずに再読み込み・停止・再起動の処理を確認できます。

```sh
python3 contrib/qsdk/selfcheck.py
```

WN-7T94XR v2.5.1 用の IPK と導入手順は [LuCI フォーク](https://github.com/onokatio/luci/tree/qsdk-wn7t94xr/contrib/wn7t94xr)で管理しています。純正の Qualcomm 制御スクリプトは含めていません。他の QSDK 機種や EasyMesh の再構成は未検証です。
