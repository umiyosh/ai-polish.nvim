# Creating a Gemini API key in Google AI Studio

[日本語](api-key.ja.md)

ai-polish.nvim calls the Gemini API with an API key. This page covers creating the key in Google AI Studio and handing it to the plugin.

## 1. Create the key

1. Open the [API keys page](https://aistudio.google.com/api-keys) in Google AI Studio and sign in with your Google account.
2. On first use, accept the terms of service. AI Studio then creates a default Google Cloud project for you.
3. Click **Create API key**.
4. Choose a project. Use the default project, or **Create API key in new project** to keep this key separate from other uses.
5. Copy the key string that is shown.

Every key belongs to a Google Cloud project, and billing and rate limits are tracked per project. To use a project that already exists in Google Cloud but is not listed, open **Projects** from the dashboard, click **Import projects**, and select it.

> [!NOTE]
> Since May 28, 2026, new keys created in AI Studio are authorization keys (auth keys), restricted to the Gemini API by default. The Gemini API stops accepting standard keys in September 2026. If the **Key type** column on the API keys page shows **Standard** for your key, create a new one and delete the old one. See [Using Gemini API keys](https://ai.google.dev/gemini-api/docs/api-key).

## 2. Store the key

Do not write the key in your Neovim config or commit it to a dotfiles repository. Choose one of the following.

Environment variable:

```sh
# ~/.zshrc etc.
export GEMINI_API_KEY="..."
```

macOS Keychain (the command prompts for the key, so it stays out of your shell history):

```sh
security add-generic-password -a "$USER" -s gemini-api-key -w
```

Then read it with a function, as shown in [Setting the API key](../README.md#setting-the-api-key).

## 3. Verify

Check that the key works by listing the available models:

```sh
curl -s "https://generativelanguage.googleapis.com/v1beta/models" \
  -H "x-goog-api-key: $GEMINI_API_KEY" | head
```

A JSON list of models means the key works. An `error` object with `API_KEY_INVALID` or `PERMISSION_DENIED` means the key is wrong, blocked, or restricted to other APIs.

In Neovim, run `:checkhealth ai-polish`.

## Free tier and paid tier

A new project starts on the free tier. On the free tier, Google may use the content you send to improve its products (see the [Gemini API terms](https://ai.google.dev/gemini-api/terms)). To proofread confidential documents or get higher rate limits, click **Set up billing** on the **Plan & Pricing** or **Settings** page in AI Studio and move the project to the paid tier.

## If the key leaks

Delete the key on the API keys page and create a new one. Any application still using the deleted key stops working, so update it to the new key.
