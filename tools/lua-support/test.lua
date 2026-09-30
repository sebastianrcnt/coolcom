assert(_VERSION == 'Lua 5.4')
assert(('hello'):upper() == 'HELLO')
assert(('abcd'):sub(2, 3) == 'bc')
local t = {answer = 42, 1, 2, 3}
assert(#t == 3 and t.answer == 42 and table.concat(t, ',') == '1,2,3')
local function counter(x)
  return function(y) x = x + y; return x end
end
local f = counter(4)
assert(f(5) == 9 and f(1) == 10)
local ok, msg = pcall(function() error('caught') end)
assert(not ok and msg:find('caught', 1, true))
assert(pcall(function() return 7 end))
assert(string.format('%s:%04d:%.2f', 'fmt', 7, 1.25) == 'fmt:0007:1.25')
io.write('LUA TEST PASS\n')
