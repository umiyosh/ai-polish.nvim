[![CI](https://github.com/umiyosh/ai-polish.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/umiyosh/ai-polish.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)

# ai-polish.nvim

[English](README.md) | 日本語

**Neovim で書いた文章を Gemini にレビューしてもらい、直すかどうかは 1 件ずつ自分で決められます。**

Visual モードで選んだ範囲か、バッファ全体に対して `:AiPolish` を実行します。指摘された箇所には下線が引かれ、フローティングウィンドウに該当箇所、最大 3 つの修正案、その理由が 1 件ずつ表示されます。修正案を採用しない限り、本文はそのままです。

![デモ: バッファを校正し、AI Polish のポップアップで修正候補を採用する様子](docs/images/demo-ja.gif)

## 特徴

ai-polish.nvim は Gemini をレビュアーとして使います。文章をまるごと書き直させて新旧を見比べる、という手間はかかりません。

- 指摘は小さく分かれて届きます。Gemini には、直す範囲を最小限にすること、1 件に含める修正は 1 つだけにすること、段落ごと書き直さないことを指示しています。1 件ずつ、その場で判断できます。
- 反映するかどうかは自分で選びます。`a` で採用、`x` で却下、`]` / `[` で前後の候補へ。採用した修正は、1 件ごとに undo 1 回で元に戻せます。
- 校正の途中でも本文を編集できます。候補はバッファ上の位置に固定してあり、適用の直前に現在のテキストと照合します（[設計メモ](#設計メモ)）。
- 画面はバッファのまま。チャット画面やサイドウィンドウは開かず、ポップアップは指摘箇所のすぐそばに出ます。
- 知らないうちに大量のテキストが送られることはありません。サイズとコストを手元で概算し、大きなリクエストは確認を取ってから送ります（[長い文書の扱い](#長い文書の扱い)）。

## 要件

- Neovim 0.11 以上
- `curl`
- Gemini API キー（発行手順は [Gemini API キーの発行](docs/api-key.ja.md)）

他のプラグインは必要ありません。

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

`setup()` は省略でき、呼ばなければデフォルト設定で動きます。

### バージョンの指定と更新

リリースには `vMAJOR.MINOR.PATCH` 形式の Git タグを付けます。公開済みのバージョンと変更内容は [GitHub Releases](https://github.com/umiyosh/ai-polish.nvim/releases) に掲載します。
初回は **v0.1.0** を予定しています。タグが公開されるまでは上のインストール例を使ってください。lazy.nvim 全体のバージョン制約を設定していなければ、デフォルトブランチを追従します。

v0.1.0 公開後は、上の lazy.nvim 設定に次のうち **1 つ**を追加できます。

| 設定 | 更新時の動作 |
| --- | --- |
| `version = "^0.1.0"` | おすすめ。0.1.x のリリースへ更新し、0.2.0 には進みません |
| `tag = "v0.1.0"` | v0.1.0 に固定します |
| `version = "*"` | 最新リリースへ更新します。minor・major の変更も含み、プレリリースのタグは除外します |
| `branch = "master", version = false` | リリースではなく開発中のコミットを追従します |

`:Lazy update ai-polish.nvim` で、指定範囲内のバージョンへ更新できます。`lazy-lock.json` をバージョン管理すると導入したコミットを再現でき、`:Lazy restore` で復元できます。詳細は lazy.nvim の [バージョン指定](https://lazy.folke.io/spec/versioning)・[lockfile](https://lazy.folke.io/usage/lockfile) の説明を参照してください。

[vim-plug](https://github.com/junegunn/vim-plug) では、リリース公開後に既存の `plug#begin()` / `plug#end()` 内でタグを指定できます。

```vim
Plug 'umiyosh/ai-polish.nvim', { 'tag': 'v0.1.0' }
```

vim-plug を使う場合も **Neovim 0.11 以上**が必要です。Vim 本体には対応していません。
1.0 未満の間は、同じ minor 系列の patch 更新では互換性を保ち、新しい minor 系列では互換性のない変更を含む場合があります。更新前にリリースノートを確認してください。メンテナー向けの公開手順は [Releasing](docs/releasing.md) に記載しています。

## API キーの設定

キーは次の順に探します。

1. `setup({ api_key = ... })` に渡した文字列、または文字列を返す関数
2. 環境変数 `GEMINI_API_KEY`
3. 環境変数 `GOOGLE_API_KEY`

設定ファイルにキーを直接書くのは避けてください。シェルの環境変数に入れるか、パスワードマネージャから関数で読み出すのがおすすめです。関数を渡した場合、呼ばれるのは初めて使うときで、結果は次に `setup()` を呼ぶまでキャッシュされます。失敗したときや空文字が返ったときは、次回もう一度呼ばれます。なお、空文字で export された環境変数は未設定として扱います。

```sh
# ~/.zshrc など
export GEMINI_API_KEY="..."
```

```lua
-- macOS キーチェーンから読む例
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

キーは `x-goog-api-key` ヘッダに載せて送ります。curl へはパーミッション 0600 の一時ファイル経由で渡すため、`ps` で見えるコマンドラインにキーは出ません。

curl が入っているか、キーが設定されているかは `:checkhealth ai-polish` で確認できます。

> [!IMPORTANT]
> 校正する文章は Google の Gemini API に送信されます。無料枠のキーでは、送った内容が Google のプロダクト改善に使われます（[利用規約](https://ai.google.dev/gemini-api/terms)）。機密文書を扱うなら有料枠のキーを使ってください。

## 使い方

| コマンド | 動作 |
| --- | --- |
| `:AiPolish` | バッファ全体を校正 |
| `:'<,'>AiPolish` | Visual モードの選択範囲を校正（文字単位の `v` 選択も範囲どおりに扱います） |
| `:AiPolish review` | 残っている候補のポップアップを開き直す（カーソル以降にある最初の候補から） |
| `:AiPolish cancel` | 実行中のリクエストを中止 |
| `:AiPolish clear` | 候補とハイライトをすべて消去 |

対象を明示したいときは `:AiPolish buffer` / `:AiPolish selection` と書くこともできます。

### ポップアップのキー

ポップアップが開くとフォーカスはそちらへ移ります。以下のキーが効くのはポップアップの中だけです。

| キー | 動作 |
| --- | --- |
| `a` / `<CR>` | カーソル行の修正案を採用（開いた時点でカーソルは第 1 案の行にあります） |
| `1` `2` `3` | その番号の修正案を採用 |
| `x` | 却下 |
| `]` / `[` | 次 / 前の候補 |
| `A` | 残りの候補をすべて第 1 案で採用（undo 1 回で戻せます） |
| `X` | 残りの候補をすべて却下 |
| `q` / `<Esc>` | 閉じる。候補は残るので `:AiPolish review` で再開できます |

ポップアップを閉じてバッファを編集しても問題ありません。編集で内容が変わった箇所の候補は、誤って適用されないよう自動的に外れます。

### 状態の表示

| 状態 | 表示 |
| --- | --- |
| 処理中 | エディター右下のフローティングウィンドウにスピナー（`⠋ AI Polish: proofreading 2/5…`）を表示します。スクロールや本文の装飾に影響されず、入力フォーカスも奪いません |
| 完了 | 件数を通知してポップアップを開きます。挿入モード中などで開けないときは `:AiPolish review` を案内します |
| 指摘なし | `no issues found` を通知 |
| エラー | HTTP ステータス、API のエラー文、安全性ブロックの理由を `vim.notify` の ERROR で表示 |
| 一部失敗 | 分割送信の一部が失敗すると WARN を出し、成功した分の候補だけを表示します |
| キャンセル | `:AiPolish cancel`、または確認ダイアログで Cancel |

ステータスラインに出したいときは `require("ai-polish").status()` を使ってください。返り値はアイドル時が空文字、処理中が `AI Polish 2/5`、候補が残っているときが `AI Polish: 3` です。

```lua
-- lualine の例
sections = { lualine_x = { function() return require("ai-polish").status() end } }
```

### 表示言語

ポップアップに出る分類・重要度の名前と、Gemini が書く指摘理由の言語は `locale`（`en` / `ja` / `zh-Hans` / `zh-Hant`。`zh` は簡体字の別名）で決まります。
`locale` を指定しなければ `v:lang` / `$LANG` から判定し、判定できないときは英語になります。
修正案そのものは常に本文と同じ言語です。キー操作の案内だけは英語で表示されます。

## 長い文書の扱い

- 送信前に、サイズとコストをローカルで概算します。見積もりのために countTokens などの API は呼ばないので、承認する前に本文が外へ出ることはありません。
- 次のどれかを超えると `confirm()` ダイアログが出て、承認したときだけ送信します。
  - 文字数 `guard.confirm_chars`（既定 12,000）
  - 推定コスト `guard.confirm_cost_usd`（既定 $0.05）
  - リクエスト数 `guard.confirm_requests`（既定 4）
- `guard.max_chars`（既定 400,000 文字）を超えると送信せず、範囲を絞るよう案内します。
- `chunk.max_chars`（既定 6,000 文字）より長い文章は分割して送ります。区切り位置は段落 → 行 → 文末（`。` `．` など）→ 読点 → 空白の順に探し、リクエストは `chunk.concurrency`（既定 2）件ずつ並列に送ります。1 リクエストの出力が大きくなりすぎると JSON が途中で切れ（MAX_TOKENS）、指摘の精度も落ちるためです。

トークン数は ASCII なら 4 文字で約 1 トークン、日本語などそれ以外は 1 文字で約 1 トークンとして数えます。出力側は、入力の 6 割に固定のオーバーヘッドを足して見積もります。どちらも多めに出る目安で、実際の請求額とは一致しません。単価は `pricing` で上書きできます。

## Jevによる文章評価（任意）

Geminiで校正する前に、Jevで「もう一度校正にかける価値があるか」を確認できます。Jevキーを設定しなければ、評価パネルや設定催促は出ず、従来のGemini校正だけを使えます。

キーはローカルの環境変数 `TYPESAFE_API_KEY`、または `evaluation.api_key`（文字列／キーを返す関数）で設定してください。設定ファイルにキーを直接書いてコミットしないでください。関数は明示的なJev操作かhealth確認のときに呼び、取得できた値だけを次の `setup()` まで保持します。

```lua
-- 既存の lazy.nvim の keys に追加する例です。既定のキー割り当てではありません。
{ "<leader>ae", "<Plug>(ai-polish-evaluate)", mode = { "n", "x" }, desc = "文章評価" },
{ "<leader>at", "<Plug>(ai-polish-evaluation-toggle)", mode = { "n", "x" }, desc = "評価パネルの表示切替" },
-- 既存の <leader>ap などの校正キーはそのまま使います。
```

| 操作 | 動作 |
| --- | --- |
| `:AiPolish evaluate` | 前回の対象を評価。対象がない初回だけ全文 |
| Visualモードの評価キー／`:'<,'>AiPolish evaluate` | 選んだ範囲を評価。矩形選択は送信せず案内 |
| `:AiPolish evaluate buffer` | 対象を明示的に全文へ戻す |
| `:AiPolish toggle` | タブごとにパネルを表示／非表示。通信なし |
| `:AiPolish polish` | 保持している範囲の現在の文章をGeminiで校正 |
| `:AiPolish details` | 不自然さの局所的な根拠・評価範囲と、AIらしさの確率分布・確かさ。通信なし。q/Escで閉じ、j/kでスクロール |
| `:AiPolish cancel`／`clear` | 実行中の評価を中止。clearは対象と結果も消去 |

右下の30セル幅のパネルに、不自然さとAIらしさを2段で表示します。バーが多いほど問題が強いという意味です。AIらしさは機械的・定型的な文体の目安で、AIが書いた確率ではありません。確かさも、正しさの保証ではありません。

**Jevへの送信は評価操作をしたときだけです。** 入力・貼り付け・保存・校正候補の採用／却下・表示切替では通信しません。本文が変わると「前回」と再評価の操作を表示します。選択した範囲は修正後も追跡し、通常モードの評価キーでも同じ範囲を評価します。範囲が消えた場合は、全文へ広げず選び直しを案内します。

```lua
evaluation = {
  enabled = true,               -- falseならJevのUIを非表示
  api_key = nil,                -- nilなら $TYPESAFE_API_KEY
  model = "jev-latest",
  timeout_ms = 20000,
  max_chars = 12000,            -- Unicode文字数。超過時は送信しない
  language = "auto",            -- 本文の言語ヒント: auto/en/ja/zh-Hans/zh-Hant
  panel_width = 30,             -- 30〜60。60なら収まる場合に横並び
  uncertainty_threshold = 0.5,  -- 「判定に迷い」の表示基準。精度の保証値ではない
},
```

対象文章は[TypeSafeのAPI](https://docs.typesafe.ai/api)に送ります。[Kotobae #41](https://github.com/umiyosh/kotobae/pull/41)・[#44](https://github.com/umiyosh/kotobae/pull/44)に合わせ、不自然さは文と短い句ごとのNoulを集計し、AIらしさは全文Scoreで評価します。日本語では反復する仮名の文字参照と限定的な主述のねじれ規則も使います。中国語は句読点で句を分け、文字体系を変換せず、日本語固有の規則は使いません。中国語・英語の閾値は未較正です。

短文は1リクエスト。長文は60問ごと、最大4並列・16リクエストに制限します。不自然さの局所判定は上限までで、未評価部分が残る場合は「一部のみ」と評価文数／省略句数を表示します。上限は `evaluation.max_chars` と `guard.max_chars` の小さい方。`guard.confirm_chars` または `guard.confirm_requests` を超える場合は予定リクエスト数を示して確認します。12,000文字はクライアント側の制限です。自動再試行は行わず、1バッチでも失敗した場合は評価全体を失敗とします。Geminiの既存の制限・再試行はそのままです。

API未設定と認証エラーは区別します。パネルを隠しても送信済みの処理は継続しますが、応答で勝手に開きません。校正ポップアップと重なるときは一時的に隠し、Geminiの進捗表示は上に配置します。前回値も文字を薄くせず表示します。

[設計・検証記録](docs/jev.md)も参照できます。`nvim -u scripts/jev-demo.lua` で通信なしのUIデモを開けます。デモの値は表示例です。個人のキー割り当てやインストール済みプラグインを自動変更しません。

## 設定

既定値は次のとおりです。

```lua
require("ai-polish").setup({
  api_key = nil,                 -- string | fun(): string。nil なら $GEMINI_API_KEY / $GOOGLE_API_KEY
  model = "gemini-3.8-flash",
  endpoint = "https://generativelanguage.googleapis.com/v1beta",
  thinking_level = "low",        -- "low" | "medium" | "high" | nil（モデル既定）
  temperature = nil,
  timeout_ms = 120000,
  locale = nil,                  -- "en" | "ja" | "zh" | "zh-Hans" | "zh-Hant"。nil なら v:lang から判定し、判定できなければ "en"
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

  ui = { border = "rounded", max_width = 80, winblend = 0 }, -- winblend: ポップアップの透過度（0-100）

  -- ポップアップ内のキー。false で無効化
  keymaps = {
    accept = "a", reject = "x", next = "]", prev = "[",
    accept_all = "A", reject_all = "X", close = "q",
  },
})
```

設定例です。

```lua
require("ai-polish").setup({
  model = "gemini-3.5-flash-lite", -- 安価なモデルに切り替える
  locale = "ja",
  instructions = [[
- 「行う」「おこなう」は「行う」に統一する
- 英単語と日本語の間に半角スペースを入れない
]],
  guard = { confirm_chars = 30000, confirm_cost_usd = 0.2 },
  keymaps = { next = "n", prev = "p" },
})
```

`pricing` の既定値には gemini-3.8-flash の標準単価（2027 年 1 月以降の価格）を入れています。2026 年末までの導入価格（$0.75 / $3.75）より高いので、見積もりは多めに出ます。

### ハイライト

どのグループも `default = true` でリンクしているので、カラースキーム側で上書きできます。

| グループ | 既定のリンク先 |
| --- | --- |
| `AiPolishCritical` / `AiPolishWarning` / `AiPolishSuggestion` / `AiPolishInfo` | `DiagnosticUnderline{Error,Warn,Info,Hint}` |
| `AiPolishCurrent` | `Visual` |
| `AiPolishDelete` / `AiPolishAdd` | `DiffDelete` / `DiffAdd` |
| `AiPolishTitle` / `AiPolishHint` | `Title` / `Comment` |
| `AiPolishProgress` | `DiagnosticVirtualTextInfo` |

## 設計メモ

- **位置の特定**: モデルに offset は返させません。返させるのは、原文から完全一致で抜き出した `before` と、前後の文脈 `context_before` / `context_after` です。プラグインは `before` の出現箇所をすべて探し、文脈がいちばん長く一致する箇所を選びます。見つからなかった候補や、他の候補と重なる候補は捨てます。
- **位置の追跡**: 候補は extmark としてバッファに固定します。別の候補を採用したり手で編集したりして位置がずれても、extmark がついていきます。適用する直前には固定範囲の現在のテキストを `before` と照合し、食い違っていれば適用しません。
- **応答形式**: Gemini の構造化出力（`responseMimeType: application/json` + `responseJsonSchema`）を使います。`promptFeedback.blockReason` や `finishReason`（SAFETY / MAX_TOKENS など）が返ってきた場合はエラー扱いです。
- **リトライ**: 429、5xx、ネットワークエラーのときは 1 秒後、2 秒後と最大 2 回まで再試行します。タイムアウトした場合は再試行しません。

## 開発

```sh
make test       # plenary.nvim の busted でテスト（初回は .tests/ に plenary を clone）
make lint       # luacheck
make fmt        # stylua で整形
make fmt-check  # 整形差分チェック
make check      # lint + fmt-check + test
```

手元の plenary を使うなら `PLENARY_DIR=/path/to/plenary.nvim make test` を実行してください。

CI（GitHub Actions）では、push と pull request のたびに次のジョブが走ります。

- test: Neovim v0.11.0 と stable のマトリクス
- lint: luacheck
- format: stylua `--check`

## License

MIT
