local lfs = require 'lfs'
local console  = require 'nelua.utils.console'
local except = require 'nelua.utils.except'
local fs = require 'nelua.utils.fs'
local sstream = require 'nelua.utils.sstream'
local analyzer = require 'nelua.analyzer'
local aster = require 'nelua.aster'
local typedefs = require 'nelua.typedefs'
local AnalyzerContext = require 'nelua.analyzercontext'
local generator = require 'nelua.cgenerator'
local inspect = require 'nelua.thirdparty.inspect'
local spairs = require 'nelua.utils.iterators'.spairs

local server = require 'nelua-lsp.server'
local json = require 'nelua-lsp.json'
local parseerror = require 'nelua-lsp.parseerror'
local utils = require 'nelua-lsp.utils'

local stdout
do
  -- Fix CRLF problem on windows
  lfs.setmode(io.stdin, 'binary')
  lfs.setmode(io.stdout, 'binary')
  lfs.setmode(io.stderr, 'binary')
  -- Redirect stderr/stdout to a file so we can debug errors.
  local err = io.stderr
  stdout = io.stdout
  _G.io.stdout, _G.io.stderr = err, err
  _G.print = console.debug
  _G.printf = console.debugf
end

local astcache = {}
local codecache = {}

local function map_severity(text)
  if text == 'error' or text == 'syntax error' then return 1 end
  if text == 'warning' then return 2 end
  if text == 'info' then return 3 end
  return 4
end

local function analyze_ast(input, infile, uri, skip)
  local ast
  local ok, err = except.trycall(function()
    ast = aster.parse(input, infile)
    local context = AnalyzerContext(analyzer.visitors, ast, generator)
    except.try(function()
      if not server.root_path then
        local dir = infile:match('(.+)'..utils.dirsep)
        lfs.chdir(dir)
      end
      for k, v in pairs(typedefs.primtypes) do
        if v.metafields then
          v.metafields = {}
        end
      end
      context = analyzer.analyze(context)
    end, function(e)
      -- todo
    end)
  end)
  local diagnostics = {}
  if not ok then
    if err.message then
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
    elseif not skip then
      server.error(tostring(err))
    end
  end
  if not skip then
    server.send_notification('textDocument/publishDiagnostics', {
      uri = uri,
      diagnostics = diagnostics,
    })
  end
  return ast
end

local function fetch_document(uri, content, skip)
  local filepath = utils.uri2path(uri)
  local content = content or fs.readfile(filepath)
  ast = analyze_ast(content, filepath, uri, skip)
  if not skip then
    codecache[uri] = content
    if ast then
      astcache[uri] = ast
    end
  end
  return ast
end

local function analyze_and_find_loc(uri, textpos, content)
  local ast = content and fetch_document(uri, content, true) or astcache[uri] or fetch_document(uri)
  if not ast then return end
  local content = content or codecache[uri]
  local pos = utils.linecol2pos(content, textpos.line, textpos.character)
  if not ast then return end
  local nodes = utils.find_nodes_by_pos(ast, pos)
  local lastnode = nodes[#nodes]
  if not lastnode then return end
  local loc = {node=lastnode, nodes=nodes}
  if lastnode.attr._symbol then
    loc.symbol = lastnode.attr
  end
  for i=#nodes,1,-1 do -- find scope
    local node = nodes[i]
    -- utils.dump_table(nodes[i])
    if node.scope then
      loc.scope = node.scope
      break
    end
  end
  return loc
end

local function dump_type_info(type, ss, opts)
  opts = opts or {}
  if not opts.no_header then
    ss:addmany('**type** `', type.nickname or type.name, '`\n')
  end
  ss:addmany('```nelua\n', type:typedesc(),'\n```')
end

local function node_info(node, attr, opts)
  local opts = opts or {}
  local ss = sstream()
  local attr = attr or node.attr
  local type = attr.type

  if type then
    local typename = type.name
    if type.is_type then
      type = attr.value
      dump_type_info(type, ss, opts)
    elseif type.is_function or type.is_polyfunction then
      if attr.value then
        type = attr.value
        if not opts.no_header then
          ss:addmany('**', typename, '** `', type.nickname or type.name, '`\n')
        end
        ss:add('```nelua\n')
        if type.type then
          ss:addmany(type.type,'\n')
        else
          ss:addmany(type.symbol,'\n')
        end
        ss:add('```')
      else
        if not opts.no_header then
          ss:addmany('**function** `', attr.name, '`\n')
        end
        if attr.builtin then
          ss:add('* builtin function\n')
        end
      end
    elseif type.is_pointer then
      ss:add('**pointer**\n')
      dump_type_info(type.subtype, ss)
    elseif attr.ismethod then
      return node_info(nil, attr.calleesym, opts)
    else
      ss:addmany('**value** `', type, '`\n')
      if type.symbol and type.symbol.node and type.symbol.node.attr then
        ss:addmany('\n', node_info(nil, type.symbol.node.attr, {no_header = true}))
      end
    end
  end
  return ss:tostring()
end

-- Get hover information
local function hover_method(reqid, params)
  local loc = analyze_and_find_loc(params.textDocument.uri, params.position)
  if loc then
    local value = node_info(loc.node)
    server.send_response(reqid, {contents = {kind = 'markdown', value = value}})
  else
    server.send_response(reqid, {contents = ''})
  end
end

local function get_definitioin_symbol(root, snode, tnode)
  if not tnode then return nil end
  local srange = utils.posrange2textrange(snode.src.content, snode.pos, snode.endpos)
  local trange = utils.posrange2textrange(tnode.src.content, tnode.pos, tnode.endpos)
  local pnodes = utils.find_parent_nodes(root, tnode)
  local prange = trange
  if #pnodes then
    for _, pnode in ipairs(pnodes) do
      if pnode.pos ~= nil then
        prange = utils.posrange2textrange(tnode.src.content, pnode.pos, pnode.endpos)
        break
      end
    end
  end
  local uri = utils.path2uri(tnode.src.name)
  -- utils.dump_table(tnode.src)
  return {
    originSelectionRange = srange,
    targetUri = uri,
    targetRange = prange,
    targetSelectionRange = trange,
  }
end

-- Get hover information
local function definition_method(reqid, params)
  local loc = analyze_and_find_loc(params.textDocument.uri, params.position)
  if not loc then
    server.send_response(reqid, {})
    return
  end
  local rootnode = loc.nodes[1]
  local node = loc.node
  local list = {}
  if node.is_Id then
    table.insert(list, get_definitioin_symbol(rootnode, node, loc.symbol.node))
  elseif node.is_call then
    table.insert(list, get_definitioin_symbol(rootnode, node, node.attr.calleesym.node))
  elseif node.is_DotIndex then
    local sym = loc.symbol or node[2].attr
    if sym then
      table.insert(list, get_definitioin_symbol(rootnode, node, sym.node))
    end
  else
    print(node.tag)
  end
  server.send_response(reqid, list)
end

local function sync_open(reqid, params)
  local doc = params.textDocument
  if not fetch_document(doc.uri, doc.text) then
    server.error('Failed to load document')
  end
end

local function sync_change(reqid, params)
  local doc = params.textDocument
  local content = params.contentChanges[1].text
  fetch_document(doc.uri, content)
end

local function sync_close(reqid, params)
  local doc = params.textDocument
  astcache[doc.uri] = nil
  codecache[doc.uri] = nil
end

local function gen_completion_list(scope, out)
  if not scope then return end
  gen_completion_list(scope.parent, out)
  for _, v in ipairs(scope.symbols) do
    out[v.name] = tostring(v.type)
  end
end

local function code_completion(reqid, params)
  local uri = params.textDocument.uri
  local content = codecache[uri]
  local textpos = params.position
  local pos = utils.linecol2pos(content..'\n', textpos.line, textpos.character)
  -- some hack for get ast node
  local before = content:sub(1, pos-1):gsub('%a%w*$', '')
  local after = content:sub(pos):gsub('^[.:]?%a%w*', '')
  local kind = "normal"
  -- fake function call
  if before:match('[.]$') then
    before = before:sub(1, -2)..'()'
    kind = "field"
  elseif before:match(':$') then
    before = before:sub(1, -2)..'()'
    kind = "meta"
  end
  content = before..' '..after..'\n'

  local ast = analyze_and_find_loc(params.textDocument.uri, textpos, content)
  local list = {}
  if ast then
    local node = ast.node
    if kind == "field" or kind == "meta" then
      if node.is_call then
        local attr = node.attr
        local xtype = attr.type
        local is_instance = false
        if not xtype then
          attr = node[2].attr
          xtype = attr.type
          is_instance = true
        end
        if xtype then
          if is_instance then
            for k, v in pairs(xtype.metafields) do
              if kind == "meta" and v.metafuncselftype ~= nil then
                table.insert(list, {label = k, detail = tostring(v)})
              end
            end
            if kind == "field" then
              for k, v in spairs(xtype.fields) do
                table.insert(list, {label = k, detail = tostring(v.type)})
              end
            end
          elseif kind == "field" then
            local tab = xtype.is_record and xtype.metafields or xtype.fields
            for k, v in spairs(tab) do
              if xtype.is_enum then
                table.insert(list, {label = k, detail = tostring(xtype)})
              else
                table.insert(list, {label = k, detail = tostring(v.type and v.type or v)})
              end
            end
          end
        end
      end
    elseif kind == "normal" then
      local symcache = {}
      gen_completion_list(ast.scope, symcache)
      for k, v in pairs(symcache) do
        table.insert(list, {label = k, detail = v})
      end
    end
  end
  server.send_response(reqid, list)
end

-- All capabilities supported by this language server.
server.capabilities = {
  textDocumentSync = {
    openClose = true,
    change = 1,
  },
  hoverProvider = true,
  publishDiagnostics = true,
  completionProvider = {
    triggerCharacters = { ".", ":" },
  },
  definitionProvider = true
}
server.methods = {
  ['textDocument/hover'] = hover_method,
  ['textDocument/definition'] = definition_method,
  ['textDocument/didOpen'] = sync_open,
  ['textDocument/didChange'] = sync_change,
  ['textDocument/didClose'] = sync_close,
  ['textDocument/completion'] = code_completion,
}

-- Listen for requests.
server.listen(io.stdin, stdout)
