local utils = require 'utils'

local stdout
do
  -- Add current script path to the lua package search path,
  -- this is necessary to require modules relative to this file.
  local script_path = debug.getinfo(1, 'S').source:sub(2)
  local script_dir = script_path:gsub('[/\\]*[^/\\]-$', '')
  script_dir = script_dir == '' and '.' or script_dir
  local dirsep, pathsep = package.config:match('(.)[\r\n]+(.)[\r\n]+')
  package.path = script_dir..dirsep..'?.lua'..pathsep..package.path

  -- Redirect stderr/stdout to a file so we can debug errors.
  local err = io.stderr
  stdout = io.stdout
  _G.io.stdout, _G.io.stderr = err, err
end

-- Required modules
local except = require 'nelua.utils.except'
local fs = require 'nelua.utils.fs'
local sstream = require 'nelua.utils.sstream'
local analyzer = require 'nelua.analyzer'
local console  = require 'nelua.utils.console'
local aster = require 'nelua.aster'
local AnalyzerContext = require 'nelua.analyzercontext'
local server = require 'server'
local generator = require('nelua.cgenerator')
local json = require 'json'
local inspect = require 'nelua.thirdparty.inspect'
local parseerror = require 'parseerror'

local cache = {}

local function map_severity(text)
  if text == 'error' then return 1 end
  if text == 'warning' then return 2 end
  if text == 'info' then return 3 end
  return 4
end

local function analyze_ast(input, infile, uri)
  local ast
  local ok, err = except.trycall(function()
    ast = aster.parse(input, infile)
    local context = AnalyzerContext(analyzer.visitors, ast, generator)
    except.try(function()
      context = analyzer.analyze(context)
    end, function(e)
      -- todo
    end)
  end)
  local diagnostics = {}
  if not ok then
    local stru = parseerror(err.message)
    for _, ins in ipairs(stru) do
      table.insert(diagnostics, {
        range = {
          ['start'] = {line = ins.line - 1, character = ins.character - 1},
          ['end'] = {line = ins.line - 1, character = ins.character + ins.length - 1},
        },
        severity = map_severity(ins.severity),
        source = 'Nelua LSP',
        message = ins.message,
      })
    end
  end
  server.send_notification('textDocument/publishDiagnostics', {
    uri = uri,
    diagnostics = diagnostics,
  })
  return ast
end

local function cache_document(uri, content)
  local filepath = utils.uri2path(uri)
  local content = content or fs.readfile(filepath)
  ast = analyze_ast(content, filepath, uri)
  if ast then
    local ret = {content = content, ast = ast}
    cache[uri] = ret
    return ret
  end
end

local function analyze_and_find_loc(uri, textpos)
  local cached = cache[uri] or cache_document(uri)
  if not cached then return end
  local content = cached.content
  local pos = utils.linecol2pos(content, textpos.line, textpos.character)
  local ast = cached.ast
  if not ast then return end
  local nodes = utils.find_nodes_by_pos(ast, pos)
  local lastnode = nodes[#nodes]
  if not lastnode then return end
  local loc = {node=lastnode}
  if lastnode.attr._symbol then
    loc.symbol = lastnode.attr
  end
  for i=#nodes,1,-1 do -- find scope
    local attr = nodes[i].attr
    if attr.scope then
      loc.scope = attr.scope
      break
    end
  end
  return loc
end

local function markup_loc_info(loc)
  local ss = sstream()
  local attr = loc.node.attr
  local type = attr.type

  if type then
    local typename = type.name
    if type.is_type then
      type = attr.value
      ss:addmany('**type** `', type.nickname or type.name, '`\n')
      local content = utils.get_node_src_content(type.node)
      ss:add('```nelua\n')
      if content then
        ss:addmany('', content,'\n')
      else
        ss:addmany('', type:typedesc(),'\n')
      end
      ss:add('```')
    elseif type.is_function then
      if attr.value then
        type = attr.value
        ss:addmany('**function** `', type.nickname or type.name, '`\n')
        local content = utils.get_node_src_content(type.node)
        ss:add('```nelua\n')
        if type.type then
          ss:addmany(type.type,'\n')
        else
          ss:addmany(type.symbol,'\n')
        end
        ss:add('```')
      else
        ss:addmany('**function** `', attr.name, '`\n')
        if attr.builtin then
          ss:add('* builtin function\n')
        end
      end
    else
      ss:addmany('**value** `', typename, '`')
    end
  end
  return ss:tostring()
end

-- Get hover information
local function hover_method(reqid, params)
  local loc = analyze_and_find_loc(params.textDocument.uri, params.position)
  if loc then
    local value = markup_loc_info(loc)
    server.send_response(reqid, {contents = {kind = 'markdown', value = value}})
  else
    server.send_response(reqid, {contents = ''})
  end
end

local function sync_open(reqid, params)
  local doc = params.textDocument
  if not cache_document(doc.uri, doc.text) then
    server.error('Failed to load document')
  end
end

local function sync_change(reqid, params)
  local doc = params.textDocument
  local content = params.contentChanges[1].text
  cache_document(doc.uri, content)
end

local function sync_close(reqid, params)
  local doc = params.textDocument
  cache[doc.uri] = nil
end

-- All capabilities supported by this language server.
server.capabilities = {
  textDocumentSync = {
    openClose = true,
    change = 1,
  },
  hoverProvider = true,
  publishDiagnostics = true,
}
server.methods = {
  ['textDocument/hover'] = hover_method,
  ['textDocument/didOpen'] = sync_open,
  ['textDocument/didChange'] = sync_change,
  ['textDocument/didClose'] = sync_close,
}

-- Listen for requests.
server.listen(io.stdin, stdout)
