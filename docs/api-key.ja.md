# Google AI Studio で Gemini API キーを発行する

[English](api-key.md)

ai-polish.nvim は API キーで Gemini API を呼び出す。このページでは、Google AI Studio でキーを発行し、プラグインに渡すまでの手順を説明する。

## 1. キーを発行する

1. Google AI Studio の [API キーページ](https://aistudio.google.com/api-keys)を開き、Google アカウントでログインする。
2. 初回は利用規約に同意する。同意すると、AI Studio がデフォルトの Google Cloud プロジェクトを作成する。
3. **Create API key** を押す。
4. プロジェクトを選ぶ。デフォルトのプロジェクトでもよい。他の用途とキーを分けたい場合は **Create API key in new project** を選ぶ。
5. 表示されたキー文字列をコピーする。

キーは必ずどれかの Google Cloud プロジェクトに属し、課金とレート制限はプロジェクト単位で管理される。Google Cloud に既にあるプロジェクトが一覧に出ない場合は、ダッシュボードの **Projects** から **Import projects** を押して取り込む。

> [!NOTE]
> 2026 年 5 月 28 日以降、AI Studio で新しく作るキーは認可キー（auth key）になり、既定で Gemini API 専用に制限される。Gemini API は 2026 年 9 月に標準キー（standard key）の受け付けを終了する。API キーページの **Key type** 列が **Standard** になっているキーを使っている場合は、新しいキーを作って古いキーを削除すること。詳細は [Using Gemini API keys](https://ai.google.dev/gemini-api/docs/api-key) を参照。

## 2. キーを保管する

キーを Neovim の設定ファイルに書いたり、dotfiles リポジトリにコミットしたりしないこと。次のどちらかで保管する。

環境変数に入れる場合:

```sh
# ~/.zshrc など
export GEMINI_API_KEY="..."
```

macOS キーチェーンに入れる場合（キーは入力プロンプトで渡すので、シェル履歴に残らない）:

```sh
security add-generic-password -a "$USER" -s gemini-api-key -w
```

キーチェーンからの読み出しは、[API キーの設定](../README.ja.md#api-キーの設定)にある関数の例を使う。

## 3. 動作を確認する

利用できるモデルの一覧を取得して、キーが有効かを確かめる。

```sh
curl -s "https://generativelanguage.googleapis.com/v1beta/models" \
  -H "x-goog-api-key: $GEMINI_API_KEY" | head
```

モデル一覧の JSON が返ればキーは有効。`API_KEY_INVALID` や `PERMISSION_DENIED` を含む `error` が返った場合は、キーの誤り、ブロック、または他の API 向けの制限が考えられる。

Neovim では `:checkhealth ai-polish` を実行する。

## 無料枠と有料枠

新しいプロジェクトは無料枠から始まる。無料枠では、送信した内容が Google のプロダクト改善に使われることがある（[Gemini API 利用規約](https://ai.google.dev/gemini-api/terms)）。機密文書を校正したい場合や、レート制限を上げたい場合は、AI Studio の **Plan & Pricing** または **Settings** ページで **Set up billing** を押し、プロジェクトを有料枠に切り替える。

## キーが漏れたとき

API キーページでそのキーを削除し、新しいキーを作る。削除したキーを使っているアプリケーションは動かなくなるので、新しいキーに差し替える。
