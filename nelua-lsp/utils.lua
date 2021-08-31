local fs = require 'nelua.utils.fs'
local lpegrex = require 'nelua.thirdparty.lpegrex'
local console  = require 'nelua.utils.console'

local utils = {}

utils.dirsep, utils.pathsep = package.config:match('(.)[\r\n]+(.)[\r\n]+')
utils.is_windows = utils.dirsep == '\\'

function decodeURI(s)
  return string.gsub(s, '%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
end

function encodeURI(s)
  s = string.gsub(s, "([^%w%.%- ])", function(c) return string.format("%%%02X", string.byte(c)) end)
  return string.gsub(s, " ", "+")
end

-- Convert a LSP uri to an usable system path.
function utils.uri2path(uri)
  local file = uri:match('file://(.*)')
  file = decodeURI(file)
  if utils.is_windows then
    file = string.sub(file:gsub('/', '\\'), 2)
  end
  file = fs.normpath(file)
  return file
end

function utils.path2uri(path)
  if utils.is_windows then
    path = '/'..path:gsub('\\', '/')
  end
  return 'file://'..path
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

function utils.node2textrange(node)
  return utils.posrange2textrange(node.src.content, node.pos, node.endpos)
end

local function find_parent_nodes(node, target, foundnodes)
  if type(node) ~= 'table' then return end
  for i=1,node.nargs or #node do
    local curr = node[i]
    if curr == target then
      table.insert(foundnodes, node)
      return true
    end
    if find_parent_nodes(curr, target, foundnodes) then
      table.insert(foundnodes, node)
      return true
    end
  end
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

-- Find node's parent chain
function utils.find_parent_nodes(node, target)
  local foundnodes = {}
  find_parent_nodes(node, target, foundnodes)
  return foundnodes
end

-- Find all nodes that contains the position.
function utils.find_nodes_by_pos(node, pos)
  local foundnodes = {}
  find_nodes_by_pos(node, pos, foundnodes)
  return foundnodes
end

function utils.dump_table(table, opts)
  opts = opts or {}
  if not table then
    console.debug '(nil)'
    return
  end
  if type(table) ~= 'table' then
    console.debug('('..type(table)..')')
    return
  end
  if opts.meta then
    for k, v in pairs(getmetatable(table)) do
      console.debugf("#%s = %s", k, tostring(v))
    end
  end
  for k, v in pairs(table) do
    console.debugf("%s = %s", k, tostring(v))
  end
end

return utils
