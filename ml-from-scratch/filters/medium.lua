--[[ medium.lua — make a Quarto post importable by Medium.

Runs only under the `medium` profile (see _quarto-medium.yml), after Quarto's
own filters, so cross-references are already resolved when we see them.

  * display equations  -> PNG images, one per paragraph (numbers included)
  * inline math        -> Unicode italics, e.g. w_{ij} -> wᵢⱼ
  * cross-ref links    -> plain text ("Equation 1"), since Medium has no anchors
  * relative links     -> absolute URLs on the published site
  * footnotes          -> [n] markers plus a "Notes" section at the end
  * tables             -> warning only (Medium has no tables)
  * <link rel=canonical> pointing at the real post on the site
]]

-- Where equation images come from. \dpi keeps them sharp on retina screens;
-- the white background keeps them readable in Medium's dark mode.
local IMAGE_URL = "https://latex.codecogs.com/png.image?"
local IMAGE_PREFIX = "\\dpi{300}\\bg{white}"

local base_url = ""
local notes = {}
local unconverted = {}

local SUB = {
  ["0"]="₀",["1"]="₁",["2"]="₂",["3"]="₃",["4"]="₄",["5"]="₅",["6"]="₆",
  ["7"]="₇",["8"]="₈",["9"]="₉",["+"]="₊",["-"]="₋",["−"]="₋",["="]="₌",
  ["("]="₍",[")"]="₎",a="ₐ",e="ₑ",h="ₕ",i="ᵢ",j="ⱼ",k="ₖ",l="ₗ",m="ₘ",
  n="ₙ",o="ₒ",p="ₚ",r="ᵣ",s="ₛ",t="ₜ",u="ᵤ",v="ᵥ",x="ₓ",
}
local SUP = {
  ["0"]="⁰",["1"]="¹",["2"]="²",["3"]="³",["4"]="⁴",["5"]="⁵",["6"]="⁶",
  ["7"]="⁷",["8"]="⁸",["9"]="⁹",["+"]="⁺",["-"]="⁻",["−"]="⁻",["="]="⁼",
  ["("]="⁽",[")"]="⁾",a="ᵃ",b="ᵇ",c="ᶜ",d="ᵈ",e="ᵉ",f="ᶠ",g="ᵍ",h="ʰ",
  i="ⁱ",j="ʲ",k="ᵏ",l="ˡ",m="ᵐ",n="ⁿ",o="ᵒ",p="ᵖ",r="ʳ",s="ˢ",t="ᵗ",
  u="ᵘ",v="ᵛ",w="ʷ",x="ˣ",y="ʸ",z="ᶻ",T="ᵀ",["⊤"]="ᵀ",
}

-- Map every character of `s` through `map`; nil if any character is missing.
local function to_script(s, map)
  local out = {}
  for _, code in utf8.codes(s) do
    local ch = map[utf8.char(code)]
    if not ch then return nil end
    out[#out + 1] = ch
  end
  return table.concat(out)
end

local function url_encode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function tidy(tex)
  return (tex:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Inline math -> list of inlines using Unicode, or nil if it's too complex.
local function inline_math_to_unicode(tex)
  -- Pandoc's HTML writer renders simple TeX as <em>/<sub>/<sup> and leaves
  -- anything it can't handle as raw TeX; read that back to get an AST.
  local html = pandoc.write(
    pandoc.Pandoc({ pandoc.Plain({ pandoc.Math("InlineMath", tex) }) }), "html")
  if html:find("%$") then return nil end

  -- Use real Unicode sub/superscripts where they exist (Medium drops <sub> and
  -- <sup>); otherwise fall back to x_(...) / x^(...) so nothing is lost.
  local function script(map, marker)
    return function(el)
      local text = pandoc.utils.stringify(el)
      local compact = text:gsub("%s", "")
      local unicode = to_script(compact, map)
      if unicode then return pandoc.Str(unicode) end
      if utf8.len(compact) == 1 then return pandoc.Str(marker .. compact) end
      return pandoc.Str(marker .. "(" .. compact .. ")")
    end
  end

  local blocks = pandoc.read(html, "html").blocks:walk({
    Subscript = script(SUB, "_"),
    Superscript = script(SUP, "^"),
    Span = function(el) return el.content end,
  })
  if #blocks ~= 1 then return nil end
  return blocks[1].content
end

local function equation_image(tex)
  tex = tidy(tex)
  local src = IMAGE_URL .. url_encode(IMAGE_PREFIX .. tex)
  return pandoc.Para({ pandoc.Image({}, src, "", pandoc.Attr("", { "equation" })) })
end

-- The display equation an inline holds, if any. Numbered equations arrive
-- wrapped by Quarto as Span#eq-label[Math], with "\qquad(n)" already added.
local function display_math(el)
  if el.t == "Math" and el.mathtype == "DisplayMath" then return el.text end
  if el.t == "Span" and #el.content == 1 then return display_math(el.content[1]) end
  return nil
end

local function is_blank(inlines)
  for _, el in ipairs(inlines) do
    if el.t ~= "Space" and el.t ~= "SoftBreak" and el.t ~= "LineBreak" then
      return false
    end
  end
  return true
end

-- Split a paragraph at each display equation so every image stands alone.
local function split_at_equations(para)
  local blocks, current, found = {}, {}, false
  local function flush()
    while #current > 0 and is_blank({ current[1] }) do table.remove(current, 1) end
    while #current > 0 and is_blank({ current[#current] }) do table.remove(current) end
    if #current > 0 then blocks[#blocks + 1] = pandoc.Para(current) end
    current = {}
  end
  for _, el in ipairs(para.content) do
    local tex = display_math(el)
    if tex then
      found = true
      flush()
      blocks[#blocks + 1] = equation_image(tex)
    else
      current[#current + 1] = el
    end
  end
  if not found then return nil end
  flush()
  return blocks
end

local function is_absolute(target)
  return target:match("^%a[%w+.-]*:") or target:match("^//")
end

-- Directory of the current post relative to the project root ("posts/foo").
local function doc_dir()
  local dir = pandoc.path.directory(quarto.doc.input_file)
  local rel = pandoc.path.make_relative(dir, quarto.project.directory)
  return rel == "." and "" or rel
end

-- Resolve a site-relative link from this post to an absolute published URL.
local function absolute_url(target)
  local path, suffix = target:match("^([^?#]*)(.*)$")
  path = path:gsub("%.qmd$", ".html"):gsub("%.ipynb$", ".html")
  local parts = {}
  local from = path:sub(1, 1) == "/" and "" or doc_dir()
  for part in (from .. "/" .. path):gmatch("[^/\\]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return base_url .. "/" .. table.concat(parts, "/") .. suffix
end

local filter = {
  Para = split_at_equations,

  Math = function(el)
    if el.mathtype ~= "InlineMath" then return nil end
    local inlines = inline_math_to_unicode(el.text)
    if inlines then return inlines end
    unconverted[#unconverted + 1] = el.text
    return pandoc.Code(tidy(el.text))
  end,

  Link = function(el)
    if el.target:sub(1, 1) == "#" then return el.content end
    if not is_absolute(el.target) then
      el.target = absolute_url(el.target)
      return el
    end
  end,

  Note = function(el)
    notes[#notes + 1] = el.content
    return pandoc.Str("[" .. #notes .. "]")
  end,

  Table = function()
    quarto.log.warning("medium.lua: Medium has no tables — this one will import as loose text. Consider a screenshot or a GitHub gist.")
  end,
}

function Pandoc(doc)
  local meta_url = doc.meta["medium-base-url"]
  if meta_url then base_url = pandoc.utils.stringify(meta_url):gsub("/+$", "") end
  if base_url == "" then
    quarto.log.warning("medium.lua: `medium-base-url` is not set, so relative links will be broken.")
  end

  -- Tell search engines the real post is the original, not this copy.
  if base_url ~= "" then
    local canonical = absolute_url(pandoc.path.filename(quarto.doc.input_file))
    local includes = doc.meta["header-includes"] or pandoc.List()
    if pandoc.utils.type(includes) ~= "List" then includes = pandoc.List({ includes }) end
    includes:insert(pandoc.RawBlock("html", '<link rel="canonical" href="' .. canonical .. '">'))
    doc.meta["header-includes"] = includes
  end

  -- Notes first (their own math and links get processed in the main pass).
  doc = doc:walk({ Note = filter.Note })
  if #notes > 0 then
    doc.blocks:insert(pandoc.Header(2, "Notes"))
    doc.blocks:insert(pandoc.OrderedList(notes))
  end

  -- Split paragraphs before converting inline math: Para is visited after its
  -- children by default, and the display equations must still be Math then.
  doc = doc:walk({ Para = filter.Para })
  doc = doc:walk({ Math = filter.Math, Link = filter.Link, Table = filter.Table })

  if #unconverted > 0 then
    quarto.log.warning("medium.lua: " .. #unconverted ..
      " inline expression(s) were too complex for Unicode and were left as code. " ..
      "Move them into display equations or reword:\n  " ..
      table.concat(unconverted, "\n  "))
  end
  return doc
end
