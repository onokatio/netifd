# QSDK 対応フォーク

純正の無線制御処理を使う netifd プラグインです。[実装・確認方法](contrib/qsdk/README.md)と [WN-7T94XR 用 IPK](https://github.com/onokatio/luci/tree/qsdk-25.12/contrib/wn7t94xr)を参照してください。

既定ブランチの `qsdk-19.07` は、OpenWrt 19.07 系を基にした、純正 netifd 向けのプラグインを管理しています。ブランチ名は互換対応の基になった系統を表し、LuCI のバージョンとは別です。現在の LuCI 25.12 構成でもこのプラグインを使い、純正 netifd 本体のバイナリーは置き換えません。
