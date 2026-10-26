# QSDK の netifd wireless driver

`examples/wireless/qcawificfg80211.sh` を `/lib/netifd/wireless/` に配置すると、既存の netifd が QSDK のラジオと VAP を管理します。netifd 本体のバイナリーは変更しません。

無線の起動と設定適用には、ROM にある純正 `/sbin/wifi` と `/lib/wifi/` の制御処理を使います。MLO を含む設定は全ラジオにまとめて適用し、同じ設定での複数回の setup をまとめます。停止操作では、他のラジオが共有する MLD を削除しないよう、純正のラジオ単位の停止処理を使います。古い netifd は共有ブリッジ接続も外すため、停止後に残りの有効なラジオを再起動して接続を復元します。全ラジオを停止する場合は再起動しません。

`contrib/qsdk/wifi` は既存の `/sbin/wifi` の入口を置き換えます。通常の操作を標準 `network.wireless` API に接続し、機種固有のコマンドは ROM の処理へ渡します。

WN-7T94XRではラジオの `distance` を0〜21150mで指定できます。純正 `cfg80211tool wifiN acktimeout` で、設定前のACKタイムアウトに450mごとに3µsを加えます。空欄・0・ラジオ停止では設定前の値に戻します。元の値はRAMだけに保存し、変更後の値が純正APIから読めない場合は失敗として扱います。純正値が112µsより大きい場合は、計算結果がドライバーの上限255µsを超える設定を拒否します。動的な距離推定とCTS・スロット時間の調整には対応していません。

標準WirelessのWMM、802.11k/v、MACフィルター、暗号化、送信出力、フラグメント閾値を純正の設定へ反映します。独自のATF・詳細QoS・Neighbor AP・puncturingの管理処理は含めません。既存の純正UCI値は変更せず、純正コントローラーが引き続き読み取ります。送信出力が無線機・VAPのどちらにも指定されていない場合は、純正処理と同じく追加の書き込みを行いません。未指定値を0に置き換えると、MLOと個別SSIDの併用時に起動が失敗する場合があります。無線起動や設定反映の失敗では成功状態を保存せず、次回の再試行で設定し直します。

次のコマンドで、ハードウェアを操作せずに再読み込み・停止・再起動の処理を確認できます。

```sh
python3 contrib/qsdk/selfcheck.py
```

WN-7T94XR v2.5.1 用の IPK と導入手順は [LuCI フォーク](https://github.com/onokatio/luci/tree/qsdk-25.12/contrib/wn7t94xr)で管理しています。純正の Qualcomm 制御スクリプトは含めていません。他の QSDK 機種や EasyMesh の再構成は未検証です。
