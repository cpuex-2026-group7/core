# Frontend 回帰テスト

WSL/Linux の Verilator と C++ ビルド環境で、リポジトリ直下から実行します。

```sh
make -C test/frontend lint
make -C test/frontend
```

ビルド先は `BUILD_DIR=/tmp/frontend-test` などで変更できます。
`i_mem` の初期化後、テストごとに命令を設定します。仮置きメモリの固定2段レイテンシと
enableによる保持を前提とします。

確認する動作:

- PC=0と非ゼロのリセットベクタからの開始、逐次フェッチ。
- BTBミス時のfrontend redirectで、分岐命令と修正先を保持すること。
- 学習済みBTBの予測と、予測先でBTBミスした際の逐次PC。
- 学習済み分岐ループに余分な命令やバブルが入らないこと。
- backend redirectでFetch Queueと古いパイプラインを破棄すること。
- Fetch Queue満杯／FTQ満杯中でもbackend redirectを取り込むこと。
- FTQを満杯のまま復元しても、無効なF3で停止せず非分岐命令を流せること。
- stall中のfrontend redirectを保持し、再開時に一度だけ適用すること。
- backend redirectがfrontend redirectと古い命令のBTB更新に優先すること。
- 連続したbackend redirectと、初回要求より先に来るbackend redirect。
- backend redirectでsrcのPCにBTBを学習させ、次に通るときバブル無しで予測すること。

Fetch Queueの出力をスコアボードと比較し、PCと命令の対応も確認します。
