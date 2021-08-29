local fs = require 'nelua.utils.fs'
local lpegrex = require 'nelua.thirdparty.lpegrex'
local console  = require 'nelua.utils.console'

local utils = {}

utils.dirsep, utils.pathsep = package.config:match('(.)[\r\n]+(.)[\r\n]+')
utils.is_windows = utils.dirsep == '\\'

function decodeURI(s)
  return string.gsub(s, '%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
end

-- Convert a LSP uri to an usable system path.
function utils.uri2path(uri)
  local file = uri:match('file://(.*)')
  file = decodeURI(file)
  if utils.is_windows then
    file = string.sub(string.gsub(file, '/', '\\'), 2)
  end
  file = fs.normpath(file)
  return file
end

-- Get content position from a line number and column number.
-- The line and column numbers must be zero based (starts at 0).
-- The returned position is one based (starts at 1).
function utils.linecol2pos(content, lineno, colno)
  local i = 0
  local pos = 0
  for line in content:gmatch('[^\r\n]*[\r]?[\n]') do
    if i == lineno then
      pos = pos + colno
      break
    end
    i = i + 1
    pos = pos + #line
  end
  return pos + 1 -- convert to one-based
end

-- Convert content position into a table to send back in LSP API.
function utils.pos2textpos(content, pos)
  local lineno, colno = lpegrex.calcline(content, pos)
  return {line=lineno-1, character=colno-1} -- convert to zero-based
end

-- Convert a content position range to a table to send back in LSP API.
function utils.posrange2textrange(content, startpos, endpos)
  return {['start']=utils.pos2textpos(content, startpos),
          ['end']=utils.pos2textpos(content, endpos)}
end

local function find_nodes_by_pos(node, pos, foundnodes)
  if type(node) ~= 'table' then return end
  if node._astnode and
     node.pos and pos >= node.pos and
     node.endpos and pos < node.endpos then
    foundnodes[#foundnodes+1] = node
  end
  for i=1,node.nargs or #node do
    find_nodes_by_pos(node[i], pos, foundnodes)
  end
end

-- Find all nodes that contains the position.
function utils.find_nodes_by_pos(node, pos)
  local foundnodes = {}
  find_nodes_by_pos(node, pos, foundnodes)
  return foundnodes
end

function utils.dump_table(table)
  if not table then
    console.debug '(nil)'
    return
  end
  for k, v in pairs(table) do
    console.debugf("%s = %s", k, tostring(v))
  end
end

return utils
