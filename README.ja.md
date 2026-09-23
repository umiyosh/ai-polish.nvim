# ai-polish.nvim

[English](README.md) | 日本語

Gemini で文章を校正・推敲する Neovim プラグイン。

選択範囲またはバッファ全体を Gemini に送り、返ってきた修正候補をバッファ上の下線とフローティングウィンドウで示す。候補はキーボードで 1 件ずつ採用・却下する。専用のメイン画面は持たない。

```
今日わ良い天気です。
午後╭ AI Polish ───────────────────────────────────────╮
    │typo · warning                                 1/2│
    │助詞「は」の誤りです。                            │
    │                                                  │
    │- わ                                              │
    │1 は                                              │
    │                                                  │
    │a accept  x reject  ] next  [ prev  A all  q close│
    ╰──────────────────────────────────────────────────╯
```

## 要件

- Neovim 0.11 以上
- `curl`
- Gemini API キー（[Google AI Studio](https://aistudio.google.com/apikey) で発行）

他のプラグインには依存しない。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "umiyosh/ai-polish.nvim",
  cmd = "AiPolish",
  keys = {
    { "<leader>ap", "<Plug>(ai-polish-selection)", mode = "x", desc = "Proofread selection" },
    { "<leader>ap", "<Plug>(ai-polish-buffer)", mode = "n", desc = "Proofread buffer" },
    { "<leader>ar", "<Plug>(ai-polish-review)", mode = "n", desc = "Review suggestions" },
  },
  opts = {},
}
```

`setup()` は省略できる。呼ばない場合はデフォルト設定で動く。

## API キーの設定

次の順で探す。

1. `setup({ api_key = ... })` に渡した文字列、または文字列を返す関数
2. 環境変数 `GEMINI_API_KEY`
3. 環境変数 `GOOGLE_API_KEY`

キーを設定ファイルに直書きしないこと。シェルで環境変数に入れるか、パスワードマネージャから関数で読む。

```sh
# ~/.zshrc など
export GEMINI_API_KEY="..."
```

```lua
-- macOS キーチェーンから読む例（初回呼び出し時に 1 回だけ実行される）
opts = {
  api_key = function()
    return vim.trim(vim.fn.system({ "security", "find-generic-password", "-s", "gemini-api-key", "-w" }))
  end,
}
```

```lua
-- 1Password CLI から読む例
api_key = function()
  return vim.trim(vim.fn.system({ "op", "read", "op://Private/Gemini/credential" }))
end
```

キーは `x-goog-api-key` ヘッダで送る。curl にはパーミッション 0600 の一時ファイル経由で渡すので、`ps` のコマンドラインにキーは現れない。

`:checkhealth ai-polish` で curl の有無とキーの設定状況を確認できる。

> [!IMPORTANT]
> 校正対象の文章は Google の Gemini API に送信される。Gemini API の無料枠では、送信内容が Google のプロダクト改善に使われる（[利用規約](https://ai.google.dev/gemini-api/terms)）。機密文書を扱う場合は有料枠のキーを使うこと。

## 使い方

| コマンド | 動作 |
| --- | --- |
| `:AiPolish` | バッファ全体を校正する |
| `:'<,'>AiPolish` | Visual モードの選択範囲を校正する（文字単位の `v` 選択も範囲どおりに扱う） |
| `:AiPolish review` | 残っている候補のポップアップを開き直す（カーソル以降の最初の候補から） |
| `:AiPolish cancel` | 実行中のリクエストを中止する |
| `:AiPolish clear` | 候補とハイライトをすべて消す |

`:AiPolish buffer` / `:AiPolish selection` でも明示的に指定できる。

### ポップアップのキー

ポップアップにはフォーカスが移り、以下のキーはポップアップ内だけで効く。

| キー | 動作 |
| --- | --- |
| `a` / `<CR>` | カーソル行の修正案を採用（カーソルは最初の案の行に置かれる） |
| `1` `2` `3` | その番号の修正案を採用 |
| `x` | 却下 |
| `]` / `[` | 次 / 前の候補 |
| `A` | 残りの候補をすべて第 1 案で採用する（undo 1 回で戻せる） |
| `X` | 残りの候補をすべて却下 |
| `q` / `<Esc>` | 閉じる。候補は残り、`:AiPolish review` で再開できる |

個々の採用はそれぞれ 1 回の undo で戻せる。ポップアップを閉じたままバッファを編集してもかまわない。候補の位置は extmark で追跡しており、編集で変わった箇所の候補は適用前の照合で自動的に外れる。

### 状態の表示

| 状態 | 表示 |
| --- | --- |
| 処理中 | 対象範囲の先頭行の末尾にスピナー（`⠋ AI Polish: proofreading 2/5…`）を出す |
| 完了 | 件数を通知してポップアップを開く。挿入モード中などで開けないときは、`:AiPolish review` を案内する |
| 指摘なし | `no issues found` を通知する |
| エラー | HTTP ステータス・API のエラー文・安全性ブロックの理由を `vim.notify` の ERROR で出す |
| 一部失敗 | 分割送信の一部が失敗したら WARN を出し、成功した分の候補だけを表示する |
| キャンセル | `:AiPolish cancel`、または確認ダイアログで Cancel |

ステータスラインに出す場合は `require("ai-polish").status()` を使う。アイドル時は空文字、処理中は `AI Polish 2/5`、候補が残っていれば `AI Polish: 3` を返す。

```lua
-- lualine の例
sections = { lualine_x = { function() return require("ai-polish").status() end } }
```

## 長い文書の扱い

- 送信前にサイズとコストをローカルで概算する。見積もりのために API を呼ぶこと（countTokens など）はしないので、承認前に本文が外部へ出ることはない。
- 次のいずれかを超えたら `confirm()` ダイアログを出し、明示的に承認されたときだけ送信する。
  - 文字数 `guard.confirm_chars`（既定 12,000）
  - 推定コスト `guard.confirm_cost_usd`（既定 $0.05）
  - リクエスト数 `guard.confirm_requests`（既定 4）
- `guard.max_chars`（既定 400,000 文字）を超える場合は送信を拒否し、範囲を絞るよう案内する。
- `chunk.max_chars`（既定 6,000 文字）を超える文章は分割して送る。区切りは段落 → 行 → 文末（`。` `．` など）→ 読点 → 空白の順で探す。リクエストは `chunk.concurrency`（既定 2）件ずつ並列に送る。分割する理由は、1 リクエストの出力が大きすぎると JSON が途中で切れる（MAX_TOKENS）ことと、指摘の精度が落ちることの 2 つ。

トークン数は、ASCII 4 文字 ≒ 1 トークン、それ以外（日本語など）1 文字 ≒ 1 トークンとして概算する。出力は入力の 6 割に固定のオーバーヘッドを足した値で見積もる。いずれも多めに出る目安で、請求額そのものではない。単価は `pricing` で上書きできる。

## 設定

既定値:

```lua
require("ai-polish").setup({
  api_key = nil,                 -- string | fun(): string。nil なら $GEMINI_API_KEY / $GOOGLE_API_KEY
  model = "gemini-3.8-flash",
  endpoint = "https://generativelanguage.googleapis.com/v1beta",
  thinking_level = "low",        -- "low" | "medium" | "high" | nil（モデル既定）
  temperature = nil,
  timeout_ms = 120000,
  language = nil,                -- 指摘理由の言語。nil なら本文と同じ言語
  instructions = nil,            -- 追加指示（表記ルール、用語集など）

  chunk = { max_chars = 6000, concurrency = 2 },
  guard = {
    confirm_chars = 12000,
    confirm_cost_usd = 0.05,
    confirm_requests = 4,
    max_chars = 400000,
  },

  -- 見積もり用の単価（USD / 1M tokens）
  pricing = {
    ["gemini-3.8-flash"] = { input_per_mtok = 1.50, output_per_mtok = 7.50 },
    -- ...
  },
  default_pricing = { input_per_mtok = 1.50, output_per_mtok = 9.00 },

  ui = { border = "rounded", max_width = 80 },

  -- ポップアップ内のキー。false で無効化
  keymaps = {
    accept = "a", reject = "x", next = "]", prev = "[",
    accept_all = "A", reject_all = "X", close = "q",
  },
})
```

設定例:

```lua
require("ai-polish").setup({
  model = "gemini-3.5-flash-lite", -- 安価なモデルに切り替える
  language = "日本語",
  instructions = [[
- 「行う」「おこなう」は「行う」に統一する
- 英単語と日本語の間に半角スペースを入れない
]],
  guard = { confirm_chars = 30000, confirm_cost_usd = 0.2 },
  keymaps = { next = "n", prev = "p" },
})
```

`pricing` の既定値は gemini-3.8-flash の標準単価（2027 年 1 月以降の価格）。2026 年末までの導入価格（$0.75 / $3.75）より高く、見積もりは多めに出る。

### ハイライト

すべて `default = true` でリンクしている。カラースキーム側で上書きできる。

| グループ | 既定のリンク先 |
| --- | --- |
| `AiPolishCritical` / `AiPolishWarning` / `AiPolishSuggestion` / `AiPolishInfo` | `DiagnosticUnderline{Error,Warn,Info,Hint}` |
| `AiPolishCurrent` | `Visual` |
| `AiPolishDelete` / `AiPolishAdd` | `DiffDelete` / `DiffAdd` |
| `AiPolishTitle` / `AiPolishHint` | `Title` / `Comment` |
| `AiPolishProgress` | `DiagnosticVirtualTextInfo` |

## 設計メモ

- **位置の特定**: モデルには offset を返させない。原文から完全一致で抜き出した `before` と、その前後の文脈 `context_before` / `context_after` を返させる。プラグイン側では `before` の出現箇所を全部探し、文脈がもっとも長く一致する箇所を選ぶ。見つからない候補と、他の候補と重なる候補は捨てる。
- **位置の追跡**: 候補は extmark としてバッファに固定する。他の候補の採用や手作業の編集で位置がずれても、extmark が追従する。適用直前に固定範囲の現在テキストと `before` を照合し、一致しなければ適用しない。
- **応答形式**: Gemini の構造化出力（`responseMimeType: application/json` + `responseJsonSchema`）を使う。`promptFeedback.blockReason` と `finishReason`（SAFETY / MAX_TOKENS など）はエラーとして扱う。
- **リトライ**: 429 / 5xx / ネットワークエラーは 1 秒 → 2 秒の間隔で最大 2 回まで再試行する。タイムアウトは再試行しない。

## 開発

```sh
make test       # plenary.nvim の busted でテスト（初回は .tests/ に plenary を clone）
make lint       # luacheck
make fmt        # stylua で整形
make fmt-check  # 整形差分チェック
make check      # lint + fmt-check + test
```

ローカルにある plenary を使う場合は `PLENARY_DIR=/path/to/plenary.nvim make test` とする。

CI（GitHub Actions）は push / pull request ごとに次を実行する。

- test: Neovim v0.11.0 と stable のマトリクス
- lint: luacheck
- format: stylua `--check`

## License

MIT
