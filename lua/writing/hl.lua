-- Highlight groups. All are `default` links, so a colorscheme or your config
-- (setup({ highlights = … }) or plain :hi on ColorScheme) wins.

local M = {}

M.links = {
  -- the audit walker (spell, grammar, conform, restyle, rigor)
  SpellAuditAccent = "Function", -- suggestion numbers
  SpellAuditTitle = "Title", -- float title
  SpellAuditMuted = "Comment", -- context, labels, footer
  SpellAuditBad = "SpellBad", -- the issue inside the context line
  SpellAuditWord = "Visual", -- the issue in the buffer
  SpellAuditSel = "CursorLine", -- selected suggestion
  -- outline / rigor panels and the assist floats
  WritingTitle = "Title",
  WritingMuted = "Comment",
  WritingRole = "Function", -- outline roles, "Fix:"
  WritingFlag = "DiagnosticWarn",
  WritingHeading = "Title",
  WritingCurrent = "CursorLine", -- outline entry of the paragraph under the cursor
  WritingMajor = "DiagnosticWarn",
  WritingMinor = "DiagnosticInfo",
  -- restyle diffs in the walker float
  WritingDel = "DiffDelete",
  WritingAdd = "DiffAdd",
}

function M.apply()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  local over = require("writing.config").options.highlights
  if type(over) == "function" then over = over() end
  for name, spec in pairs(over or {}) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("writing_hl", { clear = true }),
    callback = M.apply,
  })
end

return M
