local re = require 'nelua.thirdparty.lpegrex'

local patt = re.compile[[
  line    <== path ":" column ":" row ": " title message
  num     <-- {[%d]+} -> tonumber
  column  <-- num
  row     <-- num
  path    <-- {([^:] / (":\"))+}
  title   <-- {[^:]+} ": "
  message <-- {.+}
]]

return function(content)
  local stru = {}
  local curr

  for line in content:gmatch("([^\n\r]*)\r?\n?") do
    if line == "stack traceback:" then break end
    local res = patt:match(line)
    if res then
      if curr then
        table.insert(stru, curr)
      end
      curr = {
        path = res[1],
        line = res[2],
        character = res[3],
        severity = res[4],
        message = res[5],
        length = 1,
      }
    else
      local matched = line:match("^ *([~^]+) *$")
      if matched then
        curr.length = #matched
      end
    end
  end
  if curr then table.insert(stru, curr) end
  return stru
end