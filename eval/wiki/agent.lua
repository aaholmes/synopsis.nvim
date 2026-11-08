-- The wiki eval's blocking wrapper around the plugin's question loop (synopsis.ask), with the
-- eval's tools (the plugin's plus the language server's). run(o) takes synopsis.ask's options
-- and returns its result.
local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local A = { tools = dofile(here .. '/tools.lua') }

function A.run(o)
  local r
  require('synopsis.ask').start(vim.tbl_extend('force', o, {
    toolset = o.toolset or A.tools,
    on_done = function(x) r = x end,
  }))
  vim.wait(o.wait_ms or 900000, function() return r ~= nil end, 10)
  return r or { rounds = 0, calls = {}, usage = {}, error = 'no result in time' }
end

return A
