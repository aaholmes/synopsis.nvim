local H = dofile 'tests/harness.lua'
local consent = require 'synopsis.consent'

H.check('an unknown repo has no decision', function() H.eq(consent.get '/repo/new', nil, 'decision') end)

H.check('a decision is kept, and survives reloading the module', function()
  consent.set('/repo/a', 'allow')
  consent.set('/repo/b', 'deny')
  package.loaded['synopsis.consent'] = nil
  local fresh = require 'synopsis.consent'
  H.eq(fresh.get '/repo/a', 'allow', 'allow')
  H.eq(fresh.get '/repo/b', 'deny', 'deny')
end)

H.check('decisions are stored in the data directory, not the cache', function()
  H.eq(vim.startswith(consent.path(), vim.fn.stdpath 'data'), true, consent.path())
end)

H.check('a decision can be changed', function()
  consent.set('/repo/a', 'deny')
  H.eq(consent.get '/repo/a', 'deny', 'changed')
end)

H.finish()
