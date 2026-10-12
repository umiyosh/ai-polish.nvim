--- BudouX parser for CJK text segmentation.
--- Ported to Lua from https://github.com/google/budoux
--- Original work Copyright 2021 Google LLC, licensed under Apache-2.0.
--- See LICENSE and NOTICE in the project root.
---
--- Uses a compact machine-learning model to find natural word boundaries in CJK text,
--- producing more readable line breaks than character-level splitting.

local M = {}

-- Boundary markers used to pad the beginning/end of text
local INVALID = "\xef\xbf\xbd" -- U+FFFD REPLACEMENT CHARACTER

--- Iterate over UTF-8 characters in a string.
---@param s string
---@return string[]
local function utf8_chars(s)
  local chars = {}
  for c in s:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    chars[#chars + 1] = c
  end
  return chars
end

--- Parse text into chunks using a BudouX model (internal implementation).
---@param model table BudouX model
---@param text string Input text
---@return string[] chunks
local function parse(model, text)
  local chars = utf8_chars(text)
  if #chars == 0 then
    return {}
  end

  local chunks = {}
  local chunk_start = 1

  -- We examine each position i (between chars[i-1] and chars[i]).
  -- Features use a window of 6 characters centered around the boundary.
  for i = 2, #chars do
    local p1 = chars[i - 3] or INVALID
    local p2 = chars[i - 2] or INVALID
    local p3 = chars[i - 1] or INVALID
    local w1 = chars[i]
    local w2 = chars[i + 1] or INVALID
    local w3 = chars[i + 2] or INVALID

    local score = -model.base_score

    -- Unigram features
    local uw1 = model.UW1
    local uw2 = model.UW2
    local uw3 = model.UW3
    local uw4 = model.UW4
    local uw5 = model.UW5
    local uw6 = model.UW6
    if uw1 then score = score + (uw1[p1] or 0) end
    if uw2 then score = score + (uw2[p2] or 0) end
    if uw3 then score = score + (uw3[p3] or 0) end
    if uw4 then score = score + (uw4[w1] or 0) end
    if uw5 then score = score + (uw5[w2] or 0) end
    if uw6 then score = score + (uw6[w3] or 0) end

    -- Bigram features
    local bw1 = model.BW1
    local bw2 = model.BW2
    local bw3 = model.BW3
    if bw1 then score = score + (bw1[p2 .. p3] or 0) end
    if bw2 then score = score + (bw2[p3 .. w1] or 0) end
    if bw3 then score = score + (bw3[w1 .. w2] or 0) end

    -- Trigram features
    local tw1 = model.TW1
    local tw2 = model.TW2
    local tw3 = model.TW3
    local tw4 = model.TW4
    if tw1 then score = score + (tw1[p1 .. p2 .. p3] or 0) end
    if tw2 then score = score + (tw2[p2 .. p3 .. w1] or 0) end
    if tw3 then score = score + (tw3[p3 .. w1 .. w2] or 0) end
    if tw4 then score = score + (tw4[w1 .. w2 .. w3] or 0) end

    if score > 0 then
      -- Collect the chunk from chunk_start to i-1
      local parts = {}
      for j = chunk_start, i - 1 do
        parts[#parts + 1] = chars[j]
      end
      chunks[#chunks + 1] = table.concat(parts)
      chunk_start = i
    end
  end

  -- Remaining tail
  local parts = {}
  for j = chunk_start, #chars do
    parts[#parts + 1] = chars[j]
  end
  chunks[#chunks + 1] = table.concat(parts)

  return chunks
end

--- @class budoux.Parser
--- @field model table The BudouX model data
local Parser = {}
Parser.__index = Parser
M.Parser = Parser

--- Create a new Parser with the given model.
---@param model table BudouX model (e.g. require("budoux.models.ja"))
---@return budoux.Parser
function Parser.new(model)
  return setmetatable({ model = model }, Parser)
end

--- Parse text into chunks using the BudouX model.
--- Each chunk represents a segment that should not be broken across lines.
---@param text string Input text
---@return string[] chunks
function Parser:parse(text)
  return parse(self.model, text)
end

--- Load a default Japanese parser.
---@return budoux.Parser
function M.load_default_japanese_parser()
  return Parser.new(require("budoux.models.ja"))
end

--- Load a default Simplified Chinese parser.
---@return budoux.Parser
function M.load_default_simplified_chinese_parser()
  return Parser.new(require("budoux.models.zh_hans"))
end

--- Load a default Traditional Chinese parser.
---@return budoux.Parser
function M.load_default_traditional_chinese_parser()
  return Parser.new(require("budoux.models.zh_hant"))
end

--- Load a default Thai parser.
---@return budoux.Parser
function M.load_default_thai_parser()
  return Parser.new(require("budoux.models.th"))
end

return M
