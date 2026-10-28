local M = {}

-- The markdown_inline parser reads an `_` next to a digit as emphasis, so
-- `hw_002 ... hw_002` turns italic between the two names
-- (tree-sitter-grammars/tree-sitter-markdown#276). In CommonMark, an `_` after
-- a word character never opens emphasis, and one before a word character never
-- closes it.

---@param source integer|string
---@param row integer
---@param col integer
---@param byte integer
---@return string
local function char_at(source, row, col, byte)
  if type(source) == "string" then
    return byte < 0 and "" or source:sub(byte + 1, byte + 1)
  end
  local line = col < 0 and "" or vim.api.nvim_buf_get_lines(source, row, row + 1, false)[1] or ""
  return line:sub(col + 1, col + 1)
end

-- Whether the captured emphasis, or the emphasis of a captured delimiter, is
-- an `_` pair that CommonMark does not allow.
local function intraword(match, _, source, predicate)
  local node = match[predicate[2]] and match[predicate[2]][1]
  if node and node:type() == "emphasis_delimiter" then
    node = node:parent()
  end
  if not (node and (node:type() == "emphasis" or node:type() == "strong_emphasis")) then
    return false
  end
  local sr, sc, sb, er, ec, eb = node:range(true)
  local opens = char_at(source, sr, sc, sb) == "_" and char_at(source, sr, sc - 1, sb - 1):match("%w") ~= nil
  local closes = char_at(source, er, ec - 1, eb - 1) == "_" and char_at(source, er, ec, eb):match("%w") ~= nil
  return opens or closes
end

-- nvim-treesitter's markdown_inline highlights, with the check on emphasis.
local highlights = [[
(code_span) @markup.raw @nospell

((emphasis) @markup.italic
  (#not-anvim-intraword? @markup.italic))

((strong_emphasis) @markup.strong
  (#not-anvim-intraword? @markup.strong))

(strikethrough) @markup.strikethrough

(shortcut_link
  (link_text) @nospell)

((backslash_escape) @conceal
  (#offset! @conceal 0 0 0 -1)
  (#set! conceal ""))

((hard_line_break
  "\\" @conceal)
  (#set! conceal ""))

((code_span_delimiter) @conceal
  (#set! conceal ""))

((emphasis_delimiter) @conceal
  (#not-anvim-intraword? @conceal)
  (#set! conceal ""))

(inline_link
  [
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! conceal ""))

[
  (link_label)
  (link_text)
  (link_title)
  (image_description)
] @markup.link.label

((inline_link
  (link_destination) @_url) @_label
  (#set! @_label url @_url))

((image
  (link_destination) @_url) @_label
  (#set! @_label url @_url))

(image
  [
    "!"
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! conceal ""))

(full_reference_link
  [
    "["
    "]"
    (link_label)
  ] @markup.link
  (#set! conceal ""))

(collapsed_reference_link
  [
    "["
    "]"
  ] @markup.link
  (#set! conceal ""))

(shortcut_link
  [
    "["
    "]"
  ] @markup.link
  (#set! conceal ""))

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @markup.link.url @nospell

((uri_autolink) @_url
  (#offset! @_url 0 1 0 -1)
  (#set! @_url url @_url))

(entity_reference) @nospell

((entity_reference) @character.special
  (#eq? @character.special "&nbsp;")
  (#set! conceal " "))

((entity_reference) @character.special
  (#eq? @character.special "&lt;")
  (#set! conceal "<"))

((entity_reference) @character.special
  (#eq? @character.special "&gt;")
  (#set! conceal ">"))

((entity_reference) @character.special
  (#eq? @character.special "&amp;")
  (#set! conceal "&"))

((entity_reference) @character.special
  (#eq? @character.special "&quot;")
  (#set! conceal "\""))

((entity_reference) @character.special
  (#any-of? @character.special "&ensp;" "&emsp;")
  (#set! conceal " "))
]]

function M.setup()
  vim.treesitter.query.add_predicate("anvim-intraword?", intraword, { force = true })
  vim.treesitter.query.set("markdown_inline", "highlights", highlights)
end

return M
